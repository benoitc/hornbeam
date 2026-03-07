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

"""HTTP parsing errors - adapted from gunicorn."""


class ParseException(Exception):
    """Base exception for HTTP parsing errors."""
    pass


class NoMoreData(IOError):
    """Raised when no more data is available."""

    def __init__(self, buf=None):
        self.buf = buf

    def __str__(self):
        return "No more data after: %r" % self.buf


class ConfigurationProblem(ParseException):
    """Configuration error."""

    def __init__(self, info):
        self.info = info
        self.code = 500

    def __str__(self):
        return "Configuration problem: %s" % self.info


class InvalidRequestLine(ParseException):
    """Invalid HTTP request line."""

    def __init__(self, req):
        self.req = req
        self.code = 400

    def __str__(self):
        return "Invalid HTTP request line: %r" % self.req


class InvalidRequestMethod(ParseException):
    """Invalid HTTP method."""

    def __init__(self, method):
        self.method = method
        self.code = 400

    def __str__(self):
        return "Invalid HTTP method: %r" % self.method


class ExpectationFailed(ParseException):
    """Unable to comply with Expect header."""

    def __init__(self, expect):
        self.expect = expect
        self.code = 417

    def __str__(self):
        return "Unable to comply with expectation: %r" % (self.expect,)


class InvalidHTTPVersion(ParseException):
    """Invalid HTTP version."""

    def __init__(self, version):
        self.version = version
        self.code = 400

    def __str__(self):
        return "Invalid HTTP Version: %r" % (self.version,)


class InvalidHeader(ParseException):
    """Invalid HTTP header."""

    def __init__(self, hdr, req=None):
        self.hdr = hdr
        self.req = req
        self.code = 400

    def __str__(self):
        return "Invalid HTTP Header: %r" % self.hdr


class ObsoleteFolding(ParseException):
    """Obsolete line folding is unacceptable."""

    def __init__(self, hdr):
        self.hdr = hdr
        self.code = 400

    def __str__(self):
        return "Obsolete line folding is unacceptable: %r" % (self.hdr,)


class InvalidHeaderName(ParseException):
    """Invalid HTTP header name."""

    def __init__(self, hdr):
        self.hdr = hdr
        self.code = 400

    def __str__(self):
        return "Invalid HTTP header name: %r" % self.hdr


class UnsupportedTransferCoding(ParseException):
    """Unsupported transfer coding."""

    def __init__(self, hdr):
        self.hdr = hdr
        self.code = 501

    def __str__(self):
        return "Unsupported transfer coding: %r" % self.hdr


class InvalidChunkSize(IOError):
    """Invalid chunk size in chunked encoding."""

    def __init__(self, data):
        self.data = data

    def __str__(self):
        return "Invalid chunk size: %r" % self.data


class ChunkMissingTerminator(IOError):
    """Chunk missing CRLF terminator."""

    def __init__(self, term):
        self.term = term

    def __str__(self):
        return "Invalid chunk terminator is not '\\r\\n': %r" % self.term


class LimitRequestLine(ParseException):
    """Request line too large."""

    def __init__(self, size, max_size):
        self.size = size
        self.max_size = max_size
        self.code = 414

    def __str__(self):
        return "Request Line is too large (%s > %s)" % (self.size, self.max_size)


class LimitRequestHeaders(ParseException):
    """Request headers too large or too many."""

    def __init__(self, msg):
        self.msg = msg
        self.code = 431

    def __str__(self):
        return self.msg


class InvalidProxyLine(ParseException):
    """Invalid PROXY protocol v1 line."""

    def __init__(self, line):
        self.line = line
        self.code = 400

    def __str__(self):
        return "Invalid PROXY line: %r" % self.line


class InvalidProxyHeader(ParseException):
    """Invalid PROXY protocol v2 header."""

    def __init__(self, msg):
        self.msg = msg
        self.code = 400

    def __str__(self):
        return "Invalid PROXY header: %s" % self.msg


class ForbiddenProxyRequest(ParseException):
    """PROXY protocol not allowed from this host."""

    def __init__(self, host):
        self.host = host
        self.code = 403

    def __str__(self):
        return "Proxy request from %r not allowed" % self.host


class InvalidSchemeHeaders(ParseException):
    """Contradictory scheme headers."""

    def __init__(self):
        self.code = 400

    def __str__(self):
        return "Contradictory scheme headers"
