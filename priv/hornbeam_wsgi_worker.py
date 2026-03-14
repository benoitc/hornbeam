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

"""Simplified WSGI worker using unified channel-based approach.

This module provides a WSGI worker with:
- Single entry point for all requests
- Channel-based body delivery via ChannelBuffer (file-like object)
- Clear schedule_inline phases for yielding

Architecture:
1. Erlang sends body via channel (single {body, Data} or streamed chunks)
2. Python phases using schedule_inline:
   - Phase 1: handle_request - setup ChannelBuffer, call app, schedule iteration
   - Phase 2: _iterate_response - send response chunks, yield every N chunks
"""

import io
import threading
from typing import Callable, Dict, List, Optional, Tuple

try:
    import erlang
    from erlang import reply, Channel
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False
    erlang = None
    reply = None
    Channel = None


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
# ChannelBuffer - BufferedIOBase backed by channel
# ============================================================================

class ChannelBuffer(io.BufferedIOBase):
    """Buffered IO object that reads body from Erlang channel.

    Inherits from io.BufferedIOBase for proper file-like interface.
    Supports both single-message bodies ({body, Data}) and
    streaming bodies ({body_chunk, Chunk}... body_done).
    """

    def __init__(self, channel):
        self._channel = channel
        self._buffer = b''
        self._eof = False
        self._closed = False

    def readable(self) -> bool:
        return True

    def writable(self) -> bool:
        return False

    def seekable(self) -> bool:
        return False

    @property
    def closed(self) -> bool:
        return self._closed

    def read(self, size: int = -1) -> bytes:
        """Read up to size bytes from the body."""
        if self._closed:
            raise ValueError("I/O operation on closed file")

        if self._eof and not self._buffer:
            return b''

        # If we have enough in buffer, return it
        if size > 0 and len(self._buffer) >= size:
            result = self._buffer[:size]
            self._buffer = self._buffer[size:]
            return result

        # Need to read more from channel
        self._fill_buffer(size)

        # Return requested amount
        if size is None or size < 0:
            result = self._buffer
            self._buffer = b''
        else:
            result = self._buffer[:size]
            self._buffer = self._buffer[size:]

        return result

    def read1(self, size: int = -1) -> bytes:
        """Read up to size bytes with at most one channel read."""
        if self._closed:
            raise ValueError("I/O operation on closed file")

        if self._eof and not self._buffer:
            return b''

        # If buffer is empty, do one read from channel
        if not self._buffer and not self._eof:
            self._pull_one()

        # Return what we have (up to size)
        if size is None or size < 0:
            result = self._buffer
            self._buffer = b''
        else:
            result = self._buffer[:size]
            self._buffer = self._buffer[size:]

        return result

    def readinto(self, b) -> int:
        """Read bytes into a pre-allocated buffer."""
        data = self.read(len(b))
        n = len(data)
        b[:n] = data
        return n

    def readinto1(self, b) -> int:
        """Read bytes into buffer with at most one channel read."""
        data = self.read1(len(b))
        n = len(data)
        b[:n] = data
        return n

    def _pull_one(self):
        """Pull one message from channel."""
        if self._eof:
            return

        try:
            msg = self._channel.receive(timeout_ms=30000)
        except Exception:
            self._eof = True
            return

        if msg == b'body_done' or msg == 'body_done':
            self._eof = True
        elif isinstance(msg, tuple) and len(msg) >= 2:
            tag, data = msg[0], msg[1]
            if tag in (b'body', 'body'):
                # Complete body in one message
                if isinstance(data, bytes):
                    self._buffer += data
                elif isinstance(data, str):
                    self._buffer += data.encode('utf-8')
                self._eof = True
            elif tag in (b'body_chunk', 'body_chunk'):
                if isinstance(data, bytes):
                    self._buffer += data
                elif isinstance(data, str):
                    self._buffer += data.encode('utf-8')

    def _fill_buffer(self, target_size: int = -1):
        """Fill buffer from channel until we have enough or EOF."""
        while not self._eof:
            if target_size > 0 and len(self._buffer) >= target_size:
                break
            self._pull_one()

    def readline(self, size: int = -1) -> bytes:
        """Read a line from the body."""
        if self._closed:
            raise ValueError("I/O operation on closed file")

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

    def close(self):
        """Close the buffer."""
        if not self._closed:
            self._eof = True
            self._buffer = b''
            self._closed = True
            super().close()


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
# Phase 1: Entry point - setup and call app
# ============================================================================

def handle_request(caller_pid, channel_ref, app_module: bytes, app_callable: bytes, environ_map: dict):
    """Entry point - setup ChannelBuffer, call app, iterate response.

    Args:
        caller_pid: Erlang PID to send response to
        channel_ref: Channel reference for receiving body
        app_module: Python module containing WSGI app (bytes)
        app_callable: Name of WSGI callable in module (bytes)
        environ_map: Pre-built environ dict from Erlang

    Returns:
        'done' on success, or schedule_inline marker for continuation
    """
    if not HAS_ERLANG:
        return b'error'

    try:
        # Wrap channel reference
        channel = Channel(channel_ref)

        # Convert bytes to strings
        module_name = app_module.decode('utf-8') if isinstance(app_module, bytes) else app_module
        callable_name = app_callable.decode('utf-8') if isinstance(app_callable, bytes) else app_callable

        # Process environ (convert bytes to strings)
        environ = _process_environ(environ_map)

        # Create ChannelBuffer as wsgi.input
        wsgi_input = ChannelBuffer(channel)
        environ['wsgi.input'] = wsgi_input
        environ['wsgi.errors'] = _SHARED_ERRORS

        # Load and call app
        app = _load_app(module_name, callable_name)
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

        # Call iterate_response directly (not via schedule_inline)
        # schedule_inline is only used for continuation within iteration
        return _iterate_response(state)

    except Exception as e:
        try:
            reply(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass
        return b'error'


# ============================================================================
# Phase 2: Iterate response
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
            reply(caller, (b'response', state['status'], state['headers'], body))
            _cleanup_result(result)
            return b'done'

        # Send any buffered write() data first
        if write_buffer and not headers_sent:
            reply(caller, (b'start_response', state['status'], state['headers']))
            state['headers_sent'] = True
            for part in write_buffer:
                reply(caller, (b'chunk', _to_bytes(part)))
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
                    reply(caller, (b'start_response', state['status'], state['headers']))
                    state['headers_sent'] = True

                reply(caller, (b'chunk', chunk))
                chunks_processed += 1

                # Yield after batch to release scheduler
                if chunks_processed >= CHUNKS_PER_BATCH:
                    return erlang.schedule_inline(
                        'hornbeam_wsgi_worker', '_iterate_response',
                        args=[state]
                    )

        # Done iterating
        if state['headers_sent']:
            reply(caller, b'done')
        else:
            # Empty response (no chunks produced)
            reply(caller, (b'response', state['status'], state['headers'], b''))

        _cleanup_result(result)
        return b'done'

    except Exception as e:
        _cleanup_result(state.get('result'))
        try:
            reply(caller, (b'error', str(e).encode('utf-8')))
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
