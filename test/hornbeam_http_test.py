#!/usr/bin/env python3
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

"""Unit tests for hornbeam_http parser package."""

import sys
import os
import struct
import unittest

# Add priv to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'priv'))

from hornbeam_http import (
    HTTPConfig, Request, BufferUnreader,
    ParseException, InvalidRequestLine, InvalidHeader,
    InvalidProxyLine, InvalidProxyHeader, LimitRequestLine,
)
from hornbeam_http.util import build_wsgi_environ, build_asgi_scope


class TestHTTPConfig(unittest.TestCase):
    """Tests for HTTPConfig dataclass."""

    def test_default_config(self):
        cfg = HTTPConfig()
        self.assertFalse(cfg.is_ssl)
        self.assertEqual(cfg.limit_request_fields, 100)
        self.assertEqual(cfg.proxy_protocol, 'off')

    def test_from_dict(self):
        cfg = HTTPConfig.from_dict({
            'is_ssl': True,
            'proxy_protocol': 'v2',
            'limit_request_line': 8000
        })
        self.assertTrue(cfg.is_ssl)
        self.assertEqual(cfg.proxy_protocol, 'v2')
        self.assertEqual(cfg.limit_request_line, 8000)

    def test_from_dict_camel_case(self):
        cfg = HTTPConfig.from_dict({
            'isSsl': True,
            'proxyProtocol': 'auto'
        })
        self.assertTrue(cfg.is_ssl)
        self.assertEqual(cfg.proxy_protocol, 'auto')


class TestHTTPParser(unittest.TestCase):
    """Tests for HTTP request parsing."""

    def parse_request(self, data, cfg=None, peer_addr=None):
        """Helper to parse request from bytes."""
        if cfg is None:
            cfg = HTTPConfig()
        if peer_addr is None:
            peer_addr = ('127.0.0.1', 12345)
        unreader = BufferUnreader(data)
        return Request(cfg, unreader, peer_addr)

    def test_simple_get_request(self):
        data = b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        req = self.parse_request(data)

        self.assertEqual(req.method, 'GET')
        self.assertEqual(req.path, '/')
        self.assertEqual(req.version, (1, 1))
        self.assertEqual(len(req.headers), 1)
        self.assertEqual(req.headers[0], ('HOST', 'example.com'))

    def test_get_with_query_string(self):
        data = b"GET /search?q=test&page=1 HTTP/1.1\r\nHost: example.com\r\n\r\n"
        req = self.parse_request(data)

        self.assertEqual(req.method, 'GET')
        self.assertEqual(req.path, '/search')
        self.assertEqual(req.query, 'q=test&page=1')

    def test_post_with_body(self):
        data = b"POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 13\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nname=testuser"
        req = self.parse_request(data)

        self.assertEqual(req.method, 'POST')
        self.assertEqual(req.path, '/submit')
        body = req.body.read()
        self.assertEqual(body, b'name=testuser')

    def test_chunked_transfer_encoding(self):
        data = (
            b"POST /upload HTTP/1.1\r\n"
            b"Host: example.com\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n"
            b"5\r\nhello\r\n"
            b"5\r\nworld\r\n"
            b"0\r\n\r\n"
        )
        req = self.parse_request(data)

        self.assertEqual(req.method, 'POST')
        body = req.body.read()
        self.assertEqual(body, b'helloworld')

    def test_http_10_request(self):
        data = b"GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"
        req = self.parse_request(data)

        self.assertEqual(req.version, (1, 0))
        self.assertTrue(req.should_close())

    def test_http_11_keep_alive(self):
        data = b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        req = self.parse_request(data)

        self.assertEqual(req.version, (1, 1))
        self.assertFalse(req.should_close())

    def test_connection_close(self):
        data = b"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
        req = self.parse_request(data)

        self.assertTrue(req.should_close())

    def test_multiple_headers_same_name(self):
        data = (
            b"GET / HTTP/1.1\r\n"
            b"Host: example.com\r\n"
            b"Accept: text/html\r\n"
            b"Accept: application/json\r\n\r\n"
        )
        req = self.parse_request(data)

        accept_headers = [h[1] for h in req.headers if h[0] == 'ACCEPT']
        self.assertEqual(len(accept_headers), 2)

    def test_invalid_request_line(self):
        data = b"GET HTTP/1.1\r\n\r\n"  # Missing path
        with self.assertRaises(InvalidRequestLine):
            self.parse_request(data)

    def test_invalid_http_version(self):
        from hornbeam_http.errors import InvalidHTTPVersion
        data = b"GET / HTTP/3.0\r\nHost: example.com\r\n\r\n"
        with self.assertRaises(InvalidHTTPVersion):
            self.parse_request(data)

    def test_header_limits(self):
        cfg = HTTPConfig(limit_request_fields=2)
        data = (
            b"GET / HTTP/1.1\r\n"
            b"Host: example.com\r\n"
            b"Accept: text/html\r\n"
            b"User-Agent: test\r\n\r\n"
        )
        from hornbeam_http.errors import LimitRequestHeaders
        with self.assertRaises(LimitRequestHeaders):
            self.parse_request(data, cfg)

    def test_request_line_too_long(self):
        cfg = HTTPConfig(limit_request_line=50)
        long_path = b"/very/long/path/" + b"x" * 100
        data = b"GET " + long_path + b" HTTP/1.1\r\nHost: example.com\r\n\r\n"
        with self.assertRaises(LimitRequestLine):
            self.parse_request(data, cfg)


class TestProxyProtocolV1(unittest.TestCase):
    """Tests for PROXY protocol v1 parsing."""

    def parse_request(self, data, cfg=None, peer_addr=None):
        if cfg is None:
            cfg = HTTPConfig(proxy_protocol='v1', proxy_allow_ips=['*'])
        if peer_addr is None:
            peer_addr = ('127.0.0.1', 12345)
        unreader = BufferUnreader(data)
        return Request(cfg, unreader, peer_addr)

    def test_proxy_v1_tcp4(self):
        data = (
            b"PROXY TCP4 192.168.1.100 10.0.0.1 54321 80\r\n"
            b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )
        req = self.parse_request(data)

        self.assertIsNotNone(req.proxy_protocol_info)
        self.assertEqual(req.proxy_protocol_info['proxy_protocol'], 'TCP4')
        self.assertEqual(req.proxy_protocol_info['client_addr'], '192.168.1.100')
        self.assertEqual(req.proxy_protocol_info['client_port'], 54321)

    def test_proxy_v1_tcp6(self):
        data = (
            b"PROXY TCP6 2001:db8::1 2001:db8::2 54321 80\r\n"
            b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )
        req = self.parse_request(data)

        self.assertEqual(req.proxy_protocol_info['proxy_protocol'], 'TCP6')
        self.assertEqual(req.proxy_protocol_info['client_addr'], '2001:db8::1')

    def test_proxy_v1_invalid(self):
        data = (
            b"PROXY INVALID 192.168.1.100 10.0.0.1 54321 80\r\n"
            b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )
        with self.assertRaises(InvalidProxyLine):
            self.parse_request(data)


class TestProxyProtocolV2(unittest.TestCase):
    """Tests for PROXY protocol v2 parsing."""

    PP_V2_SIGNATURE = b"\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"

    def build_v2_header(self, command=0x1, family=0x11, addr_data=b''):
        """Build PROXY v2 header."""
        ver_cmd = (2 << 4) | command
        length = len(addr_data)
        return self.PP_V2_SIGNATURE + struct.pack('>BBH', ver_cmd, family, length) + addr_data

    def parse_request(self, data, cfg=None, peer_addr=None):
        if cfg is None:
            cfg = HTTPConfig(proxy_protocol='v2', proxy_allow_ips=['*'])
        if peer_addr is None:
            peer_addr = ('127.0.0.1', 12345)
        unreader = BufferUnreader(data)
        return Request(cfg, unreader, peer_addr)

    def test_proxy_v2_ipv4(self):
        # Build IPv4 address data: src_ip(4) + dst_ip(4) + src_port(2) + dst_port(2)
        import socket
        src_ip = socket.inet_aton('192.168.1.100')
        dst_ip = socket.inet_aton('10.0.0.1')
        addr_data = src_ip + dst_ip + struct.pack('>HH', 54321, 80)

        proxy_header = self.build_v2_header(command=0x1, family=0x11, addr_data=addr_data)
        http_request = b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        data = proxy_header + http_request

        req = self.parse_request(data)

        self.assertIsNotNone(req.proxy_protocol_info)
        self.assertEqual(req.proxy_protocol_info['proxy_protocol'], 'TCP4')
        self.assertEqual(req.proxy_protocol_info['client_addr'], '192.168.1.100')
        self.assertEqual(req.proxy_protocol_info['client_port'], 54321)

    def test_proxy_v2_ipv6(self):
        # Build IPv6 address data: src_ip(16) + dst_ip(16) + src_port(2) + dst_port(2)
        import socket
        src_ip = socket.inet_pton(socket.AF_INET6, '2001:db8::1')
        dst_ip = socket.inet_pton(socket.AF_INET6, '2001:db8::2')
        addr_data = src_ip + dst_ip + struct.pack('>HH', 54321, 80)

        proxy_header = self.build_v2_header(command=0x1, family=0x21, addr_data=addr_data)
        http_request = b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        data = proxy_header + http_request

        req = self.parse_request(data)

        self.assertEqual(req.proxy_protocol_info['proxy_protocol'], 'TCP6')
        self.assertEqual(req.proxy_protocol_info['client_addr'], '2001:db8::1')

    def test_proxy_v2_local(self):
        # LOCAL command
        proxy_header = self.build_v2_header(command=0x0, family=0x00, addr_data=b'')
        http_request = b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        data = proxy_header + http_request

        req = self.parse_request(data)

        self.assertEqual(req.proxy_protocol_info['proxy_protocol'], 'LOCAL')
        self.assertIsNone(req.proxy_protocol_info['client_addr'])

    def test_invalid_v2_version(self):
        # Invalid version (not 2)
        ver_cmd = (1 << 4) | 0x1  # Version 1 instead of 2
        header = self.PP_V2_SIGNATURE + struct.pack('>BBH', ver_cmd, 0x11, 0)
        data = header + b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"

        with self.assertRaises(InvalidProxyHeader):
            self.parse_request(data)


class TestWSGIEnviron(unittest.TestCase):
    """Tests for WSGI environ building."""

    def parse_and_build_environ(self, data, server_addr=None):
        cfg = HTTPConfig()
        unreader = BufferUnreader(data)
        req = Request(cfg, unreader, ('192.168.1.100', 54321))
        return build_wsgi_environ(req, server_addr=server_addr)

    def test_environ_from_simple_request(self):
        data = b"GET /path?query=value HTTP/1.1\r\nHost: example.com\r\n\r\n"
        environ = self.parse_and_build_environ(data, server_addr=('example.com', 80))

        self.assertEqual(environ['REQUEST_METHOD'], 'GET')
        self.assertEqual(environ['PATH_INFO'], '/path')
        self.assertEqual(environ['QUERY_STRING'], 'query=value')
        self.assertEqual(environ['SERVER_NAME'], 'example.com')
        self.assertEqual(environ['SERVER_PORT'], '80')
        self.assertEqual(environ['REMOTE_ADDR'], '192.168.1.100')

    def test_environ_with_headers(self):
        data = (
            b"POST /submit HTTP/1.1\r\n"
            b"Host: example.com\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: 2\r\n"
            b"X-Custom-Header: custom-value\r\n\r\n{}"
        )
        environ = self.parse_and_build_environ(data)

        self.assertEqual(environ['CONTENT_TYPE'], 'application/json')
        self.assertEqual(environ['CONTENT_LENGTH'], '2')
        self.assertEqual(environ['HTTP_X_CUSTOM_HEADER'], 'custom-value')

    def test_environ_with_proxy_info(self):
        data = (
            b"PROXY TCP4 10.0.0.1 192.168.1.1 12345 80\r\n"
            b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )
        cfg = HTTPConfig(proxy_protocol='v1', proxy_allow_ips=['*'])
        unreader = BufferUnreader(data)
        req = Request(cfg, unreader, ('127.0.0.1', 8080))
        environ = build_wsgi_environ(req)

        # REMOTE_ADDR should be from PROXY header, not peer
        self.assertEqual(environ['REMOTE_ADDR'], '10.0.0.1')
        self.assertEqual(environ['REMOTE_PORT'], '12345')


class TestASGIScope(unittest.TestCase):
    """Tests for ASGI scope building."""

    def parse_and_build_scope(self, data, server_addr=None):
        cfg = HTTPConfig()
        unreader = BufferUnreader(data)
        req = Request(cfg, unreader, ('192.168.1.100', 54321))
        return build_asgi_scope(req, server_addr=server_addr)

    def test_scope_from_request(self):
        data = b"GET /path?query=value HTTP/1.1\r\nHost: example.com\r\n\r\n"
        scope = self.parse_and_build_scope(data, server_addr=('example.com', 80))

        self.assertEqual(scope['type'], 'http')
        self.assertEqual(scope['method'], 'GET')
        self.assertEqual(scope['path'], '/path')
        self.assertEqual(scope['query_string'], b'query=value')
        self.assertEqual(scope['server'], ('example.com', 80))
        self.assertEqual(scope['client'], ('192.168.1.100', 54321))

    def test_scope_headers_as_bytes(self):
        data = b"GET / HTTP/1.1\r\nHost: example.com\r\nAccept: text/html\r\n\r\n"
        scope = self.parse_and_build_scope(data)

        # Headers should be list of (name, value) tuples, both bytes
        for name, value in scope['headers']:
            self.assertIsInstance(name, bytes)
            self.assertIsInstance(value, bytes)


if __name__ == '__main__':
    unittest.main()
