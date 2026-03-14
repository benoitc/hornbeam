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

"""WSGI worker using py_buffer for zero-copy request body streaming.

This module provides a WSGI worker with:
- Single entry point for all requests
- py_buffer as wsgi.input (zero-copy shared memory)
- erlang.send for responses

Architecture:
1. Erlang creates py_buffer and writes body data
2. Python uses buffer directly as wsgi.input (file-like interface)
3. Python sends responses via erlang.send()
"""

import io
import threading
from typing import Callable, Dict, Tuple

try:
    import erlang
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False
    erlang = None


# ============================================================================
# Constants and shared instances
# ============================================================================

_WSGI_VERSION = (1, 0)
CHUNKS_PER_BATCH = 10


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
# App loading and preloading
# ============================================================================

# Cached app reference - set by preload_app() for fast access
_preloaded_app: Callable = None
_preloaded_key: Tuple[str, str] = None


def preload_app(app_module: bytes, app_callable: bytes) -> bytes:
    """Preload WSGI application at startup for zero-overhead access.

    Called from Erlang during context initialization.
    """
    global _preloaded_app, _preloaded_key

    module_name = app_module.decode('utf-8') if isinstance(app_module, bytes) else app_module
    callable_name = app_callable.decode('utf-8') if isinstance(app_callable, bytes) else app_callable

    import importlib
    module = importlib.import_module(module_name)
    app = getattr(module, callable_name)

    _preloaded_app = app
    _preloaded_key = (module_name, callable_name)

    return b'ok'


def _get_app(module_name: str, callable_name: str) -> Callable:
    """Get WSGI application - uses preloaded app if available."""
    # Fast path: use preloaded app if it matches
    if _preloaded_key == (module_name, callable_name):
        return _preloaded_app

    # Fallback: import on demand
    import importlib
    module = importlib.import_module(module_name)
    return getattr(module, callable_name)


# ============================================================================
# Helpers
# ============================================================================

def _to_bytes(val) -> bytes:
    """Convert value to bytes."""
    if isinstance(val, bytes):
        return val
    if isinstance(val, bytearray):
        return bytes(val)
    if isinstance(val, str):
        return val.encode('utf-8')
    return b''


def _parse_status(status_str) -> int:
    """Parse WSGI status string to integer."""
    try:
        if isinstance(status_str, bytes):
            status_str = status_str.decode('utf-8')
        parts = status_str.split(' ', 1)
        return int(parts[0])
    except (ValueError, IndexError, AttributeError):
        return 500


def _process_environ(environ_map: dict) -> dict:
    """Convert all binary keys/values to strings."""
    environ = _ENVIRON_TEMPLATE.copy()

    for key, value in environ_map.items():
        str_key = key.decode('utf-8') if isinstance(key, bytes) else str(key)
        if isinstance(value, bytes):
            str_value = value.decode('utf-8', errors='replace')
        elif value is None or (hasattr(value, '__class__') and value.__class__.__name__ == 'Atom'):
            str_value = ''
        else:
            str_value = str(value) if not isinstance(value, str) else value
        environ[str_key] = str_value

    return environ


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
# Entry point - setup and call app
# ============================================================================

def handle_request(caller_pid, buffer, app_module: bytes, app_callable: bytes, environ_map: dict):
    """Entry point - use py_buffer as wsgi.input, call app.

    Args:
        caller_pid: Erlang PID to send response to
        buffer: py_buffer for request body, or 'empty' atom for bodyless requests
        app_module: Python module containing WSGI app (bytes)
        app_callable: Name of WSGI callable in module (bytes)
        environ_map: Pre-built environ dict from Erlang

    Returns:
        'done' on success, or schedule_inline marker for continuation
    """
    if not HAS_ERLANG:
        return b'error'

    try:
        # Convert bytes to strings
        module_name = app_module.decode('utf-8') if isinstance(app_module, bytes) else app_module
        callable_name = app_callable.decode('utf-8') if isinstance(app_callable, bytes) else app_callable

        # Process environ (convert bytes to strings)
        environ = _process_environ(environ_map)

        # Use buffer as wsgi.input, or empty BytesIO for bodyless requests
        if buffer == b'empty' or (hasattr(buffer, '__class__') and buffer.__class__.__name__ == 'Atom'):
            environ['wsgi.input'] = io.BytesIO()
        else:
            environ['wsgi.input'] = buffer
        environ['wsgi.errors'] = _SHARED_ERRORS

        # Call app in separate function (allows schedule_inline continuation)
        return _call_app(caller_pid, module_name, callable_name, environ)

    except Exception as e:
        try:
            erlang.send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass
        return b'error'


def _call_app(caller_pid, module_name: str, callable_name: str, environ: dict):
    """Call WSGI app and iterate response.

    Args:
        caller_pid: Erlang PID to send response to
        module_name: Python module name
        callable_name: WSGI callable name
        environ: Prepared environ dict with wsgi.input

    Returns:
        'done' on success, or schedule_inline marker for continuation
    """
    try:
        # Get app (preloaded or import on demand)
        app = _get_app(module_name, callable_name)
        response = _Response()
        result = app(environ, response.start_response)

        # Build state for response iteration
        state = {
            'caller': caller_pid,
            'status': response.status_code,
            'headers': response.headers,
            'result': result,
            'result_iter': iter(result) if hasattr(result, '__iter__') else None,
            'write_buffer': list(response._write_buffer),
            'headers_sent': False,
        }

        # Call iterate_response directly
        return _iterate_response(state)

    except Exception as e:
        try:
            erlang.send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass
        return b'error'


# ============================================================================
# Iterate response
# ============================================================================

def _iterate_response(state: dict):
    """Send response chunks, yielding every CHUNKS_PER_BATCH.

    Args:
        state: Dict containing caller, status, headers, result iterator, etc.

    Returns:
        'done' or schedule_inline marker for continuation
    """
    caller = state['caller']
    result = state['result']
    result_iter = state['result_iter']
    write_buffer = state['write_buffer']
    headers_sent = state['headers_sent']

    try:
        # Handle single bytes response
        if result_iter is None or isinstance(result, (bytes, bytearray)):
            body = _to_bytes(result) if isinstance(result, (bytes, bytearray)) else b''
            if write_buffer:
                body = b''.join(_to_bytes(p) for p in write_buffer) + body
            erlang.send(caller, (b'response', state['status'], state['headers'], body))
            _cleanup_result(result)
            return b'done'

        # Fast path: list with small number of items - collect and send as single response
        if isinstance(result, list) and len(result) <= 2 and not write_buffer:
            body = b''.join(_to_bytes(chunk) for chunk in result if chunk)
            erlang.send(caller, (b'response', state['status'], state['headers'], body))
            _cleanup_result(result)
            return b'done'

        # Send any buffered write() data first
        if write_buffer and not headers_sent:
            erlang.send(caller, (b'start_response', state['status'], state['headers']))
            state['headers_sent'] = True
            for part in write_buffer:
                erlang.send(caller, (b'chunk', _to_bytes(part)))
            state['write_buffer'] = []

        # Process chunks from iterator
        chunks_processed = 0

        while True:
            try:
                chunk = next(result_iter)
            except StopIteration:
                break

            if chunk:
                chunk = _to_bytes(chunk)

                # Send headers on first chunk
                if not state['headers_sent']:
                    erlang.send(caller, (b'start_response', state['status'], state['headers']))
                    state['headers_sent'] = True

                erlang.send(caller, (b'chunk', chunk))
                chunks_processed += 1

                # Yield after batch to release scheduler
                if chunks_processed >= CHUNKS_PER_BATCH:
                    return erlang.schedule_inline(
                        'hornbeam_wsgi_worker', '_iterate_response',
                        args=[state]
                    )

        # Done iterating
        if state['headers_sent']:
            erlang.send(caller, b'done')
        else:
            # Empty response (no chunks produced)
            erlang.send(caller, (b'response', state['status'], state['headers'], b''))

        _cleanup_result(result)
        return b'done'

    except Exception as e:
        _cleanup_result(state.get('result'))
        try:
            erlang.send(caller, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass
        return b'error'


def _cleanup_result(result):
    """Close result iterator if it has a close method."""
    if result and hasattr(result, 'close'):
        try:
            result.close()
        except Exception:
            pass
