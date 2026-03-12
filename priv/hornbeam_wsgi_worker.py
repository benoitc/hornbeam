# Copyright 2026 Benoit Chesneau
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Channel-based WSGI worker for hornbeam.

This module provides a high-performance WSGI worker that uses channels
for communication with Erlang. All I/O flows through the channel,
enabling efficient streaming and backpressure handling.

Flow:
1. Erlang creates channel, sends environ, calls handle_request
2. Python receives environ from channel
3. Python processes request with WSGI app
4. Python sends headers/body chunks back via reply() to caller pid
5. Python signals completion with 'done'
"""

import io
import threading
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import erlang
    from erlang import Channel, ChannelClosed, reply
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False


# Pre-allocated error wrapper for wsgi.errors
class _WSGIErrorsWrapper:
    """Minimal wsgi.errors wrapper that routes to logging."""

    def write(self, msg):
        if msg and msg.strip():
            try:
                import logging
                logging.getLogger('hornbeam.wsgi').error(msg.rstrip())
            except Exception:
                pass

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def flush(self):
        pass


# Shared instances
_SHARED_ERRORS = _WSGIErrorsWrapper()
_WSGI_VERSION = (1, 0)


class FileWrapper:
    """Efficient file serving wrapper for WSGI."""

    def __init__(self, filelike, blksize=8192):
        self.filelike = filelike
        self.blksize = blksize
        if hasattr(filelike, 'close'):
            self.close = filelike.close

    def __iter__(self):
        return self

    def __next__(self):
        data = self.filelike.read(self.blksize)
        if data:
            return data
        raise StopIteration


# BytesIO pool for wsgi.input
_BYTESIO_POOL: List[io.BytesIO] = []
_BYTESIO_POOL_SIZE = 100
_BYTESIO_POOL_LOCK = threading.Lock()


def _get_bytesio(data: bytes) -> io.BytesIO:
    """Get a BytesIO from pool or create new one."""
    bio = None
    with _BYTESIO_POOL_LOCK:
        if _BYTESIO_POOL:
            bio = _BYTESIO_POOL.pop()
    if bio is not None:
        bio.seek(0)
        bio.truncate()
        bio.write(data)
        bio.seek(0)
        return bio
    return io.BytesIO(data)


def _return_bytesio(bio: io.BytesIO) -> None:
    """Return a BytesIO to the pool."""
    with _BYTESIO_POOL_LOCK:
        if len(_BYTESIO_POOL) < _BYTESIO_POOL_SIZE:
            _BYTESIO_POOL.append(bio)


# Environ template (shared base)
_ENVIRON_TEMPLATE = {
    'wsgi.version': _WSGI_VERSION,
    'wsgi.multithread': True,
    'wsgi.multiprocess': True,
    'wsgi.run_once': False,
    'wsgi.file_wrapper': FileWrapper,
    'wsgi.input_terminated': True,
}


# Thread-safe app cache
_app_cache: Dict[Tuple[str, str], Callable] = {}
_app_cache_lock = threading.Lock()


def _load_app(module_name: str, callable_name: str) -> Callable:
    """Load a WSGI application with thread-safe caching."""
    cache_key = (module_name, callable_name)

    if cache_key in _app_cache:
        return _app_cache[cache_key]

    with _app_cache_lock:
        if cache_key in _app_cache:
            return _app_cache[cache_key]

        import importlib
        import sys

        if module_name not in sys.modules:
            module = importlib.import_module(module_name)
        else:
            module = sys.modules[module_name]

        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


def _to_str(val) -> str:
    """Convert bytes/None to string."""
    if val is None:
        return ''
    if val.__class__.__name__ == 'Atom' or val == b'undefined':
        return ''
    if isinstance(val, bytes):
        return val.decode('utf-8', errors='replace')
    return str(val) if not isinstance(val, str) else val


def _is_none(val) -> bool:
    """Check if value is None or Erlang's undefined atom."""
    return val is None or val == b'undefined' or (
        val.__class__.__name__ == 'Atom' and str(val) == 'undefined'
    )


def _create_environ(req_tuple) -> dict:
    """Create WSGI environ from pre-parsed Erlang tuple.

    Args:
        req_tuple: (method, script_name, path_info, query_string, wsgi_headers,
                   content_type, content_length, body, server, client, scheme,
                   protocol, lifespan_state)

    Returns:
        Complete WSGI environ dict
    """
    (method, script_name, path_info, query_string, wsgi_headers,
     content_type, content_length, body, server, client, scheme,
     protocol, lifespan_state) = req_tuple

    # Handle body
    if body is None or body == b'' or body == '':
        body_bytes = b''
    elif isinstance(body, bytes):
        body_bytes = body
    elif isinstance(body, str):
        body_bytes = body.encode('utf-8')
    else:
        try:
            body_bytes = bytes(body)
        except (TypeError, ValueError):
            body_bytes = b''

    wsgi_input = _get_bytesio(body_bytes)

    # Early hints callback
    early_hints_list = []

    def early_hints_callback(headers):
        early_hints_list.append(headers)

    # Build environ from template
    environ = _ENVIRON_TEMPLATE.copy()

    environ['REQUEST_METHOD'] = _to_str(method)
    environ['SCRIPT_NAME'] = _to_str(script_name) if script_name else ''
    environ['PATH_INFO'] = _to_str(path_info)
    environ['QUERY_STRING'] = _to_str(query_string)
    environ['SERVER_NAME'] = _to_str(server[0])
    environ['SERVER_PORT'] = str(server[1])
    environ['SERVER_PROTOCOL'] = _to_str(protocol)
    environ['wsgi.url_scheme'] = _to_str(scheme)
    environ['wsgi.input'] = wsgi_input
    environ['wsgi.errors'] = _SHARED_ERRORS
    environ['wsgi.early_hints'] = early_hints_callback
    environ['REMOTE_ADDR'] = _to_str(client[0])
    environ['REMOTE_PORT'] = str(client[1])
    environ['_hornbeam.early_hints'] = early_hints_list
    environ['_hornbeam.wsgi_input'] = wsgi_input
    environ['_hornbeam.lifespan_state'] = lifespan_state

    # Add HTTP_* headers (pre-converted by Erlang)
    if wsgi_headers:
        for key, value in wsgi_headers.items():
            environ[_to_str(key)] = _to_str(value)

    # Add content-type/length
    if not _is_none(content_type):
        environ['CONTENT_TYPE'] = _to_str(content_type)
    if not _is_none(content_length):
        environ['CONTENT_LENGTH'] = _to_str(content_length)

    return environ


class _Response:
    """WSGI response handler."""
    __slots__ = ('status', 'headers', '_write_buffer')

    def __init__(self):
        self.status = None
        self.headers = []
        self._write_buffer = []

    def start_response(self, status, response_headers, exc_info=None):
        if exc_info:
            try:
                if self.status is not None:
                    raise exc_info[1].with_traceback(exc_info[2])
            finally:
                exc_info = None
        elif self.status is not None:
            raise RuntimeError("start_response already called")

        self.status = status
        self.headers = list(response_headers)
        return self._write

    def _write(self, data):
        if not self.status:
            raise RuntimeError("write() called before start_response()")
        self._write_buffer.append(data)


def handle_request(channel_ref, caller_pid, app_module: str, app_callable: str) -> None:
    """Handle a WSGI request using channel-based I/O.

    This is the main entry point called from Erlang. It:
    1. Receives environ from channel
    2. Processes request with WSGI app
    3. Sends response back via reply() to caller

    Args:
        channel_ref: Reference to py_channel for receiving environ
        caller_pid: Erlang PID to send response to
        app_module: Python module containing WSGI app
        app_callable: Name of WSGI callable in module
    """
    if not HAS_ERLANG:
        return

    ch = Channel(channel_ref)
    wsgi_input = None

    try:
        # 1. Receive environ from channel
        msg = ch.receive()

        if not isinstance(msg, tuple) or len(msg) < 2:
            reply(caller_pid, ('error', 'expected environ tuple'))
            return

        tag, req_tuple = msg[0], msg[1]
        if tag != 'environ':
            reply(caller_pid, ('error', f'expected environ, got {tag}'))
            return

        # 2. Build WSGI environ
        environ = _create_environ(req_tuple)
        wsgi_input = environ.get('_hornbeam.wsgi_input')

        # 3. Load and call WSGI app
        app = _load_app(app_module, app_callable)
        response = _Response()

        result = app(environ, response.start_response)

        # 4. Parse status code
        status_code = 500
        if response.status:
            try:
                status_str = response.status
                if isinstance(status_str, bytes):
                    status_str = status_str.decode('utf-8')
                parts = status_str.split(' ', 1)
                status_code = int(parts[0])
            except (ValueError, IndexError):
                pass

        # 5. Send headers via reply
        reply(caller_pid, ('headers', status_code, response.headers))

        # 6. Send any write() buffer content first
        for chunk in response._write_buffer:
            if chunk:
                if isinstance(chunk, str):
                    chunk = chunk.encode('utf-8')
                reply(caller_pid, ('chunk', chunk))

        # 7. Stream body chunks
        try:
            if isinstance(result, (bytes, bytearray)):
                reply(caller_pid, ('chunk', bytes(result)))
            else:
                for chunk in result:
                    if chunk:
                        if isinstance(chunk, str):
                            chunk = chunk.encode('utf-8')
                        elif isinstance(chunk, bytearray):
                            chunk = bytes(chunk)
                        reply(caller_pid, ('chunk', chunk))
        finally:
            if hasattr(result, 'close'):
                result.close()

        # 8. Signal completion
        reply(caller_pid, 'done')

    except ChannelClosed:
        # Channel was closed, nothing to do
        pass
    except Exception as e:
        try:
            reply(caller_pid, ('error', str(e)))
        except Exception:
            pass
    finally:
        # Return BytesIO to pool
        if wsgi_input is not None:
            _return_bytesio(wsgi_input)


def worker_loop(channel_ref, arbiter_pid, worker_id: str,
                app_module: str, app_callable: str) -> str:
    """Persistent WSGI worker - loops until stopped.

    This worker receives requests via a channel and processes them continuously,
    reducing Python startup overhead for each request.

    Args:
        channel_ref: Reference to the channel for receiving requests
        arbiter_pid: Erlang PID of the arbiter for heartbeat messages
        app_module: Python module containing WSGI app
        app_callable: Name of WSGI callable in module
        worker_id: Unique identifier for this worker (format: mount_id_idx)

    Returns:
        'stopped' when the worker exits cleanly
    """
    if not HAS_ERLANG:
        return 'no_erlang'

    import time

    ch = Channel(channel_ref)
    app = _load_app(app_module, app_callable)
    last_heartbeat = time.monotonic()
    heartbeat_interval = 5.0  # seconds

    while True:
        # Maybe send heartbeat
        now = time.monotonic()
        if now - last_heartbeat >= heartbeat_interval:
            try:
                reply(arbiter_pid, ('heartbeat', worker_id))
            except Exception:
                pass  # Arbiter might be restarting
            last_heartbeat = now

        # Receive next message (blocking, releases GIL)
        try:
            msg = ch.receive()
        except ChannelClosed:
            break

        # Handle control messages
        if msg == 'stop':
            break

        # Handle request messages
        if isinstance(msg, tuple) and len(msg) >= 2:
            tag = msg[0]

            if tag == 'start_request':
                # (start_request, caller_pid, req_info, body)
                _, caller_pid, req_info, body = msg
                _process_wsgi_request(caller_pid, app, req_info, body)

            elif tag == 'start_request_streaming':
                # (start_request_streaming, caller_pid, req_info)
                _, caller_pid, req_info = msg
                body = _receive_streaming_body(ch)
                _process_wsgi_request(caller_pid, app, req_info, body)

    return 'stopped'


def _receive_streaming_body(ch) -> bytes:
    """Receive streaming body chunks from channel."""
    chunks = []
    while True:
        try:
            msg = ch.receive()
        except ChannelClosed:
            break

        if msg == 'body_done':
            break
        elif isinstance(msg, tuple) and msg[0] == 'body_chunk':
            chunk = msg[1]
            if isinstance(chunk, bytes):
                chunks.append(chunk)
            elif isinstance(chunk, str):
                chunks.append(chunk.encode('utf-8'))

    return b''.join(chunks)


def _process_wsgi_request(caller_pid, app, req_info, body) -> None:
    """Process a single WSGI request and send response to caller."""
    wsgi_input = None

    try:
        # Build environ with body
        req_tuple = _build_req_tuple_with_body(req_info, body)
        environ = _create_environ(req_tuple)
        wsgi_input = environ.get('_hornbeam.wsgi_input')

        # Create response handler
        response = _Response()

        # Call WSGI app
        result = app(environ, response.start_response)

        # Parse status code
        status_code = 500
        if response.status:
            try:
                status_str = response.status
                if isinstance(status_str, bytes):
                    status_str = status_str.decode('utf-8')
                parts = status_str.split(' ', 1)
                status_code = int(parts[0])
            except (ValueError, IndexError):
                pass

        # Send headers
        reply(caller_pid, ('headers', status_code, response.headers))

        # Send write() buffer content first
        for chunk in response._write_buffer:
            if chunk:
                if isinstance(chunk, str):
                    chunk = chunk.encode('utf-8')
                reply(caller_pid, ('chunk', chunk))

        # Stream body chunks
        try:
            if isinstance(result, (bytes, bytearray)):
                reply(caller_pid, ('chunk', bytes(result)))
            else:
                for chunk in result:
                    if chunk:
                        if isinstance(chunk, str):
                            chunk = chunk.encode('utf-8')
                        elif isinstance(chunk, bytearray):
                            chunk = bytes(chunk)
                        reply(caller_pid, ('chunk', chunk))
        finally:
            if hasattr(result, 'close'):
                result.close()

        # Signal completion
        reply(caller_pid, 'done')

    except Exception as e:
        try:
            reply(caller_pid, ('error', str(e)))
        except Exception:
            pass
    finally:
        # Return BytesIO to pool
        if wsgi_input is not None:
            _return_bytesio(wsgi_input)


def _build_req_tuple_with_body(req_info, body) -> tuple:
    """Build request tuple from req_info dict and body.

    Args:
        req_info: Dict with request metadata (method, path, headers, etc.)
        body: Request body bytes

    Returns:
        Tuple in the format expected by _create_environ
    """
    # Handle body
    if body is None or body == b'':
        body_bytes = b''
    elif isinstance(body, bytes):
        body_bytes = body
    elif isinstance(body, str):
        body_bytes = body.encode('utf-8')
    else:
        body_bytes = b''

    # Extract fields from req_info (map from Erlang)
    method = req_info.get(b'method', b'GET')
    script_name = req_info.get(b'script_name', b'')
    path_info = req_info.get(b'path_info', b'/')
    query_string = req_info.get(b'query_string', b'')
    wsgi_headers = req_info.get(b'wsgi_headers', {})
    content_type = req_info.get(b'content_type')
    content_length = req_info.get(b'content_length')
    server = req_info.get(b'server', (b'localhost', 80))
    client = req_info.get(b'client', (b'127.0.0.1', 0))
    scheme = req_info.get(b'scheme', b'http')
    protocol = req_info.get(b'protocol', b'HTTP/1.1')
    lifespan_state = req_info.get(b'lifespan_state', {})

    return (
        method, script_name, path_info, query_string, wsgi_headers,
        content_type, content_length, body_bytes, server, client, scheme,
        protocol, lifespan_state
    )


def handle_request_fast(caller_pid, app_module: str, app_callable: str,
                        req_tuple) -> None:
    """Handle a WSGI request with pre-parsed tuple (no channel).

    This is an alternative entry point that receives the request tuple
    directly, bypassing channel overhead for simple requests.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing WSGI app
        app_callable: Name of WSGI callable in module
        req_tuple: Pre-parsed request tuple from Erlang
    """
    if not HAS_ERLANG:
        return

    wsgi_input = None

    try:
        # 1. Build WSGI environ directly from tuple
        environ = _create_environ(req_tuple)
        wsgi_input = environ.get('_hornbeam.wsgi_input')

        # 2. Load and call WSGI app
        app = _load_app(app_module, app_callable)
        response = _Response()

        result = app(environ, response.start_response)

        # 3. Parse status code
        status_code = 500
        if response.status:
            try:
                status_str = response.status
                if isinstance(status_str, bytes):
                    status_str = status_str.decode('utf-8')
                parts = status_str.split(' ', 1)
                status_code = int(parts[0])
            except (ValueError, IndexError):
                pass

        # 4. Send headers
        reply(caller_pid, ('headers', status_code, response.headers))

        # 5. Send write() buffer
        for chunk in response._write_buffer:
            if chunk:
                if isinstance(chunk, str):
                    chunk = chunk.encode('utf-8')
                reply(caller_pid, ('chunk', chunk))

        # 6. Stream body
        try:
            if isinstance(result, (bytes, bytearray)):
                reply(caller_pid, ('chunk', bytes(result)))
            else:
                for chunk in result:
                    if chunk:
                        if isinstance(chunk, str):
                            chunk = chunk.encode('utf-8')
                        elif isinstance(chunk, bytearray):
                            chunk = bytes(chunk)
                        reply(caller_pid, ('chunk', chunk))
        finally:
            if hasattr(result, 'close'):
                result.close()

        # 7. Signal completion
        reply(caller_pid, 'done')

    except Exception as e:
        try:
            reply(caller_pid, ('error', str(e)))
        except Exception:
            pass
    finally:
        if wsgi_input is not None:
            _return_bytesio(wsgi_input)
