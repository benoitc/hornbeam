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

"""Utility functions for HTTP parsing - extracted from gunicorn."""

import urllib.parse
import ipaddress
from typing import List


def bytes_to_str(b):
    """Convert bytes to string using latin-1 encoding.

    HTTP headers are defined as ISO-8859-1 (latin-1) encoded.
    """
    if isinstance(b, str):
        return b
    return str(b, 'latin1')


def split_request_uri(uri):
    """Split request URI into components.

    Handles the special case where path starts with // which urlsplit
    would consider as a relative URI.

    Args:
        uri: The request URI string

    Returns:
        urllib.parse.SplitResult with path, query, fragment, etc.
    """
    if uri.startswith("//"):
        # When the path starts with //, urlsplit considers it as a
        # relative uri while the RFC says we should consider it as abs_path
        # http://www.w3.org/Protocols/rfc2616/rfc2616-sec5.html#sec5.1.2
        # We use temporary dot prefix to workaround this behaviour
        parts = urllib.parse.urlsplit("." + uri)
        return parts._replace(path=parts.path[1:])

    return urllib.parse.urlsplit(uri)


def unquote_to_wsgi_str(string):
    """Unquote URL-encoded string to WSGI str (latin-1 decoded bytes)."""
    return urllib.parse.unquote_to_bytes(string).decode('latin-1')


def ip_in_allow_list(ip_str, allow_list, networks):
    """Check if IP address is in the allow list.

    Args:
        ip_str: The IP address string to check
        allow_list: The original allow list (strings, may contain "*")
        networks: Pre-computed ipaddress.ip_network objects

    Returns:
        True if IP is allowed, False otherwise
    """
    if '*' in allow_list:
        return True
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    for network in networks:
        if ip in network:
            return True
    return False


def build_wsgi_environ(request, server_addr=None, script_name=''):
    """Build WSGI environ dict from parsed request.

    Args:
        request: Parsed Request object
        server_addr: Server (host, port) tuple
        script_name: SCRIPT_NAME for mounted apps

    Returns:
        WSGI environ dictionary
    """
    environ = {
        'REQUEST_METHOD': request.method,
        'SCRIPT_NAME': script_name,
        'PATH_INFO': request.path,
        'QUERY_STRING': request.query or '',
        'SERVER_PROTOCOL': 'HTTP/%d.%d' % request.version,
        'wsgi.version': (1, 0),
        'wsgi.url_scheme': request.scheme,
        'wsgi.input': request.body,
        'wsgi.errors': None,  # Set by runner
        'wsgi.multithread': True,
        'wsgi.multiprocess': True,
        'wsgi.run_once': False,
    }

    # Server name/port
    if server_addr:
        environ['SERVER_NAME'] = server_addr[0]
        environ['SERVER_PORT'] = str(server_addr[1])

    # Remote addr from PROXY protocol or peer
    if request.proxy_protocol_info:
        info = request.proxy_protocol_info
        if info.get('client_addr'):
            environ['REMOTE_ADDR'] = info['client_addr']
            environ['REMOTE_PORT'] = str(info['client_port'])
    elif request.peer_addr and isinstance(request.peer_addr, tuple):
        environ['REMOTE_ADDR'] = request.peer_addr[0]
        if len(request.peer_addr) > 1:
            environ['REMOTE_PORT'] = str(request.peer_addr[1])

    # Headers
    for name, value in request.headers:
        key = name.upper().replace('-', '_')
        if key == 'CONTENT_TYPE':
            environ['CONTENT_TYPE'] = value
        elif key == 'CONTENT_LENGTH':
            environ['CONTENT_LENGTH'] = value
        else:
            environ['HTTP_' + key] = value

    return environ


def build_asgi_scope(request, server_addr=None, root_path=''):
    """Build ASGI scope dict from parsed request.

    Args:
        request: Parsed Request object
        server_addr: Server (host, port) tuple
        root_path: Root path for mounted apps

    Returns:
        ASGI HTTP scope dictionary
    """
    # Headers as list of (name, value) tuples, both as bytes
    headers = [
        (name.lower().encode('latin-1'), value.encode('latin-1'))
        for name, value in request.headers
    ]

    scope = {
        'type': 'http',
        'asgi': {'version': '3.0', 'spec_version': '2.3'},
        'http_version': '%d.%d' % request.version,
        'method': request.method,
        'scheme': request.scheme,
        'path': request.path,
        'raw_path': request.path.encode('latin-1'),
        'query_string': (request.query or '').encode('latin-1'),
        'root_path': root_path,
        'headers': headers,
        'server': server_addr,
    }

    # Client addr from PROXY protocol or peer
    if request.proxy_protocol_info:
        info = request.proxy_protocol_info
        if info.get('client_addr'):
            scope['client'] = (info['client_addr'], info['client_port'])
    elif request.peer_addr and isinstance(request.peer_addr, tuple):
        scope['client'] = request.peer_addr

    return scope
