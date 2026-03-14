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

"""High-performance WSGI worker using schedule_inline.

This module provides a WSGI worker that uses erlang.schedule_inline()
to release the dirty scheduler between processing steps, enabling
better concurrency.

Architecture:
1. Erlang calls handle_wsgi() with request data
2. Python processes request, yielding via schedule_inline when needed
3. Response sent via erlang.reply() - streaming or buffered
4. schedule_inline continues processing without message passing overhead

Key optimizations:
- No channel overhead for simple requests
- schedule_inline releases dirty scheduler (~3x faster than messaging)
- Streaming support for large bodies
- BytesIO pooling for request bodies
"""

import io
import threading
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import erlang
    from erlang import reply
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False
    erlang = None
    reply = None


# ============================================================================
# Constants and shared instances
# ============================================================================

_WSGI_VERSION = (1, 0)


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


_SHARED_ERRORS = _WSGIErrorsWrapper()

_ENVIRON_TEMPLATE = {
    'wsgi.version': _WSGI_VERSION,
    'wsgi.multithread': True,
    'wsgi.multiprocess': True,
    'wsgi.run_once': False,
    'wsgi.file_wrapper': FileWrapper,
    'wsgi.input_terminated': True,
}


# ============================================================================
# BytesIO pool
# ============================================================================

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
            bio.seek(0)
            bio.truncate()
            _BYTESIO_POOL.append(bio)


# ============================================================================
# App loading
# ============================================================================

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


# ============================================================================
# Helpers
# ============================================================================

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


def _parse_status(status_str) -> int:
    """Parse WSGI status string to integer."""
    try:
        if isinstance(status_str, bytes):
            status_str = status_str.decode('utf-8')
        parts = status_str.split(' ', 1)
        return int(parts[0])
    except (ValueError, IndexError, AttributeError):
        return 500


# ============================================================================
# Response class
# ============================================================================

class _Response:
    """WSGI response handler."""
    __slots__ = ('status', 'status_code', 'headers', '_write_buffer')

    def __init__(self):
        self.status = None
        self.status_code = 500
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
        self.status_code = _parse_status(status)
        self.headers = list(response_headers)
        return self._write

    def _write(self, data):
        if not self.status:
            raise RuntimeError("write() called before start_response()")
        self._write_buffer.append(data)


# ============================================================================
# Main entry point: handle_wsgi with schedule_inline
# ============================================================================

def handle_wsgi(caller_pid, app_module: bytes, app_callable: bytes,
                environ_map: dict, body: bytes):
    """Handle a WSGI request using schedule_inline for yielding.

    This is the main entry point called from Erlang via context_call.
    Uses schedule_inline to release the dirty scheduler between steps.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing WSGI app (bytes)
        app_callable: Name of WSGI callable in module (bytes)
        environ_map: Pre-built environ dict from Erlang
        body: Request body bytes

    Returns:
        'done' on success, or schedule_inline marker for continuation
    """
    if not HAS_ERLANG:
        return b'error'

    # Convert bytes to strings
    module_name = app_module.decode('utf-8') if isinstance(app_module, bytes) else app_module
    callable_name = app_callable.decode('utf-8') if isinstance(app_callable, bytes) else app_callable

    # Build state for potential continuation
    state = {
        'caller': caller_pid,
        'module': module_name,
        'callable': callable_name,
        'environ_map': environ_map,
        'body': body,
        'phase': 'init',
    }

    return _wsgi_process(state)


def _wsgi_process(state: dict):
    """Process WSGI request with schedule_inline continuation.

    This function handles the actual WSGI processing and can yield
    via schedule_inline to release the dirty scheduler.
    """
    phase = state.get('phase', 'init')
    caller = state['caller']
    wsgi_input = None

    try:
        if phase == 'init':
            # Build environ
            environ = _build_environ(state['environ_map'], state['body'])
            wsgi_input = environ.get('_hornbeam.wsgi_input')
            state['wsgi_input'] = wsgi_input

            # Load app
            app = _load_app(state['module'], state['callable'])
            response = _Response()

            # Call WSGI app
            result = app(environ, response.start_response)

            # Store result iterator for streaming
            state['response'] = response
            state['result'] = result
            state['result_iter'] = iter(result) if not isinstance(result, (bytes, bytearray)) else None
            state['body_parts'] = list(response._write_buffer)  # Start with write() buffer
            state['total_size'] = sum(len(p) for p in state['body_parts'])
            state['streaming'] = False
            state['phase'] = 'collect'

            # Continue to collection phase
            return _wsgi_collect(state)

        elif phase == 'collect':
            return _wsgi_collect(state)

        elif phase == 'stream':
            return _wsgi_stream(state)

    except Exception as e:
        try:
            reply(caller, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass
        return b'error'

    finally:
        # Return BytesIO to pool if we're done
        if phase == 'done' and 'wsgi_input' in state:
            wsgi_input = state.get('wsgi_input')
            if wsgi_input is not None:
                _return_bytesio(wsgi_input)


def _wsgi_collect(state: dict):
    """Collect response body, switching to streaming if needed."""
    BUFFER_THRESHOLD = 65536
    CHUNK_COUNT_YIELD = 10  # Yield after this many chunks

    caller = state['caller']
    response = state['response']
    result = state['result']
    result_iter = state.get('result_iter')
    body_parts = state['body_parts']
    total_size = state['total_size']
    streaming = state['streaming']
    chunks_processed = 0

    try:
        if isinstance(result, (bytes, bytearray)):
            # Single bytes result
            chunk = bytes(result)
            if total_size + len(chunk) < BUFFER_THRESHOLD:
                body_parts.append(chunk)
                # Send buffered response
                body = b''.join(body_parts)
                reply(caller, (b'response', response.status_code, response.headers, body))
                state['phase'] = 'done'
                return b'done'
            else:
                # Switch to streaming
                reply(caller, (b'headers', response.status_code, response.headers))
                for part in body_parts:
                    reply(caller, (b'chunk', part))
                reply(caller, (b'chunk', chunk))
                reply(caller, b'done')
                state['phase'] = 'done'
                return b'done'
        else:
            # Iterable result - process chunks
            while True:
                try:
                    chunk = next(result_iter)
                except StopIteration:
                    break

                if chunk:
                    if isinstance(chunk, str):
                        chunk = chunk.encode('utf-8')
                    elif isinstance(chunk, bytearray):
                        chunk = bytes(chunk)

                    chunks_processed += 1

                    if not streaming and total_size + len(chunk) < BUFFER_THRESHOLD:
                        body_parts.append(chunk)
                        total_size += len(chunk)
                    else:
                        # Switch to streaming mode
                        if not streaming:
                            reply(caller, (b'headers', response.status_code, response.headers))
                            for part in body_parts:
                                reply(caller, (b'chunk', part))
                            body_parts.clear()
                            streaming = True
                            state['streaming'] = True

                        reply(caller, (b'chunk', chunk))

                    # Yield periodically to let other work run
                    if chunks_processed >= CHUNK_COUNT_YIELD:
                        state['body_parts'] = body_parts
                        state['total_size'] = total_size
                        state['phase'] = 'collect'
                        # Use schedule_inline to release scheduler and continue
                        return erlang.schedule_inline(
                            'hornbeam_wsgi_worker', '_wsgi_collect',
                            args=[state]
                        )

            # Done iterating
            if hasattr(result, 'close'):
                result.close()

            if streaming:
                reply(caller, b'done')
            else:
                body = b''.join(body_parts)
                reply(caller, (b'response', response.status_code, response.headers, body))

            state['phase'] = 'done'
            return b'done'

    except Exception as e:
        if hasattr(result, 'close'):
            try:
                result.close()
            except Exception:
                pass
        reply(caller, (b'error', str(e).encode('utf-8')))
        state['phase'] = 'done'
        return b'error'


def _wsgi_stream(state: dict):
    """Stream remaining response body chunks."""
    # This is called when we've already sent headers and are streaming
    caller = state['caller']
    result_iter = state.get('result_iter')
    CHUNK_COUNT_YIELD = 10
    chunks_processed = 0

    try:
        while True:
            try:
                chunk = next(result_iter)
            except StopIteration:
                break

            if chunk:
                if isinstance(chunk, str):
                    chunk = chunk.encode('utf-8')
                elif isinstance(chunk, bytearray):
                    chunk = bytes(chunk)

                reply(caller, (b'chunk', chunk))
                chunks_processed += 1

                if chunks_processed >= CHUNK_COUNT_YIELD:
                    state['phase'] = 'stream'
                    return erlang.schedule_inline(
                        'hornbeam_wsgi_worker', '_wsgi_stream',
                        args=[state]
                    )

        # Done
        result = state['result']
        if hasattr(result, 'close'):
            result.close()

        reply(caller, b'done')
        state['phase'] = 'done'
        return b'done'

    except Exception as e:
        result = state.get('result')
        if result and hasattr(result, 'close'):
            try:
                result.close()
            except Exception:
                pass
        reply(caller, (b'error', str(e).encode('utf-8')))
        state['phase'] = 'done'
        return b'error'


def _build_environ(environ_map: dict, body: bytes) -> dict:
    """Build WSGI environ from Erlang map and body."""
    # Handle body
    if body is None or body == b'':
        body_bytes = b''
    elif isinstance(body, bytes):
        body_bytes = body
    elif isinstance(body, str):
        body_bytes = body.encode('utf-8')
    else:
        body_bytes = b''

    wsgi_input = _get_bytesio(body_bytes)

    # Build environ from template
    environ = _ENVIRON_TEMPLATE.copy()

    # Copy from environ_map, converting bytes to strings
    for key, value in environ_map.items():
        str_key = key.decode('utf-8') if isinstance(key, bytes) else str(key)
        if isinstance(value, bytes):
            str_value = value.decode('utf-8', errors='replace')
        elif value is None or (hasattr(value, '__class__') and value.__class__.__name__ == 'Atom'):
            str_value = ''
        else:
            str_value = value
        environ[str_key] = str_value

    # Set required WSGI keys
    environ['wsgi.input'] = wsgi_input
    environ['wsgi.errors'] = _SHARED_ERRORS
    environ['_hornbeam.wsgi_input'] = wsgi_input

    return environ


# ============================================================================
# Streaming request body support
# ============================================================================

class StreamingBodyReader:
    """File-like object that reads body chunks from Erlang channel."""

    def __init__(self, channel, content_length: Optional[int] = None):
        self.channel = channel
        self.content_length = content_length
        self._buffer = b''
        self._eof = False
        self._bytes_read = 0

    def read(self, size: int = -1) -> bytes:
        """Read up to size bytes from the body."""
        if self._eof:
            return b''

        # If we have enough in buffer, return it
        if size > 0 and len(self._buffer) >= size:
            result = self._buffer[:size]
            self._buffer = self._buffer[size:]
            self._bytes_read += len(result)
            return result

        # Need to read more from channel
        from erlang import Channel, ChannelClosed

        try:
            while not self._eof:
                if size > 0 and len(self._buffer) >= size:
                    break

                msg = self.channel.receive(timeout_ms=30000)

                if msg == b'body_done' or msg == 'body_done':
                    self._eof = True
                    break
                elif isinstance(msg, tuple) and len(msg) == 2:
                    tag, chunk = msg
                    if tag == b'body_chunk' or tag == 'body_chunk':
                        if isinstance(chunk, bytes):
                            self._buffer += chunk
                        elif isinstance(chunk, str):
                            self._buffer += chunk.encode('utf-8')

        except ChannelClosed:
            self._eof = True

        # Return requested amount
        if size < 0:
            result = self._buffer
            self._buffer = b''
        else:
            result = self._buffer[:size]
            self._buffer = self._buffer[size:]

        self._bytes_read += len(result)
        return result

    def readline(self, size: int = -1) -> bytes:
        """Read a line from the body."""
        # Simple implementation - read until newline
        result = b''
        while True:
            if size > 0 and len(result) >= size:
                break
            chunk = self.read(1)
            if not chunk:
                break
            result += chunk
            if chunk == b'\n':
                break
        return result

    def readlines(self, hint: int = -1) -> List[bytes]:
        """Read all lines from the body."""
        lines = []
        total = 0
        while True:
            line = self.readline()
            if not line:
                break
            lines.append(line)
            total += len(line)
            if hint > 0 and total >= hint:
                break
        return lines

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line


# ============================================================================
# Streaming request body entry point
# ============================================================================

def handle_wsgi_streaming(caller_pid, app_module: bytes, app_callable: bytes,
                          environ_map: dict, channel_ref, content_length: int):
    """Handle a WSGI request with streaming body via channel.

    This entry point is used for large request bodies (> 64KB) that are
    streamed via py_channel instead of buffered.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing WSGI app (bytes)
        app_callable: Name of WSGI callable in module (bytes)
        environ_map: Pre-built environ dict from Erlang
        channel_ref: py_channel reference for receiving body chunks
        content_length: Content-Length header value

    Returns:
        'done' on success, 'error' on failure
    """
    if not HAS_ERLANG:
        return b'error'

    from erlang import Channel

    # Convert bytes to strings
    module_name = app_module.decode('utf-8') if isinstance(app_module, bytes) else app_module
    callable_name = app_callable.decode('utf-8') if isinstance(app_callable, bytes) else app_callable

    try:
        # Create channel wrapper and streaming body reader
        channel = Channel(channel_ref)
        wsgi_input = StreamingBodyReader(channel, content_length)

        # Build environ with streaming input
        environ = _build_environ_streaming(environ_map, wsgi_input, content_length)

        # Load and call WSGI app
        app = _load_app(module_name, callable_name)
        response = _Response()

        result = app(environ, response.start_response)

        # Build state for response processing
        state = {
            'caller': caller_pid,
            'response': response,
            'result': result,
            'result_iter': iter(result) if not isinstance(result, (bytes, bytearray)) else None,
            'body_parts': list(response._write_buffer),
            'total_size': sum(len(p) for p in response._write_buffer),
            'streaming': False,
            'phase': 'collect',
            'wsgi_input': wsgi_input,
            'channel': channel,
        }

        return _wsgi_collect(state)

    except Exception as e:
        try:
            reply(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass
        return b'error'


def _build_environ_streaming(environ_map: dict, wsgi_input, content_length: int) -> dict:
    """Build WSGI environ with streaming body reader."""
    # Build environ from template
    environ = _ENVIRON_TEMPLATE.copy()

    # Copy from environ_map, converting bytes to strings
    for key, value in environ_map.items():
        str_key = key.decode('utf-8') if isinstance(key, bytes) else str(key)
        if isinstance(value, bytes):
            str_value = value.decode('utf-8', errors='replace')
        elif value is None or (hasattr(value, '__class__') and value.__class__.__name__ == 'Atom'):
            str_value = ''
        else:
            str_value = value
        environ[str_key] = str_value

    # Set required WSGI keys with streaming input
    environ['wsgi.input'] = wsgi_input
    environ['wsgi.errors'] = _SHARED_ERRORS

    # Ensure CONTENT_LENGTH is set if provided
    if content_length is not None:
        environ['CONTENT_LENGTH'] = str(content_length)

    return environ


# ============================================================================
# Legacy entry points (for backwards compatibility)
# ============================================================================

def handle_request_direct(args_tuple) -> None:
    """Legacy entry point - redirects to handle_wsgi."""
    if not HAS_ERLANG:
        return

    channel_ref, caller_pid, app_module, app_callable, environ, body = args_tuple

    # Call new implementation
    handle_wsgi(caller_pid, app_module, app_callable, environ, body)
