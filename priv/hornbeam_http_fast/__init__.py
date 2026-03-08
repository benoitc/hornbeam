# Copyright 2026 Benoit Chesneau
# Licensed under Apache 2.0

"""
hornbeam_http_fast - High-performance HTTP parser using picohttpparser.

This module provides fast HTTP request/response parsing using the
picohttpparser C library with SIMD optimizations (SSE4.2/AVX2 on x86,
NEON on ARM).
"""

from pico_parser import (
    parse_request,
    parse_response,
    parse_headers,
    ParseError,
    IncompleteError,
)

# Local var caching
_bytes = bytes
_isinstance = isinstance
_memoryview = memoryview


def _to_bytes(val):
    """Convert value to bytes (handles memoryview, bytes, str)."""
    if _isinstance(val, _memoryview):
        return _bytes(val)
    if _isinstance(val, _bytes):
        return val
    if _isinstance(val, str):
        return val.encode('latin-1')
    return _bytes(val)


def _to_str(val):
    """Convert value to str (handles memoryview, bytes, str)."""
    if _isinstance(val, _memoryview):
        return _bytes(val).decode('latin-1')
    if _isinstance(val, _bytes):
        return val.decode('latin-1')
    if _isinstance(val, str):
        return val
    return str(val)


def build_environ(parsed_request, peer_addr=None, server_addr=None, script_name=b''):
    """Build WSGI environ from parsed request.

    Args:
        parsed_request: Result from parse_request() - HttpRequest object or dict
        peer_addr: (ip, port) tuple for client
        server_addr: (host, port) tuple for server
        script_name: SCRIPT_NAME for mounted apps

    Returns:
        WSGI environ dict
    """
    # Handle both HttpRequest object and dict
    if hasattr(parsed_request, 'method'):
        method = parsed_request.method
        path = parsed_request.path
        headers = parsed_request.headers
        minor_version = parsed_request.minor_version
    else:
        method = parsed_request['method']
        path = parsed_request['path']
        headers = parsed_request['headers']
        minor_version = parsed_request['minor_version']

    # Convert to str (handles memoryview, bytes, str)
    method = _to_str(method)
    path = _to_str(path)
    script_name = _to_str(script_name) if script_name else ''

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
        'SERVER_PROTOCOL': f"HTTP/1.{minor_version}",
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

    # Process headers (handles memoryview from zero-copy parser)
    for name, value in headers:
        name = _to_str(name)
        value = _to_str(value)

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
        parsed_request: Result from parse_request() - HttpRequest object or dict
        peer_addr: (ip, port) tuple for client
        server_addr: (host, port) tuple for server
        root_path: Root path for mounted apps

    Returns:
        ASGI HTTP scope dict
    """
    # Handle both HttpRequest object and dict
    if hasattr(parsed_request, 'method'):
        method = parsed_request.method
        path = parsed_request.path
        headers = parsed_request.headers
        minor_version = parsed_request.minor_version
    else:
        method = parsed_request['method']
        path = parsed_request['path']
        headers = parsed_request['headers']
        minor_version = parsed_request['minor_version']

    # Convert to bytes (handles memoryview from zero-copy parser)
    method = _to_bytes(method)
    path = _to_bytes(path)
    root_path = _to_bytes(root_path) if root_path else b''

    # Split path and query string
    if b'?' in path:
        path_info, query_string = path.split(b'?', 1)
    else:
        path_info, query_string = path, b''

    # Headers as list of (name, value) byte tuples (handles memoryview)
    scope_headers = []
    for name, value in headers:
        name = _to_bytes(name)
        value = _to_bytes(value)
        scope_headers.append((name.lower(), value))

    return {
        'type': 'http',
        'asgi': {'version': '3.0', 'spec_version': '2.3'},
        'http_version': f"1.{minor_version}",
        'method': method.decode('latin-1'),
        'scheme': 'http',
        'path': path_info.decode('latin-1'),
        'raw_path': path_info,
        'query_string': query_string,
        'root_path': root_path.decode('latin-1') if root_path else '',
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
