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

"""HTTP message parsing - adapted from gunicorn.

Provides Request class for parsing HTTP/1.x requests with PROXY protocol support.
"""

from enum import IntEnum
import re
import socket
import struct
from typing import Optional, Tuple, List, Dict

from hornbeam_http.body import ChunkedReader, LengthReader, EOFReader, Body
from hornbeam_http.errors import (
    InvalidHeader, InvalidHeaderName, NoMoreData,
    InvalidRequestLine, InvalidRequestMethod, InvalidHTTPVersion,
    LimitRequestLine, LimitRequestHeaders,
    UnsupportedTransferCoding, ObsoleteFolding,
    ExpectationFailed,
    InvalidProxyLine, InvalidProxyHeader, ForbiddenProxyRequest,
    InvalidSchemeHeaders,
)
from hornbeam_http.util import bytes_to_str, split_request_uri, ip_in_allow_list


# PROXY protocol v2 constants
PP_V2_SIGNATURE = b"\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"


class PPCommand(IntEnum):
    """PROXY protocol v2 commands."""
    LOCAL = 0x0
    PROXY = 0x1


class PPFamily(IntEnum):
    """PROXY protocol v2 address families."""
    UNSPEC = 0x0
    INET = 0x1   # IPv4
    INET6 = 0x2  # IPv6
    UNIX = 0x3


class PPProtocol(IntEnum):
    """PROXY protocol v2 transport protocols."""
    UNSPEC = 0x0
    STREAM = 0x1  # TCP
    DGRAM = 0x2   # UDP


MAX_REQUEST_LINE = 8190
MAX_HEADERS = 32768
DEFAULT_MAX_HEADERFIELD_SIZE = 8190

# RFC9110 token characters
RFC9110_5_6_2_TOKEN_SPECIALS = r"!#$%&'*+-.^_`|~"
TOKEN_RE = re.compile(r"[%s0-9a-zA-Z]+" % (re.escape(RFC9110_5_6_2_TOKEN_SPECIALS)))
METHOD_BADCHAR_RE = re.compile("[a-z#]")
VERSION_RE = re.compile(r"HTTP/(\d)\.(\d)")
RFC9110_5_5_INVALID_AND_DANGEROUS = re.compile(r"[\0\r\n]")


class Message:
    """Base class for HTTP messages.

    Handles header parsing and body reader setup.
    """

    def __init__(self, cfg, unreader, peer_addr):
        """Initialize message.

        Args:
            cfg: HTTPConfig instance
            unreader: Unreader instance for reading data
            peer_addr: Peer address tuple (ip, port) or None
        """
        self.cfg = cfg
        self.unreader = unreader
        self.peer_addr = peer_addr
        self.remote_addr = peer_addr
        self.version = None
        self.headers: List[Tuple[str, str]] = []
        self.trailers: List[Tuple[str, str]] = []
        self.body = None
        self.scheme = "https" if cfg.is_ssl else "http"
        self.must_close = False
        self._expected_100_continue = False

        # Set headers limits
        self.limit_request_fields = cfg.limit_request_fields
        if (self.limit_request_fields <= 0
                or self.limit_request_fields > MAX_HEADERS):
            self.limit_request_fields = MAX_HEADERS
        self.limit_request_field_size = cfg.limit_request_field_size
        if self.limit_request_field_size < 0:
            self.limit_request_field_size = DEFAULT_MAX_HEADERFIELD_SIZE

        # Set max header buffer size
        max_header_field_size = self.limit_request_field_size or DEFAULT_MAX_HEADERFIELD_SIZE
        self.max_buffer_headers = self.limit_request_fields * \
            (max_header_field_size + 2) + 4

        unused = self.parse(self.unreader)
        self.unreader.unread(unused)
        self.set_body_reader()

    def force_close(self):
        """Force connection close after this message."""
        self.must_close = True

    def parse(self, unreader) -> bytes:
        """Parse the message from unreader.

        Returns:
            bytes: Unused data to unread
        """
        raise NotImplementedError()

    def parse_headers(self, data: bytes, from_trailer: bool = False) -> List[Tuple[str, str]]:
        """Parse HTTP headers.

        Args:
            data: Header data bytes
            from_trailer: True if parsing trailers

        Returns:
            List of (name, value) tuples
        """
        cfg = self.cfg
        headers = []

        # Split lines on \r\n
        lines = [bytes_to_str(line) for line in data.split(b"\r\n")]

        # Handle scheme headers
        scheme_header = False
        secure_scheme_headers = {}
        forwarder_headers = []
        if from_trailer:
            # Nonsense - either a request is https from the beginning
            # or we are just behind a proxy who does not remove conflicting trailers
            pass
        elif (not isinstance(self.peer_addr, tuple)
              or ip_in_allow_list(self.peer_addr[0], cfg.forwarded_allow_ips,
                                  cfg.forwarded_allow_networks())):
            secure_scheme_headers = cfg.secure_scheme_headers
            forwarder_headers = cfg.forwarder_headers

        # Parse headers into key/value pairs
        while lines:
            if len(headers) >= self.limit_request_fields:
                raise LimitRequestHeaders("limit request headers fields")

            # Parse initial header name: value pair
            curr = lines.pop(0)
            header_length = len(curr) + len("\r\n")
            if curr.find(":") <= 0:
                raise InvalidHeader(curr)
            name, value = curr.split(":", 1)
            if self.cfg.strip_header_spaces:
                name = name.rstrip(" \t")
            if not TOKEN_RE.fullmatch(name):
                raise InvalidHeaderName(name)

            name = name.upper()
            value = [value.strip(" \t")]

            # Consume value continuation lines
            while lines and lines[0].startswith((" ", "\t")):
                if not self.cfg.permit_obsolete_folding:
                    raise ObsoleteFolding(name)
                curr = lines.pop(0)
                header_length += len(curr) + len("\r\n")
                if header_length > self.limit_request_field_size > 0:
                    raise LimitRequestHeaders("limit request headers fields size")
                value.append(curr.strip("\t "))
            value = " ".join(value)

            if RFC9110_5_5_INVALID_AND_DANGEROUS.search(value):
                raise InvalidHeader(name)

            if header_length > self.limit_request_field_size > 0:
                raise LimitRequestHeaders("limit request headers fields size")

            if not from_trailer and name == "EXPECT":
                if value.lower() == "100-continue":
                    if self.version < (1, 1):
                        pass  # Ignore for HTTP/1.0
                    else:
                        self._expected_100_continue = True
                else:
                    raise ExpectationFailed(value)

            if name in secure_scheme_headers:
                secure = value == secure_scheme_headers[name]
                scheme = "https" if secure else "http"
                if scheme_header:
                    if scheme != self.scheme:
                        raise InvalidSchemeHeaders()
                else:
                    scheme_header = True
                    self.scheme = scheme

            # Handle underscores in header names
            if "_" in name:
                if name in forwarder_headers or "*" in forwarder_headers:
                    pass
                elif self.cfg.header_map == "dangerous":
                    pass
                elif self.cfg.header_map == "drop":
                    continue
                else:
                    raise InvalidHeaderName(name)

            headers.append((name, value))

        return headers

    def set_body_reader(self):
        """Set up appropriate body reader based on headers."""
        chunked = False
        content_length = None

        for (name, value) in self.headers:
            if name == "CONTENT-LENGTH":
                if content_length is not None:
                    raise InvalidHeader("CONTENT-LENGTH", req=self)
                content_length = value
            elif name == "TRANSFER-ENCODING":
                vals = [v.strip() for v in value.split(',')]
                for val in vals:
                    if val.lower() == "chunked":
                        if chunked:
                            raise InvalidHeader("TRANSFER-ENCODING", req=self)
                        chunked = True
                    elif val.lower() == "identity":
                        if chunked:
                            raise InvalidHeader("TRANSFER-ENCODING", req=self)
                    elif val.lower() in ('compress', 'deflate', 'gzip'):
                        if chunked:
                            raise InvalidHeader("TRANSFER-ENCODING", req=self)
                        self.force_close()
                    else:
                        raise UnsupportedTransferCoding(value)

        if chunked:
            if self.version < (1, 1):
                raise InvalidHeader("TRANSFER-ENCODING", req=self)
            if content_length is not None:
                raise InvalidHeader("CONTENT-LENGTH", req=self)
            self.body = Body(ChunkedReader(self, self.unreader))
        elif content_length is not None:
            try:
                if str(content_length).isnumeric():
                    content_length = int(content_length)
                else:
                    raise InvalidHeader("CONTENT-LENGTH", req=self)
            except ValueError:
                raise InvalidHeader("CONTENT-LENGTH", req=self)

            if content_length < 0:
                raise InvalidHeader("CONTENT-LENGTH", req=self)

            self.body = Body(LengthReader(self.unreader, content_length))
        else:
            self.body = Body(EOFReader(self.unreader))

    def should_close(self) -> bool:
        """Check if connection should close after this message."""
        if self.must_close:
            return True
        for (h, v) in self.headers:
            if h == "CONNECTION":
                v = v.lower().strip(" \t")
                if v == "close":
                    return True
                elif v == "keep-alive":
                    return False
                break
        return self.version <= (1, 0)


class Request(Message):
    """HTTP request message.

    Parses request line, headers, and handles PROXY protocol.
    """

    def __init__(self, cfg, unreader, peer_addr, req_number: int = 1):
        """Initialize request.

        Args:
            cfg: HTTPConfig instance
            unreader: Unreader instance
            peer_addr: Peer address tuple (ip, port)
            req_number: Request number for keep-alive (1 for first request)
        """
        self.method: Optional[str] = None
        self.uri: Optional[str] = None
        self.path: str = ""
        self.query: str = ""
        self.fragment: str = ""

        # Get max request line size
        self.limit_request_line = cfg.limit_request_line
        if (self.limit_request_line < 0
                or self.limit_request_line >= MAX_REQUEST_LINE):
            self.limit_request_line = MAX_REQUEST_LINE

        self.req_number = req_number
        self.proxy_protocol_info: Optional[Dict] = None
        super().__init__(cfg, unreader, peer_addr)

    def get_data(self, unreader, buf, stop: bool = False):
        """Read data from unreader into buffer."""
        data = unreader.read()
        if not data:
            if stop:
                raise StopIteration()
            raise NoMoreData(buf.getvalue())
        buf.write(data)

    def parse(self, unreader) -> bytes:
        """Parse request from unreader."""
        buf = bytearray()
        self.read_into(unreader, buf, stop=True)

        # Handle proxy protocol if enabled and this is the first request
        mode = self.cfg.proxy_protocol
        if mode != "off" and self.req_number == 1:
            buf = self._handle_proxy_protocol(unreader, buf, mode)

        # Get request line
        line, buf = self.read_line(unreader, buf, self.limit_request_line)

        self.parse_request_line(line)

        # Headers
        data = bytes(buf)

        done = data[:2] == b"\r\n"
        while True:
            idx = data.find(b"\r\n\r\n")
            done = data[:2] == b"\r\n"

            if idx < 0 and not done:
                self.read_into(unreader, buf)
                data = bytes(buf)
                if len(data) > self.max_buffer_headers:
                    raise LimitRequestHeaders("max buffer headers")
            else:
                break

        if done:
            self.unreader.unread(data[2:])
            return b""

        self.headers = self.parse_headers(data[:idx], from_trailer=False)

        ret = data[idx + 4:]
        return ret

    def read_into(self, unreader, buf, stop: bool = False):
        """Read data from unreader and append to bytearray buffer."""
        data = unreader.read()
        if not data:
            if stop:
                raise StopIteration()
            raise NoMoreData(bytes(buf))
        buf.extend(data)

    def read_line(self, unreader, buf, limit: int = 0) -> Tuple[bytes, bytearray]:
        """Read a line from buffer, returning (line, remaining_buffer)."""
        data = bytes(buf)

        while True:
            idx = data.find(b"\r\n")
            if idx >= 0:
                if idx > limit > 0:
                    raise LimitRequestLine(idx, limit)
                break
            if len(data) - 2 > limit > 0:
                raise LimitRequestLine(len(data), limit)
            self.read_into(unreader, buf)
            data = bytes(buf)

        return (data[:idx], bytearray(data[idx + 2:]))

    def read_bytes(self, unreader, buf, count: int) -> Tuple[bytes, bytearray]:
        """Read exactly count bytes from buffer/unreader."""
        while len(buf) < count:
            self.read_into(unreader, buf)
        return bytes(buf[:count]), bytearray(buf[count:])

    def _handle_proxy_protocol(self, unreader, buf: bytearray, mode: str) -> bytearray:
        """Handle PROXY protocol detection and parsing."""
        # Ensure we have enough data to detect v2 signature (12 bytes)
        while len(buf) < 12:
            self.read_into(unreader, buf)

        # Check for v2 signature first
        if mode in ("v2", "auto") and buf[:12] == PP_V2_SIGNATURE:
            self.proxy_protocol_access_check()
            return self._parse_proxy_protocol_v2(unreader, buf)

        # Check for v1 prefix
        if mode in ("v1", "auto") and buf[:6] == b"PROXY ":
            self.proxy_protocol_access_check()
            return self._parse_proxy_protocol_v1(unreader, buf)

        # Not proxy protocol - return buffer unchanged
        return buf

    def proxy_protocol_access_check(self):
        """Check if proxy protocol is allowed from this peer."""
        if (isinstance(self.peer_addr, tuple) and
                not ip_in_allow_list(self.peer_addr[0], self.cfg.proxy_allow_ips,
                                     self.cfg.proxy_allow_networks())):
            raise ForbiddenProxyRequest(self.peer_addr[0])

    def _parse_proxy_protocol_v1(self, unreader, buf: bytearray) -> bytearray:
        """Parse PROXY protocol v1 (text format)."""
        data = bytes(buf)
        while b"\r\n" not in data:
            self.read_into(unreader, buf)
            data = bytes(buf)

        idx = data.find(b"\r\n")
        line = bytes_to_str(data[:idx])
        remaining = bytearray(data[idx + 2:])

        bits = line.split(" ")

        if len(bits) != 6:
            raise InvalidProxyLine(line)

        proto = bits[1]
        s_addr = bits[2]
        d_addr = bits[3]

        if proto not in ["TCP4", "TCP6"]:
            raise InvalidProxyLine("protocol '%s' not supported" % proto)
        if proto == "TCP4":
            try:
                socket.inet_pton(socket.AF_INET, s_addr)
                socket.inet_pton(socket.AF_INET, d_addr)
            except OSError:
                raise InvalidProxyLine(line)
        elif proto == "TCP6":
            try:
                socket.inet_pton(socket.AF_INET6, s_addr)
                socket.inet_pton(socket.AF_INET6, d_addr)
            except OSError:
                raise InvalidProxyLine(line)

        try:
            s_port = int(bits[4])
            d_port = int(bits[5])
        except ValueError:
            raise InvalidProxyLine("invalid port %s" % line)

        if not ((0 <= s_port <= 65535) and (0 <= d_port <= 65535)):
            raise InvalidProxyLine("invalid port %s" % line)

        self.proxy_protocol_info = {
            "proxy_protocol": proto,
            "client_addr": s_addr,
            "client_port": s_port,
            "proxy_addr": d_addr,
            "proxy_port": d_port
        }

        return remaining

    def _parse_proxy_protocol_v2(self, unreader, buf: bytearray) -> bytearray:
        """Parse PROXY protocol v2 (binary format)."""
        # We need at least 16 bytes for the header
        while len(buf) < 16:
            self.read_into(unreader, buf)

        # Parse header fields (after 12-byte signature)
        ver_cmd = buf[12]
        fam_proto = buf[13]
        length = struct.unpack(">H", bytes(buf[14:16]))[0]

        # Validate version
        version = (ver_cmd & 0xF0) >> 4
        if version != 2:
            raise InvalidProxyHeader("unsupported version %d" % version)

        # Extract command
        command = ver_cmd & 0x0F
        if command not in (PPCommand.LOCAL, PPCommand.PROXY):
            raise InvalidProxyHeader("unsupported command %d" % command)

        # Ensure we have the complete header
        total_header_size = 16 + length
        while len(buf) < total_header_size:
            self.read_into(unreader, buf)

        # For LOCAL command, no address info is provided
        if command == PPCommand.LOCAL:
            self.proxy_protocol_info = {
                "proxy_protocol": "LOCAL",
                "client_addr": None,
                "client_port": None,
                "proxy_addr": None,
                "proxy_port": None
            }
            return bytearray(buf[total_header_size:])

        # Extract address family and protocol
        family = (fam_proto & 0xF0) >> 4
        protocol = fam_proto & 0x0F

        # We only support TCP (STREAM)
        if protocol != PPProtocol.STREAM:
            raise InvalidProxyHeader("only TCP protocol is supported")

        addr_data = bytes(buf[16:16 + length])

        if family == PPFamily.INET:  # IPv4
            if length < 12:
                raise InvalidProxyHeader("insufficient address data for IPv4")
            s_addr = socket.inet_ntop(socket.AF_INET, addr_data[0:4])
            d_addr = socket.inet_ntop(socket.AF_INET, addr_data[4:8])
            s_port = struct.unpack(">H", addr_data[8:10])[0]
            d_port = struct.unpack(">H", addr_data[10:12])[0]
            proto = "TCP4"

        elif family == PPFamily.INET6:  # IPv6
            if length < 36:
                raise InvalidProxyHeader("insufficient address data for IPv6")
            s_addr = socket.inet_ntop(socket.AF_INET6, addr_data[0:16])
            d_addr = socket.inet_ntop(socket.AF_INET6, addr_data[16:32])
            s_port = struct.unpack(">H", addr_data[32:34])[0]
            d_port = struct.unpack(">H", addr_data[34:36])[0]
            proto = "TCP6"

        elif family == PPFamily.UNSPEC:
            self.proxy_protocol_info = {
                "proxy_protocol": "UNSPEC",
                "client_addr": None,
                "client_port": None,
                "proxy_addr": None,
                "proxy_port": None
            }
            return bytearray(buf[total_header_size:])

        else:
            raise InvalidProxyHeader("unsupported address family %d" % family)

        self.proxy_protocol_info = {
            "proxy_protocol": proto,
            "client_addr": s_addr,
            "client_port": s_port,
            "proxy_addr": d_addr,
            "proxy_port": d_port
        }

        return bytearray(buf[total_header_size:])

    def parse_request_line(self, line_bytes: bytes):
        """Parse HTTP request line (method, uri, version)."""
        bits = [bytes_to_str(bit) for bit in line_bytes.split(b" ", 2)]
        if len(bits) != 3:
            raise InvalidRequestLine(bytes_to_str(line_bytes))

        # Method
        self.method = bits[0]

        if not self.cfg.permit_unconventional_http_method:
            if METHOD_BADCHAR_RE.search(self.method):
                raise InvalidRequestMethod(self.method)
            if not 3 <= len(bits[0]) <= 20:
                raise InvalidRequestMethod(self.method)
        if not TOKEN_RE.fullmatch(self.method):
            raise InvalidRequestMethod(self.method)
        if self.cfg.casefold_http_method:
            self.method = self.method.upper()

        # URI
        self.uri = bits[1]

        if len(self.uri) == 0:
            raise InvalidRequestLine(bytes_to_str(line_bytes))

        try:
            parts = split_request_uri(self.uri)
        except ValueError:
            raise InvalidRequestLine(bytes_to_str(line_bytes))
        self.path = parts.path or ""
        self.query = parts.query or ""
        self.fragment = parts.fragment or ""

        # Version
        match = VERSION_RE.fullmatch(bits[2])
        if match is None:
            raise InvalidHTTPVersion(bits[2])
        self.version = (int(match.group(1)), int(match.group(2)))
        if not (1, 0) <= self.version < (2, 0):
            if not self.cfg.permit_unconventional_http_version:
                raise InvalidHTTPVersion(self.version)

    def set_body_reader(self):
        """Set up body reader, defaulting to empty for requests."""
        super().set_body_reader()
        if isinstance(self.body.reader, EOFReader):
            self.body = Body(LengthReader(self.unreader, 0))
