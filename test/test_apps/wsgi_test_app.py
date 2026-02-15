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

"""WSGI test application with various endpoints for testing."""

import json
import time
import traceback


def application(environ, start_response):
    """WSGI application for testing various HTTP scenarios."""
    path = environ.get('PATH_INFO', '/')
    method = environ.get('REQUEST_METHOD', 'GET')

    try:
        # Route to appropriate handler
        if path == '/':
            return handle_hello(environ, start_response)
        elif path == '/info':
            return handle_info(environ, start_response)
        elif path == '/echo':
            return handle_echo(environ, start_response)
        elif path == '/headers':
            return handle_headers(environ, start_response)
        elif path == '/status':
            return handle_status(environ, start_response)
        elif path == '/json':
            return handle_json(environ, start_response)
        elif path == '/large':
            return handle_large(environ, start_response)
        elif path == '/streaming':
            return handle_streaming(environ, start_response)
        elif path == '/slow':
            return handle_slow(environ, start_response)
        elif path == '/error':
            return handle_error(environ, start_response)
        elif path == '/unicode':
            return handle_unicode(environ, start_response)
        elif path.startswith('/methods/'):
            return handle_methods(environ, start_response)
        else:
            return handle_not_found(environ, start_response)
    except Exception as e:
        # Return 500 with error details
        body = f"Internal Server Error: {str(e)}\n{traceback.format_exc()}".encode('utf-8')
        start_response('500 Internal Server Error', [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ])
        return [body]


def handle_hello(environ, start_response):
    """Simple hello world response."""
    body = b'Hello from WSGI Test App!\n'
    start_response('200 OK', [
        ('Content-Type', 'text/plain'),
        ('Content-Length', str(len(body)))
    ])
    return [body]


def handle_info(environ, start_response):
    """Return detailed request information as JSON."""
    info = {
        'method': environ.get('REQUEST_METHOD', ''),
        'path': environ.get('PATH_INFO', ''),
        'query_string': environ.get('QUERY_STRING', ''),
        'content_type': environ.get('CONTENT_TYPE', ''),
        'content_length': environ.get('CONTENT_LENGTH', ''),
        'server_name': environ.get('SERVER_NAME', ''),
        'server_port': environ.get('SERVER_PORT', ''),
        'server_protocol': environ.get('SERVER_PROTOCOL', ''),
        'script_name': environ.get('SCRIPT_NAME', ''),
        'remote_addr': environ.get('REMOTE_ADDR', ''),
        'wsgi_version': str(environ.get('wsgi.version', '')),
        'wsgi_url_scheme': environ.get('wsgi.url_scheme', ''),
        'wsgi_multithread': environ.get('wsgi.multithread', False),
        'wsgi_multiprocess': environ.get('wsgi.multiprocess', False),
    }

    # Include HTTP headers
    headers = {}
    for key, value in environ.items():
        if key.startswith('HTTP_'):
            header_name = key[5:].replace('_', '-').lower()
            headers[header_name] = value
    info['headers'] = headers

    body = json.dumps(info, indent=2).encode('utf-8')
    start_response('200 OK', [
        ('Content-Type', 'application/json'),
        ('Content-Length', str(len(body)))
    ])
    return [body]


def handle_echo(environ, start_response):
    """Echo back the request body."""
    content_length = int(environ.get('CONTENT_LENGTH', 0))
    if content_length > 0:
        wsgi_input = environ['wsgi.input']
        if isinstance(wsgi_input, bytes):
            body = wsgi_input
        else:
            body = wsgi_input.read(content_length)
    else:
        body = b''

    start_response('200 OK', [
        ('Content-Type', environ.get('CONTENT_TYPE', 'application/octet-stream')),
        ('Content-Length', str(len(body))),
        ('X-Echo-Length', str(len(body)))
    ])
    return [body]


def handle_headers(environ, start_response):
    """Test various response header scenarios."""
    query = environ.get('QUERY_STRING', '')
    params = dict(p.split('=', 1) for p in query.split('&') if '=' in p)

    headers = [('Content-Type', 'text/plain')]

    # Add custom headers from query params
    if 'custom' in params:
        headers.append(('X-Custom-Header', params['custom']))

    # Test multiple headers with same name
    if 'multi' in params:
        headers.append(('X-Multi', 'value1'))
        headers.append(('X-Multi', 'value2'))

    # Test special headers
    if 'cache' in params:
        headers.append(('Cache-Control', f'max-age={params["cache"]}'))

    body = b'Headers test response\n'
    headers.append(('Content-Length', str(len(body))))

    start_response('200 OK', headers)
    return [body]


def handle_status(environ, start_response):
    """Return specific HTTP status codes."""
    query = environ.get('QUERY_STRING', '')
    params = dict(p.split('=', 1) for p in query.split('&') if '=' in p)

    code = int(params.get('code', 200))

    status_messages = {
        200: 'OK',
        201: 'Created',
        204: 'No Content',
        301: 'Moved Permanently',
        302: 'Found',
        304: 'Not Modified',
        400: 'Bad Request',
        401: 'Unauthorized',
        403: 'Forbidden',
        404: 'Not Found',
        405: 'Method Not Allowed',
        500: 'Internal Server Error',
        502: 'Bad Gateway',
        503: 'Service Unavailable',
    }

    status = f'{code} {status_messages.get(code, "Unknown")}'

    if code == 204:
        # No content, no body
        start_response(status, [])
        return []
    elif code in (301, 302):
        # Redirect
        location = params.get('location', '/')
        start_response(status, [
            ('Location', location),
            ('Content-Length', '0')
        ])
        return []
    else:
        body = f'Status: {code}\n'.encode('utf-8')
        start_response(status, [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ])
        return [body]


def handle_json(environ, start_response):
    """Handle JSON request and response."""
    method = environ.get('REQUEST_METHOD', 'GET')

    if method == 'POST':
        content_length = int(environ.get('CONTENT_LENGTH', 0))
        if content_length > 0:
            wsgi_input = environ['wsgi.input']
            if isinstance(wsgi_input, bytes):
                raw_body = wsgi_input
            else:
                raw_body = wsgi_input.read(content_length)
            try:
                data = json.loads(raw_body)
                response = {'received': data, 'status': 'ok'}
            except json.JSONDecodeError as e:
                response = {'error': str(e), 'status': 'error'}
        else:
            response = {'error': 'No body', 'status': 'error'}
    else:
        response = {'message': 'Use POST to send JSON', 'status': 'info'}

    body = json.dumps(response).encode('utf-8')
    start_response('200 OK', [
        ('Content-Type', 'application/json'),
        ('Content-Length', str(len(body)))
    ])
    return [body]


def handle_large(environ, start_response):
    """Generate a large response body."""
    query = environ.get('QUERY_STRING', '')
    params = dict(p.split('=', 1) for p in query.split('&') if '=' in p)

    size = int(params.get('size', 1024))  # Default 1KB
    size = min(size, 10 * 1024 * 1024)  # Cap at 10MB

    body = b'X' * size
    start_response('200 OK', [
        ('Content-Type', 'application/octet-stream'),
        ('Content-Length', str(len(body)))
    ])
    return [body]


def handle_streaming(environ, start_response):
    """Return a streaming response.

    In WSGI, streaming is done by returning an iterable.
    The server handles chunked encoding automatically when there's no Content-Length.
    """
    query = environ.get('QUERY_STRING', '')
    params = dict(p.split('=', 1) for p in query.split('&') if '=' in p)

    chunks = int(params.get('chunks', 5))
    chunk_size = int(params.get('size', 100))

    # Build complete body for simplicity (WSGI streaming requires careful handling)
    body_parts = []
    for i in range(chunks):
        body_parts.append(f'Chunk {i + 1}: {"X" * chunk_size}\n'.encode('utf-8'))
    body = b''.join(body_parts)

    start_response('200 OK', [
        ('Content-Type', 'text/plain'),
        ('Content-Length', str(len(body)))
    ])

    return [body]


def handle_slow(environ, start_response):
    """Simulate a slow response."""
    query = environ.get('QUERY_STRING', '')
    params = dict(p.split('=', 1) for p in query.split('&') if '=' in p)

    delay = float(params.get('delay', 1.0))
    delay = min(delay, 10.0)  # Cap at 10 seconds

    time.sleep(delay)

    body = f'Response after {delay}s delay\n'.encode('utf-8')
    start_response('200 OK', [
        ('Content-Type', 'text/plain'),
        ('Content-Length', str(len(body)))
    ])
    return [body]


def handle_error(environ, start_response):
    """Simulate various error conditions."""
    query = environ.get('QUERY_STRING', '')
    params = dict(p.split('=', 1) for p in query.split('&') if '=' in p)

    error_type = params.get('type', 'exception')

    if error_type == 'exception':
        raise ValueError("Intentional test exception")
    elif error_type == 'timeout':
        time.sleep(300)  # Will be killed by timeout
    elif error_type == 'empty':
        start_response('200 OK', [])
        return []
    else:
        body = b'Unknown error type\n'
        start_response('400 Bad Request', [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ])
        return [body]


def handle_unicode(environ, start_response):
    """Test Unicode handling."""
    # Various unicode characters
    unicode_text = """Unicode Test:
- ASCII: Hello World
- Accents: café, naïve, résumé
- Greek: Ελληνικά
- Chinese: 中文测试
- Japanese: 日本語テスト
- Emoji: 🎉 🚀 ✨
- Math: ∑ ∫ √ π ∞
"""
    body = unicode_text.encode('utf-8')
    start_response('200 OK', [
        ('Content-Type', 'text/plain; charset=utf-8'),
        ('Content-Length', str(len(body)))
    ])
    return [body]


def handle_methods(environ, start_response):
    """Test HTTP method handling."""
    method = environ.get('REQUEST_METHOD', 'GET')
    path = environ.get('PATH_INFO', '')

    # Extract expected method from path: /methods/{method}
    expected = path.split('/')[-1].upper()

    if method == expected:
        body = f'Method {method} OK\n'.encode('utf-8')
        status = '200 OK'
    else:
        body = f'Expected {expected}, got {method}\n'.encode('utf-8')
        status = '405 Method Not Allowed'

    start_response(status, [
        ('Content-Type', 'text/plain'),
        ('Content-Length', str(len(body))),
        ('Allow', 'GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS')
    ])
    return [body]


def handle_not_found(environ, start_response):
    """404 handler."""
    body = b'Not Found\n'
    start_response('404 Not Found', [
        ('Content-Type', 'text/plain'),
        ('Content-Length', str(len(body)))
    ])
    return [body]
