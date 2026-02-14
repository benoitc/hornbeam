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
"""

import importlib
import io
import sys

# Cache for loaded application callables
_app_cache = {}


def load_app(module_name, callable_name):
    """Load a WSGI application (no caching to handle reloads)."""
    # Force reload if already imported to handle path changes
    if module_name in sys.modules:
        del sys.modules[module_name]
    module = importlib.import_module(module_name)
    return getattr(module, callable_name)


def clear_cache():
    """Clear the application cache."""
    global _app_cache
    _app_cache = {}


def run_wsgi(module_name, callable_name, environ):
    """Run a WSGI application and return the response.

    Args:
        module_name: Python module containing the WSGI app
        callable_name: Name of the WSGI callable in the module
        environ: WSGI environ dict

    Returns:
        Tuple of (status, headers, body)
    """
    # Load the application
    app = load_app(module_name, callable_name)

    # Convert wsgi.input to BytesIO if needed
    if 'wsgi.input' in environ:
        wsgi_input = environ['wsgi.input']
        if isinstance(wsgi_input, bytes):
            environ['wsgi.input'] = io.BytesIO(wsgi_input)
        elif isinstance(wsgi_input, str):
            # Binary from Erlang may come as string
            environ['wsgi.input'] = io.BytesIO(wsgi_input.encode('utf-8'))
        elif not hasattr(wsgi_input, 'read'):
            # Ensure it's a file-like object
            environ['wsgi.input'] = io.BytesIO(b'')

    # Capture start_response
    response_status = [None]
    response_headers = [None]

    def start_response(status, headers, exc_info=None):
        if exc_info:
            try:
                if response_status[0] is not None:
                    raise exc_info[1].with_traceback(exc_info[2])
            finally:
                exc_info = None
        elif response_status[0] is not None:
            raise RuntimeError("start_response already called")

        response_status[0] = status
        response_headers[0] = headers
        return lambda s: None  # write() callable (deprecated)

    # Call the WSGI app
    result = app(environ, start_response)

    # Collect body
    try:
        if isinstance(result, (bytes, bytearray)):
            body = bytes(result)
        else:
            body = b''.join(result)
    finally:
        if hasattr(result, 'close'):
            result.close()

    return {
        'status': response_status[0],
        'headers': response_headers[0],
        'body': body
    }
