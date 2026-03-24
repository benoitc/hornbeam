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

# BytesIO pool for wsgi.input - reduces allocation overhead
_BYTESIO_POOL = []
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
    """Return a BytesIO to the pool for reuse."""
    with _BYTESIO_POOL_LOCK:
        if len(_BYTESIO_POOL) < _BYTESIO_POOL_SIZE:
            _BYTESIO_POOL.append(bio)


# Pre-computed environ template - shared base for all requests
_ENVIRON_TEMPLATE = {
    'wsgi.version': _WSGI_VERSION,
    'wsgi.multithread': True,
    'wsgi.multiprocess': True,
    'wsgi.run_once': False,
    'wsgi.file_wrapper': FileWrapper,
    'wsgi.input_terminated': True,
}


def create_environ(raw_environ):
    """Create a complete WSGI environ dict from raw environ.

    Ensures all required WSGI variables are present and properly typed.
    Optimized for minimal overhead on hot path using template and BytesIO pool.

    Args:
        raw_environ: Raw environ dict from Erlang

    Returns:
        Complete WSGI environ dict
    """
    # Create early hints callback (must be per-request)
    early_hints_list = []

    def early_hints_callback(headers):
        early_hints_list.append(headers)

    # Handle wsgi.input - use pooled BytesIO for common bytes case
    wsgi_input = raw_environ.get('wsgi.input', b'')
    wsgi_input_type = type(wsgi_input)
    if wsgi_input_type is bytes:
        wsgi_input_stream = _get_bytesio(wsgi_input)
    elif wsgi_input_type is str:
        wsgi_input_stream = _get_bytesio(wsgi_input.encode('utf-8'))
    elif hasattr(wsgi_input, 'read'):
        wsgi_input_stream = wsgi_input
    else:
        wsgi_input_stream = _get_bytesio(b'')

    # Start from template copy (faster than inline dict creation)
    environ = _ENVIRON_TEMPLATE.copy()

    # Update with request-specific required CGI variables
    environ['REQUEST_METHOD'] = raw_environ.get('REQUEST_METHOD', 'GET')
    environ['SCRIPT_NAME'] = raw_environ.get('SCRIPT_NAME', '')
    environ['PATH_INFO'] = raw_environ.get('PATH_INFO', '/')
    environ['QUERY_STRING'] = raw_environ.get('QUERY_STRING', '')
    environ['SERVER_NAME'] = raw_environ.get('SERVER_NAME', 'localhost')
    environ['SERVER_PORT'] = str(raw_environ.get('SERVER_PORT', '80'))
    environ['SERVER_PROTOCOL'] = raw_environ.get('SERVER_PROTOCOL', 'HTTP/1.1')

    # Request-specific WSGI variables
    environ['wsgi.url_scheme'] = raw_environ.get('wsgi.url_scheme', 'http')
    environ['wsgi.input'] = wsgi_input_stream
    environ['wsgi.errors'] = _SHARED_ERRORS
    environ['wsgi.early_hints'] = early_hints_callback

    # Store references for cleanup and early hints
    environ['_hornbeam.early_hints'] = early_hints_list
    environ['_hornbeam.wsgi_input'] = wsgi_input_stream

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
        # Return BytesIO to pool
        wsgi_input = environ.get('_hornbeam.wsgi_input')
        if wsgi_input is not None:
            _return_bytesio(wsgi_input)

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


def create_environ_from_tuple(req_tuple):
    """Create WSGI environ from pre-parsed Erlang tuple - O(1) operations only.

    This is the fast path for WSGI requests. Erlang pre-parses all headers
    into WSGI format so Python only does dict updates (no loops).

    Args:
        req_tuple: Pre-parsed request tuple from hornbeam_request:build_wsgi_tuple/2
            (method, script_name, path_info, query_string, wsgi_headers,
             content_type, content_length, body, server, client, scheme,
             protocol, lifespan_state)

    Returns:
        Complete WSGI environ dict
    """
    (method, script_name, path_info, query_string, wsgi_headers,
     content_type, content_length, body, server, client, scheme,
     protocol, lifespan_state) = req_tuple

    # Create early hints callback (must be per-request)
    early_hints_list = []

    def early_hints_callback(headers):
        early_hints_list.append(headers)

    # Get BytesIO from pool
    wsgi_input = _get_bytesio(body if body.__class__ is bytes else b'')

    # Start with template copy (O(1) - shallow copy of small dict)
    environ = _ENVIRON_TEMPLATE.copy()

    # Update with request-specific values (no loops!)
    environ['REQUEST_METHOD'] = method
    environ['SCRIPT_NAME'] = script_name if script_name else ''
    environ['PATH_INFO'] = path_info
    environ['QUERY_STRING'] = query_string
    environ['SERVER_NAME'] = server[0]
    environ['SERVER_PORT'] = str(server[1])
    environ['SERVER_PROTOCOL'] = protocol
    environ['wsgi.url_scheme'] = scheme
    environ['wsgi.input'] = wsgi_input
    environ['wsgi.errors'] = _SHARED_ERRORS
    environ['wsgi.early_hints'] = early_hints_callback
    environ['REMOTE_ADDR'] = client[0]
    environ['REMOTE_PORT'] = str(client[1])
    environ['_hornbeam.early_hints'] = early_hints_list
    environ['_hornbeam.wsgi_input'] = wsgi_input  # For pool return
    environ['_hornbeam.lifespan_state'] = lifespan_state

    # Add pre-converted HTTP_* headers (already in correct format from Erlang)
    environ.update(wsgi_headers)

    # Add content-type/length if present
    if content_type is not None:
        environ['CONTENT_TYPE'] = content_type
    if content_length is not None:
        environ['CONTENT_LENGTH'] = content_length

    return environ


def run_wsgi_fast(module_name, callable_name, req_tuple):
    """Run WSGI app with pre-parsed request tuple - fastest path.

    Args:
        module_name: Python module containing the WSGI app
        callable_name: Name of the WSGI callable
        req_tuple: Pre-parsed request tuple from Erlang

    Returns:
        Dict with status, headers, body, and optional early_hints
    """
    # Load the application
    app = load_app(module_name, callable_name)

    # Create environ from pre-parsed tuple
    environ = create_environ_from_tuple(req_tuple)

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
        # Return BytesIO to pool
        wsgi_input = environ.get('_hornbeam.wsgi_input')
        if wsgi_input is not None:
            _return_bytesio(wsgi_input)

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
