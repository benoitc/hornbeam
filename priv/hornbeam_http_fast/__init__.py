# Copyright 2026 Benoit Chesneau
# Licensed under Apache 2.0

"""
hornbeam_http_fast - High-performance HTTP parser using picohttpparser.

This module provides fast HTTP request/response parsing using the
picohttpparser C library with SIMD optimizations (SSE4.2/AVX2 on x86,
NEON on ARM).

Performance: ~1.7M requests/sec (12x faster than pure Python)

Example:
    from hornbeam_http_fast import parse_request, parse_response

    # Parse request
    result = parse_request(b"GET /path HTTP/1.1\\r\\nHost: example.com\\r\\n\\r\\n")
    print(result['method'], result['path'], result['headers'])

    # Parse response
    result = parse_response(b"HTTP/1.1 200 OK\\r\\nContent-Length: 5\\r\\n\\r\\n")
    print(result['status'], result['headers'])
"""

try:
    from pico_parser import (
        parse_request,
        parse_response,
        parse_headers,
        ParseError,
        IncompleteError,
    )
    FAST_PARSER_AVAILABLE = True

except ImportError:
    # C extension not built
    import warnings
    warnings.warn(
        "hornbeam_http_fast C extension not available. "
        "Build with: cd priv/hornbeam_http_fast && python setup.py build_ext --inplace",
        ImportWarning
    )
    FAST_PARSER_AVAILABLE = False

    # Provide fallback using pure Python parser
    from hornbeam_http.errors import NoMoreData

    class ParseError(ValueError):
        pass

    class IncompleteError(Exception):
        pass

    def parse_request(data, last_len=0):
        """Fallback parser using pure Python implementation."""
        import sys
        sys.path.insert(0, __file__.rsplit('/', 2)[0])
        from hornbeam_http import HTTPConfig, Request, BufferUnreader

        try:
            cfg = HTTPConfig()
            unreader = BufferUnreader(data)
            req = Request(cfg, unreader, None)
            return {
                'method': req.method.encode() if isinstance(req.method, str) else req.method,
                'path': req.path.encode() if isinstance(req.path, str) else req.path,
                'minor_version': req.version[1] if req.version else 1,
                'headers': [(n.encode(), v.encode()) for n, v in req.headers],
                'consumed': len(data),  # Approximate
            }
        except NoMoreData:
            raise IncompleteError("Incomplete request")
        except Exception as e:
            raise ParseError(str(e))

    def parse_response(data, last_len=0):
        raise NotImplementedError("Response parsing requires C extension")

    def parse_headers(data, last_len=0):
        raise NotImplementedError("Header parsing requires C extension")


def build_environ(parsed_request, peer_addr=None, server_addr=None, script_name=b''):
    """Build WSGI environ from parsed request.

    Args:
        parsed_request: Result from parse_request()
        peer_addr: (ip, port) tuple for client
        server_addr: (host, port) tuple for server
        script_name: SCRIPT_NAME for mounted apps

    Returns:
        WSGI environ dict
    """
    method = parsed_request['method']
    path = parsed_request['path']
    headers = parsed_request['headers']

    # Decode bytes to str
    if isinstance(method, bytes):
        method = method.decode('latin-1')
    if isinstance(path, bytes):
        path = path.decode('latin-1')
    if isinstance(script_name, bytes):
        script_name = script_name.decode('latin-1')

    # Split path and query string
    if '?' in path:
        path_info, query_string = path.split('?', 1)
    else:
        path_info, query_string = path, ''

    environ = {
        'REQUEST_METHOD': method,
        'SCRIPT_NAME': script_name,
        'PATH_INFO': path_info,
        'QUERY_STRING': query_string,
        'SERVER_PROTOCOL': f"HTTP/1.{parsed_request['minor_version']}",
        'wsgi.version': (1, 0),
        'wsgi.url_scheme': 'http',
        'wsgi.multithread': True,
        'wsgi.multiprocess': True,
        'wsgi.run_once': False,
    }

    if server_addr:
        environ['SERVER_NAME'] = server_addr[0]
        environ['SERVER_PORT'] = str(server_addr[1])

    if peer_addr:
        environ['REMOTE_ADDR'] = peer_addr[0]
        environ['REMOTE_PORT'] = str(peer_addr[1])

    # Process headers
    for name, value in headers:
        if isinstance(name, bytes):
            name = name.decode('latin-1')
        if isinstance(value, bytes):
            value = value.decode('latin-1')

        name_upper = name.upper().replace('-', '_')

        if name_upper == 'CONTENT_TYPE':
            environ['CONTENT_TYPE'] = value
        elif name_upper == 'CONTENT_LENGTH':
            environ['CONTENT_LENGTH'] = value
        else:
            environ[f'HTTP_{name_upper}'] = value

    return environ


def build_asgi_scope(parsed_request, peer_addr=None, server_addr=None, root_path=''):
    """Build ASGI scope from parsed request.

    Args:
        parsed_request: Result from parse_request()
        peer_addr: (ip, port) tuple for client
        server_addr: (host, port) tuple for server
        root_path: Root path for mounted apps

    Returns:
        ASGI HTTP scope dict
    """
    method = parsed_request['method']
    path = parsed_request['path']
    headers = parsed_request['headers']

    # Ensure bytes
    if isinstance(method, str):
        method = method.encode('latin-1')
    if isinstance(path, str):
        path = path.encode('latin-1')
    if isinstance(root_path, str):
        root_path = root_path.encode('latin-1')

    # Split path and query string
    if b'?' in path:
        path_info, query_string = path.split(b'?', 1)
    else:
        path_info, query_string = path, b''

    # Headers as list of (name, value) byte tuples
    scope_headers = []
    for name, value in headers:
        if isinstance(name, str):
            name = name.encode('latin-1')
        if isinstance(value, str):
            value = value.encode('latin-1')
        scope_headers.append((name.lower(), value))

    return {
        'type': 'http',
        'asgi': {'version': '3.0', 'spec_version': '2.3'},
        'http_version': f"1.{parsed_request['minor_version']}",
        'method': method.decode('latin-1') if isinstance(method, bytes) else method,
        'scheme': 'http',
        'path': path_info.decode('latin-1') if isinstance(path_info, bytes) else path_info,
        'raw_path': path_info,
        'query_string': query_string,
        'root_path': root_path.decode('latin-1') if isinstance(root_path, bytes) else root_path,
        'headers': scope_headers,
        'server': server_addr,
        'client': peer_addr,
    }


__all__ = [
    'parse_request',
    'parse_response',
    'parse_headers',
    'ParseError',
    'IncompleteError',
    'build_environ',
    'build_asgi_scope',
    'FAST_PARSER_AVAILABLE',
]

__version__ = '1.0.0'
