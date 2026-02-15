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


def load_app(module_name, callable_name):
    """Load a WSGI application.

    Args:
        module_name: Python module name
        callable_name: Name of the WSGI callable

    Returns:
        The WSGI application callable
    """
    # Force reload if already imported to handle path changes
    if module_name in sys.modules:
        del sys.modules[module_name]
    module = importlib.import_module(module_name)
    return getattr(module, callable_name)


def create_environ(raw_environ):
    """Create a complete WSGI environ dict from raw environ.

    Ensures all required WSGI variables are present and properly typed.

    Args:
        raw_environ: Raw environ dict from Erlang

    Returns:
        Complete WSGI environ dict
    """
    # Create errors stream
    errors = WSGIErrorsWrapper()

    # Create early hints callback
    early_hints_list = []

    def early_hints_callback(headers):
        """Callback for wsgi.early_hints."""
        early_hints_list.append(headers)

    # Build environ with proper types
    environ = {
        # Required CGI variables with defaults
        'REQUEST_METHOD': raw_environ.get('REQUEST_METHOD', 'GET'),
        'SCRIPT_NAME': raw_environ.get('SCRIPT_NAME', ''),
        'PATH_INFO': raw_environ.get('PATH_INFO', '/'),
        'QUERY_STRING': raw_environ.get('QUERY_STRING', ''),
        'SERVER_NAME': raw_environ.get('SERVER_NAME', 'localhost'),
        'SERVER_PORT': str(raw_environ.get('SERVER_PORT', '80')),
        'SERVER_PROTOCOL': raw_environ.get('SERVER_PROTOCOL', 'HTTP/1.1'),

        # Required WSGI variables
        'wsgi.version': (1, 0),
        'wsgi.url_scheme': raw_environ.get('wsgi.url_scheme', 'http'),
        'wsgi.input': io.BytesIO(b''),  # Will be replaced below
        'wsgi.errors': errors,
        'wsgi.multithread': True,
        'wsgi.multiprocess': True,
        'wsgi.run_once': False,

        # Recommended extensions
        'wsgi.file_wrapper': FileWrapper,
        'wsgi.input_terminated': True,
        'wsgi.early_hints': early_hints_callback,
    }

    # Copy remaining keys (HTTP_*, CONTENT_TYPE, CONTENT_LENGTH, etc.)
    for key, value in raw_environ.items():
        if key not in environ:
            # Convert binary keys/values to strings if needed
            if isinstance(key, bytes):
                key = key.decode('utf-8', errors='replace')
            if isinstance(value, bytes):
                value = value.decode('utf-8', errors='replace')
            environ[key] = value

    # Handle wsgi.input specially
    wsgi_input = raw_environ.get('wsgi.input', b'')
    if isinstance(wsgi_input, bytes):
        environ['wsgi.input'] = io.BytesIO(wsgi_input)
    elif isinstance(wsgi_input, str):
        environ['wsgi.input'] = io.BytesIO(wsgi_input.encode('utf-8'))
    elif hasattr(wsgi_input, 'read'):
        environ['wsgi.input'] = wsgi_input
    else:
        environ['wsgi.input'] = io.BytesIO(b'')

    # Ensure CONTENT_TYPE and CONTENT_LENGTH are strings
    if 'CONTENT_TYPE' in environ and environ['CONTENT_TYPE'] is not None:
        environ['CONTENT_TYPE'] = str(environ['CONTENT_TYPE'])
    if 'CONTENT_LENGTH' in environ and environ['CONTENT_LENGTH'] is not None:
        environ['CONTENT_LENGTH'] = str(environ['CONTENT_LENGTH'])

    # Store early hints list reference for later retrieval
    environ['_hornbeam.early_hints'] = early_hints_list

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
