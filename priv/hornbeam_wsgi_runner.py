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

"""WSGI runner module for hornbeam.

This module handles calling WSGI applications from Erlang.
Adapted from gunicorn (MIT License).
"""

import importlib
import io
import logging
import sys
import threading

# Set up logging for wsgi.errors
logger = logging.getLogger('hornbeam.wsgi')


class FileWrapper:
    """Efficient file serving wrapper for WSGI (wsgi.file_wrapper).

    Adapted from gunicorn (MIT License).
    https://github.com/benoitc/gunicorn

    This wrapper allows efficient file serving by exposing the underlying
    file-like object to the server, which may use sendfile() or similar
    optimizations.
    """

    def __init__(self, filelike, blksize=8192):
        self.filelike = filelike
        self.blksize = blksize
        if hasattr(filelike, 'close'):
            self.close = filelike.close

    def __getitem__(self, key):
        data = self.filelike.read(self.blksize)
        if data:
            return data
        raise IndexError

    def __iter__(self):
        return self

    def __next__(self):
        data = self.filelike.read(self.blksize)
        if data:
            return data
        raise StopIteration


class WSGIErrorsWrapper:
    """Wrapper for wsgi.errors that routes to logging.

    This class wraps the standard error stream to route WSGI errors
    to the Python logging system for better integration with Erlang.
    """

    def __init__(self, logger_instance=None):
        self._logger = logger_instance or logger

    def write(self, msg):
        """Write a message to the error log."""
        # Strip trailing newlines as logging adds its own
        msg = msg.rstrip('\n\r')
        if msg:
            self._logger.error(msg)

    def writelines(self, lines):
        """Write multiple lines to the error log."""
        for line in lines:
            self.write(line)

    def flush(self):
        """Flush the error stream (no-op for logging)."""
        pass


class Response:
    """WSGI response handler with proper start_response handling.

    Adapted from gunicorn (MIT License).
    https://github.com/benoitc/gunicorn

    This class handles the WSGI start_response protocol including:
    - exc_info handling per PEP 3333
    - Headers validation
    - Chunked encoding detection
    - Early hints support
    """

    def __init__(self, request_environ):
        self.environ = request_environ
        self.status = None
        self.headers = []
        self.headers_sent = False
        self.body_chunks = []
        self.early_hints_sent = []
        self._write_buffer = []

    def start_response(self, status, response_headers, exc_info=None):
        """WSGI start_response callable.

        Args:
            status: Status string like "200 OK"
            response_headers: List of (header_name, header_value) tuples
            exc_info: Optional exception info for error handling

        Returns:
            write() callable for legacy response writing
        """
        if exc_info:
            try:
                if self.headers_sent:
                    # Headers already sent, re-raise the exception
                    raise exc_info[1].with_traceback(exc_info[2])
            finally:
                exc_info = None
        elif self.status is not None:
            raise RuntimeError("start_response already called")

        self.status = status
        self.headers = list(response_headers)
        return self._write

    def _write(self, data):
        """Legacy write() callable for WSGI apps.

        Note: Using write() is deprecated in WSGI. Applications should
        return an iterable instead.
        """
        if not self.status:
            raise RuntimeError("write() called before start_response()")
        self._write_buffer.append(data)

    def send_early_hints(self, headers):
        """Send 103 Early Hints response.

        This allows sending hints like Link preload headers before
        the main response, enabling browsers to start fetching
        resources early.

        Args:
            headers: List of (header_name, header_value) tuples
        """
        self.early_hints_sent.append(headers)

    def has_content_length(self):
        """Check if Content-Length header is set."""
        for name, value in self.headers:
            if name.lower() == 'content-length':
                return True
        return False

    def is_chunked(self):
        """Check if response should use chunked transfer encoding.

        Returns True if HTTP/1.1+ and no Content-Length header.
        """
        protocol = self.environ.get('SERVER_PROTOCOL', 'HTTP/1.1')
        if protocol == 'HTTP/1.0':
            return False
        return not self.has_content_length()

    def get_content_length(self):
        """Get Content-Length value if set."""
        for name, value in self.headers:
            if name.lower() == 'content-length':
                return int(value)
        return None


# Thread-safe app cache to avoid race conditions under concurrent load
_app_cache = {}
_app_cache_lock = threading.Lock()


def load_app(module_name, callable_name):
    """Load a WSGI application.

    Args:
        module_name: Python module name
        callable_name: Name of the WSGI callable

    Returns:
        The WSGI application callable
    """
    cache_key = (module_name, callable_name)

    # Fast path: check cache without lock
    if cache_key in _app_cache:
        return _app_cache[cache_key]

    # Slow path: acquire lock and load
    with _app_cache_lock:
        # Double-check after acquiring lock
        if cache_key in _app_cache:
            return _app_cache[cache_key]

        # Import module (don't delete from sys.modules - causes race conditions)
        if module_name not in sys.modules:
            module = importlib.import_module(module_name)
        else:
            module = sys.modules[module_name]

        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


def reload_app(module_name, callable_name):
    """Force reload a WSGI application.

    Use this when the application code has changed on disk.
    """
    cache_key = (module_name, callable_name)
    with _app_cache_lock:
        # Remove from cache
        _app_cache.pop(cache_key, None)
        # Reload module
        if module_name in sys.modules:
            module = importlib.reload(sys.modules[module_name])
        else:
            module = importlib.import_module(module_name)
        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


# Pre-computed set of base environ keys to skip during raw environ copy
_BASE_ENVIRON_KEYS = frozenset({
    'REQUEST_METHOD', 'SCRIPT_NAME', 'PATH_INFO', 'QUERY_STRING',
    'SERVER_NAME', 'SERVER_PORT', 'SERVER_PROTOCOL',
    'wsgi.version', 'wsgi.url_scheme', 'wsgi.input', 'wsgi.errors',
    'wsgi.multithread', 'wsgi.multiprocess', 'wsgi.run_once',
    'wsgi.file_wrapper', 'wsgi.input_terminated', 'wsgi.early_hints',
})

# Shared errors wrapper instance (thread-safe, stateless)
_SHARED_ERRORS = WSGIErrorsWrapper()

# Cached WSGI version tuple
_WSGI_VERSION = (1, 0)


def create_environ(raw_environ):
    """Create a complete WSGI environ dict from raw environ.

    Ensures all required WSGI variables are present and properly typed.
    Optimized for minimal overhead on hot path.

    Args:
        raw_environ: Raw environ dict from Erlang

    Returns:
        Complete WSGI environ dict
    """
    # Create early hints callback (must be per-request)
    early_hints_list = []

    def early_hints_callback(headers):
        early_hints_list.append(headers)

    # Handle wsgi.input - most common case is bytes
    wsgi_input = raw_environ.get('wsgi.input', b'')
    wsgi_input_type = type(wsgi_input)
    if wsgi_input_type is bytes:
        wsgi_input_stream = io.BytesIO(wsgi_input)
    elif wsgi_input_type is str:
        wsgi_input_stream = io.BytesIO(wsgi_input.encode('utf-8'))
    elif hasattr(wsgi_input, 'read'):
        wsgi_input_stream = wsgi_input
    else:
        wsgi_input_stream = io.BytesIO(b'')

    # Build environ with proper types
    # Use direct access for speed on known keys
    environ = {
        # Required CGI variables with defaults
        'REQUEST_METHOD': raw_environ.get('REQUEST_METHOD', 'GET'),
        'SCRIPT_NAME': raw_environ.get('SCRIPT_NAME', ''),
        'PATH_INFO': raw_environ.get('PATH_INFO', '/'),
        'QUERY_STRING': raw_environ.get('QUERY_STRING', ''),
        'SERVER_NAME': raw_environ.get('SERVER_NAME', 'localhost'),
        'SERVER_PORT': str(raw_environ.get('SERVER_PORT', '80')),
        'SERVER_PROTOCOL': raw_environ.get('SERVER_PROTOCOL', 'HTTP/1.1'),

        # Required WSGI variables (use cached/shared where possible)
        'wsgi.version': _WSGI_VERSION,
        'wsgi.url_scheme': raw_environ.get('wsgi.url_scheme', 'http'),
        'wsgi.input': wsgi_input_stream,
        'wsgi.errors': _SHARED_ERRORS,
        'wsgi.multithread': True,
        'wsgi.multiprocess': True,
        'wsgi.run_once': False,

        # Recommended extensions
        'wsgi.file_wrapper': FileWrapper,
        'wsgi.input_terminated': True,
        'wsgi.early_hints': early_hints_callback,

        # Store early hints list reference
        '_hornbeam.early_hints': early_hints_list,
    }

    # Copy remaining keys (HTTP_*, CONTENT_TYPE, CONTENT_LENGTH, etc.)
    # Use pre-computed set for O(1) membership test
    for key, value in raw_environ.items():
        if key not in _BASE_ENVIRON_KEYS:
            # Fast path: most keys are already strings from Erlang
            key_type = type(key)
            if key_type is bytes:
                key = key.decode('utf-8', errors='replace')
            value_type = type(value)
            if value_type is bytes:
                value = value.decode('utf-8', errors='replace')
            environ[key] = value

    # Ensure CONTENT_TYPE and CONTENT_LENGTH are strings (common HTTP headers)
    content_type = environ.get('CONTENT_TYPE')
    if content_type is not None and type(content_type) is not str:
        environ['CONTENT_TYPE'] = str(content_type)
    content_length = environ.get('CONTENT_LENGTH')
    if content_length is not None and type(content_length) is not str:
        environ['CONTENT_LENGTH'] = str(content_length)

    return environ


def run_wsgi(module_name, callable_name, raw_environ):
    """Run a WSGI application and return the response.

    Args:
        module_name: Python module containing the WSGI app
        callable_name: Name of the WSGI callable in the module
        raw_environ: Raw WSGI environ dict from Erlang

    Returns:
        Dict with status, headers, body, and optional early_hints
    """
    # Load the application
    app = load_app(module_name, callable_name)

    # Create complete environ
    environ = create_environ(raw_environ)

    # Create response handler
    response = Response(environ)

    # Call the WSGI app
    result = app(environ, response.start_response)

    # Collect body
    body_parts = []

    # Add any write() buffer content first
    body_parts.extend(response._write_buffer)

    # Check if result is a FileWrapper (for optimized file serving)
    is_file_wrapper = isinstance(result, FileWrapper)

    try:
        if isinstance(result, (bytes, bytearray)):
            body_parts.append(bytes(result))
        else:
            for chunk in result:
                if isinstance(chunk, (bytes, bytearray)):
                    body_parts.append(bytes(chunk))
                elif isinstance(chunk, str):
                    body_parts.append(chunk.encode('utf-8'))
    finally:
        if hasattr(result, 'close'):
            result.close()

    body = b''.join(body_parts)

    # Build response dict
    result_dict = {
        'status': response.status or '500 Internal Server Error',
        'headers': response.headers,
        'body': body,
    }

    # Include early hints if any were sent
    early_hints = environ.get('_hornbeam.early_hints', [])
    if early_hints:
        result_dict['early_hints'] = early_hints

    # Include file wrapper info for potential sendfile optimization
    if is_file_wrapper:
        result_dict['file_wrapper'] = True

    return result_dict


def _run_wsgi_sync(module_name: str, callable_name: str,
                   raw_environ: dict) -> tuple:
    """Optimized WSGI runner returning tuple for efficient marshalling.

    This function returns a tuple (status, headers, body) instead of a dict,
    reducing Python-side overhead. Can be used directly or from a future
    py_wsgi NIF for maximum performance.

    Args:
        module_name: Python module containing the WSGI app
        callable_name: Name of the WSGI callable in the module
        raw_environ: Raw WSGI environ dict from Erlang

    Returns:
        Tuple of (status: str, headers: list, body: bytes)
    """
    result = run_wsgi(module_name, callable_name, raw_environ)
    return (
        result.get('status', '500 Internal Server Error'),
        result.get('headers', []),
        result.get('body', b'')
    )


# =============================================================================
# Streaming Support (for Erlang handler integration)
# =============================================================================

# Import erlang module for message passing
try:
    import erlang
    _has_erlang = True
except ImportError:
    _has_erlang = False


class StreamingResponse(Response):
    """WSGI response handler with streaming support.

    Extends Response to send chunks to Erlang handler via message passing.
    """

    def __init__(self, request_environ, handler_pid, max_pending=3):
        super().__init__(request_environ)
        self.handler_pid = handler_pid
        self.max_pending = max_pending
        self.pending_acks = 0
        self._started = False
        self._ack_condition = threading.Condition()

    def _send_start(self):
        """Send stream_start message to Erlang handler."""
        if self._started or not _has_erlang:
            return
        self._started = True
        erlang.send(self.handler_pid, (
            'stream_start',
            self.status,
            self.headers
        ))

    def _wait_for_ack(self):
        """Wait for ack if too many pending chunks."""
        with self._ack_condition:
            while self.pending_acks >= self.max_pending:
                self._ack_condition.wait(timeout=30.0)

    def _send_chunk(self, chunk, more_body=True):
        """Send a chunk to Erlang handler with flow control."""
        if not _has_erlang:
            return

        self._wait_for_ack()

        erlang.send(self.handler_pid, (
            'stream_chunk',
            chunk,
            more_body
        ))
        with self._ack_condition:
            self.pending_acks += 1

    def ack_received(self):
        """Called when ack received from Erlang."""
        with self._ack_condition:
            self.pending_acks = max(0, self.pending_acks - 1)
            self._ack_condition.notify()


def run_wsgi_streaming(module_name, callable_name, raw_environ, handler_pid,
                       max_pending=3):
    """Run a WSGI application with true response streaming.

    Streams response chunks to the Erlang handler via message passing.
    Supports FileWrapper for sendfile optimization.

    Args:
        module_name: Python module containing the WSGI app
        callable_name: Name of the WSGI callable in the module
        raw_environ: Raw WSGI environ dict from Erlang
        handler_pid: Erlang PID to send chunks to
        max_pending: Max pending chunks before backpressure (default 3)

    Returns:
        Dict with 'ok' or 'error' status
    """
    if not _has_erlang:
        return {'error': 'erlang module not available'}

    try:
        # Load the application
        app = load_app(module_name, callable_name)

        # Create complete environ
        environ = create_environ(raw_environ)

        # Create streaming response handler
        response = StreamingResponse(environ, handler_pid, max_pending)

        # Call the WSGI app
        result = app(environ, response.start_response)

        # Send response start
        response._send_start()

        # Add any write() buffer content first
        for chunk in response._write_buffer:
            if isinstance(chunk, str):
                chunk = chunk.encode('utf-8')
            response._send_chunk(chunk, more_body=True)

        # Check if result is a FileWrapper for optimized file serving
        if isinstance(result, FileWrapper):
            # Try to get file descriptor for sendfile
            filelike = result.filelike
            if hasattr(filelike, 'fileno'):
                try:
                    fd = filelike.fileno()
                    # Send stream_file message for sendfile optimization
                    erlang.send(handler_pid, ('stream_file', fd))
                    return {'ok': True, 'sendfile': True}
                except (io.UnsupportedOperation, OSError):
                    pass
            # Fall through to iterate chunks

        # Iterate result and send chunks
        try:
            if isinstance(result, (bytes, bytearray)):
                response._send_chunk(bytes(result), more_body=False)
            else:
                for chunk in result:
                    if isinstance(chunk, str):
                        chunk = chunk.encode('utf-8')
                    elif isinstance(chunk, bytearray):
                        chunk = bytes(chunk)
                    response._send_chunk(chunk, more_body=True)
                # Send final empty chunk to signal end
                response._send_chunk(b'', more_body=False)
        finally:
            if hasattr(result, 'close'):
                result.close()

        return {'ok': True}

    except Exception as e:
        import traceback
        return {'error': str(e), 'traceback': traceback.format_exc()}
