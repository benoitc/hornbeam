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

"""HTTP Protocol for Erlang Reactor.

This module provides HTTP/1.1 protocol handling for the FD reactor model.
It integrates with hornbeam_http for parsing and supports both WSGI and ASGI apps.

The protocol lifecycle:
1. Connection made - receive FD and client info
2. Read PROXY v2 header (if present)
3. Parse HTTP/1.1 request
4. Build environ/scope
5. Run WSGI/ASGI app
6. Write response
7. Handle keep-alive or close

Example:
    import erlang.reactor as reactor
    from hornbeam_reactor_http import HTTPProtocol, set_wsgi_app

    set_wsgi_app(my_wsgi_app)
    reactor.set_protocol_factory(HTTPProtocol)
"""

import os
import sys
import io
import asyncio
import traceback
from typing import Optional, Dict, Any, Callable, Tuple, List

# Import erlang module for messaging (available when running inside Erlang VM)
try:
    import erlang
    _HAS_ERLANG = True
except ImportError:
    _HAS_ERLANG = False

# Persistent event loop for ASGI tasks (uses Erlang event loop when available)
_persistent_loop: Optional[asyncio.AbstractEventLoop] = None
_use_erlang_loop: Optional[bool] = None

def _get_persistent_loop() -> asyncio.AbstractEventLoop:
    """Get or create persistent event loop for ASGI tasks.

    This loop persists across requests and runs tasks concurrently.
    Priority:
    1. Erlang event loop (when running inside Erlang VM)
    2. uvloop (if installed, for standalone Python)
    3. Standard asyncio event loop (fallback)
    """
    global _persistent_loop, _use_erlang_loop

    if _persistent_loop is not None and not _persistent_loop.is_closed():
        return _persistent_loop

    # Check if running inside Erlang VM (erlang module available)
    if _use_erlang_loop is None:
        _use_erlang_loop = _HAS_ERLANG and hasattr(erlang, 'new_event_loop')

    if _use_erlang_loop:
        _persistent_loop = erlang.new_event_loop()
    else:
        # Try uvloop for better performance outside Erlang VM
        try:
            import uvloop
            _persistent_loop = uvloop.new_event_loop()
        except ImportError:
            _persistent_loop = asyncio.new_event_loop()

    asyncio.set_event_loop(_persistent_loop)
    return _persistent_loop


# Alias for backward compatibility
def _get_event_loop() -> asyncio.AbstractEventLoop:
    """Alias for _get_persistent_loop for backward compatibility."""
    return _get_persistent_loop()


class ASGIState:
    """Mutable state container for ASGI request handling."""
    __slots__ = ('body', 'body_consumed', 'status', 'headers', 'body_parts', 'started')

    def __init__(self, body: io.BytesIO):
        self.body = body
        self.body_consumed = False
        self.status = 0
        self.headers = []
        self.body_parts = []
        self.started = False


async def _asgi_receive(state: ASGIState) -> dict:
    """ASGI receive callable."""
    if state.body_consumed:
        return {'type': 'http.disconnect'}
    state.body_consumed = True
    body = state.body.read() if state.body else b''
    return {'type': 'http.request', 'body': body, 'more_body': False}


async def _asgi_send(state: ASGIState, message: dict) -> None:
    """ASGI send callable."""
    msg_type = message['type']
    if msg_type == 'http.response.start':
        state.started = True
        state.status = message['status']
        state.headers = [
            (name.decode('latin-1') if isinstance(name, bytes) else name,
             value.decode('latin-1') if isinstance(value, bytes) else value)
            for name, value in message.get('headers', [])
        ]
    elif msg_type == 'http.response.body':
        body = message.get('body', b'')
        if body:
            state.body_parts.append(body)

# Import HTTP parsers - prefer fast C parser
sys.path.insert(0, os.path.dirname(__file__))
_fast_parser_path = os.path.join(os.path.dirname(__file__), 'hornbeam_http_fast')
sys.path.insert(0, _fast_parser_path)

# Always import dict-based environ/scope builders
from hornbeam_http_fast import build_environ as fast_build_environ, build_asgi_scope as fast_build_asgi_scope

try:
    from pico_parser_fast import parse_request as _fast_parse_request, IncompleteError, ParseError
    FAST_PARSER = True
except ImportError:
    try:
        # Try standard dict-based parser
        from pico_parser import parse_request as _fast_parse_request, IncompleteError, ParseError
        FAST_PARSER = True
    except ImportError:
        FAST_PARSER = False

# Fallback to pure Python parser
if not FAST_PARSER:
    from hornbeam_http import HTTPConfig, Request, BufferUnreader
    from hornbeam_http.errors import ParseException, NoMoreData
    class IncompleteError(Exception):
        pass
    class ParseError(Exception):
        pass
else:
    # Create wrapper for fast parser to handle HttpRequest object
    def fast_parse_request(data):
        """Parse HTTP request using fast C parser.

        Returns dict with method, path, minor_version, headers, consumed.
        """
        result = _fast_parse_request(data)
        # pico_parser_fast returns HttpRequest object, pico_parser returns dict
        if hasattr(result, 'method'):
            return {
                'method': result.method,
                'path': result.path,
                'minor_version': result.minor_version,
                'headers': result.headers,
                'consumed': result.consumed,
            }
        return result


# PROXY protocol v2 signature
PP_V2_SIGNATURE = b"\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"


# Pre-computed response constants
_HTTP11_PREFIX = b"HTTP/1.1 "
_CRLF = b"\r\n"
_HEADER_SEP = b": "
_CONN_KEEPALIVE = b"Connection: keep-alive\r\n"
_CONN_CLOSE = b"Connection: close\r\n"
_CONTENT_LENGTH_PREFIX = b"Content-Length: "

# Common status lines (pre-encoded)
_STATUS_LINES = {
    200: b"200 OK",
    201: b"201 Created",
    204: b"204 No Content",
    301: b"301 Moved Permanently",
    302: b"302 Found",
    304: b"304 Not Modified",
    400: b"400 Bad Request",
    401: b"401 Unauthorized",
    403: b"403 Forbidden",
    404: b"404 Not Found",
    405: b"405 Method Not Allowed",
    500: b"500 Internal Server Error",
    502: b"502 Bad Gateway",
    503: b"503 Service Unavailable",
}


class HTTPProtocol:
    """HTTP/1.1 protocol for FD reactor.

    Handles HTTP request parsing, WSGI/ASGI app execution, and response writing.
    Supports PROXY protocol v2 and HTTP keep-alive.

    Attributes:
        fd: File descriptor for the connection
        client_info: Dict with connection metadata from Erlang
        config: HTTPConfig for parsing options (fallback parser only)
        buffer: Receive buffer
        write_buffer: Response buffer for writing
        parsed_request: Dict with method, path, headers, etc.
        request_body: BytesIO for request body
        keep_alive: Whether to keep connection alive
        req_count: Number of requests on this connection
    """

    __slots__ = (
        'fd', 'client_info', 'config', 'buffer', 'write_buffer',
        'parsed_request', 'request_body', 'keep_alive', 'req_count',
        'closed', 'content_length', 'chunked', 'body_received',
        'state', '_wsgi_app', '_asgi_app', 'server_addr', 'script_name',
        'root_path', 'peer_addr', 'worker_class', '_fallback_request',
        'reactor_pid',  # PID of reactor context for async completion signaling
    )

    def __init__(self):
        """Initialize protocol with empty state."""
        self.fd = -1
        self.client_info: Dict[str, Any] = {}
        self.config = None  # HTTPConfig for fallback parser
        self.buffer = bytearray()
        self.write_buffer = bytearray()
        self.parsed_request: Optional[Dict[str, Any]] = None
        self.request_body: Optional[io.BytesIO] = None
        self.keep_alive = True
        self.req_count = 0
        self.closed = False

        # Body handling
        self.content_length = 0
        self.chunked = False
        self.body_received = 0

        # State machine
        self.state = 'reading_request'

        # App reference
        self._wsgi_app = None
        self._asgi_app = None

        # Server info
        self.server_addr: Optional[Tuple[str, int]] = None
        self.script_name = ''
        self.root_path = ''
        self.peer_addr: Optional[Tuple[str, int]] = None

        # Worker class and fallback parser state
        self.worker_class = 'wsgi'
        self._fallback_request = None

        # Reactor PID for async completion signaling
        self.reactor_pid = None

    def connection_made(self, fd: int, client_info: dict):
        """Called when FD is handed off from Erlang.

        Args:
            fd: File descriptor for the connection
            client_info: Dict with connection metadata
        """
        self.fd = fd
        self.client_info = client_info

        # Extract config for fallback parser
        if not FAST_PARSER:
            config_dict = client_info.get('config', {})
            self.config = HTTPConfig.from_dict(config_dict)

        # Extract server info
        self.server_addr = client_info.get('server_addr')
        self.script_name = client_info.get('script_name', '')
        self.root_path = client_info.get('root_path', '')

        # Extract peer address
        peer = client_info.get('peer_addr')
        if isinstance(peer, dict):
            self.peer_addr = (peer.get('ip'), peer.get('port'))
        elif isinstance(peer, tuple):
            self.peer_addr = peer
        else:
            self.peer_addr = None

        # Get app from client_info or global
        self._wsgi_app = client_info.get('wsgi_app') or _global_wsgi_app
        self._asgi_app = client_info.get('asgi_app') or _global_asgi_app

        # Determine worker class
        self.worker_class = client_info.get('worker_class', 'wsgi')

        # Extract reactor PID for async completion signaling
        self.reactor_pid = client_info.get('reactor_pid')

        # Reset state for new connection
        self.buffer.clear()
        self.write_buffer.clear()
        self.parsed_request = None
        self.request_body = None
        self.keep_alive = True
        self.req_count = 0
        self.content_length = 0
        self.chunked = False
        self.body_received = 0
        self.state = 'reading_request'

    def data_received(self, data: bytes) -> str:
        """Handle received data.

        Called when data has been read from the FD.

        Args:
            data: The bytes that were read

        Returns:
            Action string: "continue", "write_pending", or "close"
        """
        self.buffer.extend(data)

        try:
            if self.state == 'reading_request':
                return self._handle_reading_request()
            elif self.state == 'reading_body':
                return self._handle_reading_body()
        except IncompleteError:
            return "continue"  # Need more data
        except ParseError as e:
            return self._send_error_response(400, str(e))
        except Exception as e:
            traceback.print_exc()
            return self._send_error_response(500, "Internal Server Error")

        return "continue"

    def _handle_reading_request(self) -> str:
        """Handle reading request line and headers."""
        data = bytes(self.buffer)

        # Check for PROXY v2 header if this is first request
        proxy_offset = 0
        if self.req_count == 0 and len(data) >= 12:
            if data[:12] == PP_V2_SIGNATURE:
                if len(data) < 16:
                    return "continue"
                import struct
                proxy_len = struct.unpack(">H", data[14:16])[0]
                if len(data) < 16 + proxy_len:
                    return "continue"
                # Parse PROXY v2 header for peer info
                self._parse_proxy_v2(data[:16 + proxy_len])
                proxy_offset = 16 + proxy_len
                data = data[proxy_offset:]

        # Check if we have complete headers
        if b"\r\n\r\n" not in data:
            return "continue"

        # Parse using fast or fallback parser
        if FAST_PARSER:
            return self._handle_fast_parse(data, proxy_offset)
        else:
            return self._handle_fallback_parse(data, proxy_offset)

    def _parse_proxy_v2(self, header: bytes):
        """Parse PROXY v2 header and extract peer address."""
        if len(header) < 16:
            return
        ver_cmd = header[12]
        fam_proto = header[13]

        # Only handle PROXY command (not LOCAL)
        if (ver_cmd & 0x0F) != 0x01:
            return

        family = (fam_proto >> 4) & 0x0F
        if family == 0x01:  # IPv4
            if len(header) >= 28:
                import socket
                src_ip = socket.inet_ntoa(header[16:20])
                src_port = int.from_bytes(header[24:26], 'big')
                self.peer_addr = (src_ip, src_port)
        elif family == 0x02:  # IPv6
            if len(header) >= 52:
                import socket
                src_ip = socket.inet_ntop(socket.AF_INET6, header[16:32])
                src_port = int.from_bytes(header[48:50], 'big')
                self.peer_addr = (src_ip, src_port)

    def _handle_fast_parse(self, data: bytes, proxy_offset: int) -> str:
        """Handle request parsing with fast C parser."""
        self.parsed_request = fast_parse_request(data)
        consumed = self.parsed_request['consumed']

        # Clear buffer up to consumed bytes
        del self.buffer[:proxy_offset + consumed]

        self.req_count += 1

        # Check headers for body handling and keep-alive
        self.content_length = 0
        self.chunked = False
        connection_close = False

        for name, value in self.parsed_request['headers']:
            name_lower = name.lower() if isinstance(name, str) else name.lower()
            value_str = value.decode('latin-1') if isinstance(value, bytes) else value

            if name_lower == b'content-length':
                self.content_length = int(value_str)
            elif name_lower == b'transfer-encoding' and b'chunked' in value.lower():
                self.chunked = True
            elif name_lower == b'connection':
                if b'close' in value.lower():
                    connection_close = True
                elif b'keep-alive' in value.lower():
                    self.keep_alive = True

        # Determine keep-alive from HTTP version if not explicit
        if not connection_close:
            # HTTP/1.1 defaults to keep-alive
            self.keep_alive = self.parsed_request.get('minor_version', 1) >= 1
        else:
            self.keep_alive = False

        # Handle body
        if self.content_length > 0 or self.chunked:
            self.body_received = len(self.buffer)  # Any remaining data is body
            self.state = 'reading_body'
            return self._handle_reading_body()
        else:
            self.request_body = io.BytesIO(b'')
            return self._run_app()

    def _handle_fallback_parse(self, data: bytes, proxy_offset: int) -> str:
        """Handle request parsing with fallback Python parser."""
        # Create unreader from buffer
        unreader = BufferUnreader(data)

        # Parse request
        self.req_count += 1
        request = Request(
            self.config,
            unreader,
            self.peer_addr,
            req_number=self.req_count
        )

        # Convert to dict format
        self.parsed_request = {
            'method': request.method.encode() if isinstance(request.method, str) else request.method,
            'path': request.path.encode() if isinstance(request.path, str) else request.path,
            'minor_version': request.version[1] if request.version else 1,
            'headers': [(n.encode() if isinstance(n, str) else n,
                        v.encode() if isinstance(v, str) else v)
                       for n, v in request.headers],
        }

        # Clear buffer
        self.buffer.clear()

        # Check if body needs to be read
        self.content_length = 0
        self.chunked = False
        for name, value in request.headers:
            if name.upper() == 'CONTENT-LENGTH':
                self.content_length = int(value)
            elif name.upper() == 'TRANSFER-ENCODING' and 'chunked' in value.lower():
                self.chunked = True

        self.keep_alive = not request.should_close()

        if self.content_length > 0 or self.chunked:
            # Store the request for body reading
            self._fallback_request = request
            self.state = 'reading_body'
            return self._handle_reading_body()
        else:
            self.request_body = io.BytesIO(b'')
            return self._run_app()

    def _handle_reading_body(self) -> str:
        """Handle reading request body."""
        if FAST_PARSER:
            return self._handle_fast_body()
        else:
            return self._handle_fallback_body()

    def _handle_fast_body(self) -> str:
        """Handle body reading with fast parser path."""
        if self.chunked:
            # For chunked, need to parse chunk headers
            # For now, simple implementation: accumulate until 0\r\n\r\n
            data = bytes(self.buffer)
            if b'0\r\n\r\n' in data or b'0\r\n' in data:
                # Parse chunked body
                body_parts = []
                pos = 0
                while pos < len(data):
                    # Find chunk size line
                    nl_pos = data.find(b'\r\n', pos)
                    if nl_pos == -1:
                        return "continue"
                    size_line = data[pos:nl_pos]
                    try:
                        chunk_size = int(size_line.split(b';')[0], 16)
                    except ValueError:
                        return self._send_error_response(400, "Invalid chunk size")

                    if chunk_size == 0:
                        break

                    chunk_start = nl_pos + 2
                    chunk_end = chunk_start + chunk_size
                    if chunk_end + 2 > len(data):
                        return "continue"

                    body_parts.append(data[chunk_start:chunk_end])
                    pos = chunk_end + 2  # Skip \r\n after chunk

                self.request_body = io.BytesIO(b''.join(body_parts))
                self.buffer.clear()
                return self._run_app()
            return "continue"
        else:
            # Content-Length body
            self.body_received = len(self.buffer)
            if self.body_received >= self.content_length:
                body = bytes(self.buffer[:self.content_length])
                del self.buffer[:self.content_length]
                self.request_body = io.BytesIO(body)
                return self._run_app()
            return "continue"

    def _handle_fallback_body(self) -> str:
        """Handle body reading with fallback parser path."""
        try:
            if self.buffer:
                self._fallback_request.unreader.feed(bytes(self.buffer))
                self.buffer.clear()

            body_data = self._fallback_request.body.read()
            if body_data is not None:
                self.request_body = io.BytesIO(body_data)
                return self._run_app()
        except NoMoreData:
            return "continue"
        return "continue"

    def _run_app(self) -> str:
        """Run WSGI or ASGI app and prepare response."""
        if self.worker_class == 'asgi':
            return self._run_asgi_app()
        else:
            return self._run_wsgi_app()

    def _run_wsgi_app(self) -> str:
        """Run WSGI app and prepare response."""
        if not self._wsgi_app:
            return self._send_error_response(500, "No WSGI app configured")

        # Build environ (both fast and fallback paths use dict format)
        environ = fast_build_environ(
            self.parsed_request,
            peer_addr=self.peer_addr,
            server_addr=self.server_addr,
            script_name=self.script_name
        )

        # Add wsgi.input and wsgi.errors
        environ['wsgi.input'] = self.request_body
        environ['wsgi.errors'] = sys.stderr

        # Run the app
        response_started = False
        status_line = None
        response_headers = None

        def start_response(status, headers, exc_info=None):
            nonlocal response_started, status_line, response_headers
            if exc_info:
                try:
                    if response_started:
                        raise exc_info[1].with_traceback(exc_info[2])
                finally:
                    exc_info = None
            elif response_started:
                raise RuntimeError("Response already started")

            status_line = status
            response_headers = headers
            response_started = True

        try:
            result = self._wsgi_app(environ, start_response)
            try:
                response_body = b"".join(result)
            finally:
                if hasattr(result, 'close'):
                    result.close()
        except Exception as e:
            traceback.print_exc()
            return self._send_error_response(500, "Internal Server Error")

        if not response_started:
            return self._send_error_response(500, "App did not start response")

        # Build HTTP response
        return self._prepare_response(status_line, response_headers, response_body)

    def _run_asgi_app(self) -> str:
        """Run ASGI app as non-blocking task.

        If reactor_pid is available, submits task and returns "async_pending".
        Otherwise, falls back to synchronous run_until_complete.
        """
        if not self._asgi_app:
            return self._send_error_response(500, "No ASGI app configured")

        # Build scope (both fast and fallback paths use dict format)
        scope = fast_build_asgi_scope(
            self.parsed_request,
            peer_addr=self.peer_addr,
            server_addr=self.server_addr,
            root_path=self.root_path
        )

        # Get body bytes for task (avoid sharing BytesIO across tasks)
        body_bytes = self.request_body.read() if self.request_body else b''

        # If we have reactor_pid, use async task submission
        if self.reactor_pid is not None and _HAS_ERLANG:
            return self._submit_asgi_task(scope, body_bytes)

        # Fallback: synchronous execution (for standalone Python or testing)
        return self._run_asgi_sync(scope, body_bytes)

    def _submit_asgi_task(self, scope: dict, body_bytes: bytes) -> str:
        """Submit ASGI app as non-blocking task to persistent event loop.

        The task runs concurrently with other requests. When complete,
        it signals the reactor via erlang.send() to trigger write.

        Returns:
            "async_pending" - reactor should wait for write_ready signal
        """
        loop = _get_persistent_loop()

        # Create task that will run the ASGI app
        task = loop.create_task(
            self._run_asgi_task(scope, body_bytes)
        )

        # Add done callback to handle errors
        task.add_done_callback(self._on_asgi_task_done)

        self.state = 'async_pending'
        return "async_pending"

    async def _run_asgi_task(self, scope: dict, body_bytes: bytes) -> None:
        """Run ASGI app as async task and signal reactor on completion.

        This coroutine:
        1. Runs the ASGI app with receive/send callables
        2. Prepares the response buffer
        3. Signals the reactor that response is ready
        """
        state = ASGIState(io.BytesIO(body_bytes))

        async def receive():
            return await _asgi_receive(state)

        async def send(message):
            await _asgi_send(state, message)

        try:
            await self._asgi_app(scope, receive, send)

            if not state.started:
                status_bytes = _STATUS_LINES.get(500)
                self._prepare_response_fast(
                    status_bytes,
                    [(b'Content-Type', b'text/plain')],
                    b"App did not start response"
                )
            else:
                status_bytes = _STATUS_LINES.get(state.status)
                if status_bytes is None:
                    status_bytes = f"{state.status} Unknown".encode('latin-1')
                self._prepare_response_fast(
                    status_bytes,
                    state.headers,
                    b''.join(state.body_parts)
                )

        except Exception as e:
            traceback.print_exc()
            status_bytes = _STATUS_LINES.get(500)
            self._prepare_response_fast(
                status_bytes,
                [(b'Content-Type', b'text/plain')],
                f"Internal Server Error: {e}".encode('utf-8')
            )

        # Signal reactor that response is ready
        try:
            erlang.send(self.reactor_pid, ('write_ready', self.fd))
        except Exception:
            # Reactor may have died, connection will be cleaned up
            pass

    def _on_asgi_task_done(self, task: asyncio.Task) -> None:
        """Handle ASGI task completion/exception (for logging purposes)."""
        if task.cancelled():
            return
        exc = task.exception()
        if exc is not None:
            # Exception should have been handled in _run_asgi_task
            # but log it just in case
            traceback.print_exception(type(exc), exc, exc.__traceback__)

    def _run_asgi_sync(self, scope: dict, body_bytes: bytes) -> str:
        """Run ASGI app synchronously (fallback for non-reactor mode)."""
        state = ASGIState(io.BytesIO(body_bytes))

        receive = lambda: _asgi_receive(state)
        send = lambda msg: _asgi_send(state, msg)

        try:
            _get_event_loop().run_until_complete(self._asgi_app(scope, receive, send))
        except Exception as e:
            traceback.print_exc()
            return self._send_error_response(500, "Internal Server Error")

        if not state.started:
            return self._send_error_response(500, "App did not start response")

        status_bytes = _STATUS_LINES.get(state.status)
        if status_bytes is None:
            status_bytes = f"{state.status} Unknown".encode('latin-1')

        return self._prepare_response_fast(status_bytes, state.headers, b''.join(state.body_parts))

    def _prepare_response_fast(self, status_bytes: bytes, headers: List[Tuple], body: bytes) -> str:
        """Build HTTP response using pre-computed constants."""
        # Pre-allocate response buffer with estimated size
        # HTTP/1.1 + status + headers + body
        response = bytearray(len(body) + 256)
        response.clear()

        # Status line
        response.extend(_HTTP11_PREFIX)
        response.extend(status_bytes)
        response.extend(_CRLF)

        # Add headers
        has_content_length = False
        has_connection = False

        for name, value in headers:
            # Handle both bytes and str headers
            if isinstance(name, bytes):
                name_lower = name.lower()
                response.extend(name)
            else:
                name_lower = name.lower().encode('latin-1')
                response.extend(name.encode('latin-1'))

            response.extend(_HEADER_SEP)

            if isinstance(value, bytes):
                response.extend(value)
            else:
                response.extend(value.encode('latin-1'))

            response.extend(_CRLF)

            if name_lower == b'content-length':
                has_content_length = True
            elif name_lower == b'connection':
                has_connection = True
                if isinstance(value, bytes):
                    self.keep_alive = value.lower() == b'keep-alive'
                else:
                    self.keep_alive = value.lower() == 'keep-alive'

        # Add Content-Length if not present
        if not has_content_length and body:
            response.extend(_CONTENT_LENGTH_PREFIX)
            response.extend(str(len(body)).encode('ascii'))
            response.extend(_CRLF)

        # Add Connection header if not present
        if not has_connection:
            response.extend(_CONN_KEEPALIVE if self.keep_alive else _CONN_CLOSE)

        response.extend(_CRLF)
        response.extend(body)

        self.write_buffer = response
        self.state = 'writing_response'
        return "write_pending"

    def _prepare_response(self, status_line: str, headers: List[Tuple[str, str]], body: bytes) -> str:
        """Build HTTP response (compatibility wrapper)."""
        status_bytes = status_line.encode('latin-1')
        return self._prepare_response_fast(status_bytes, headers, body)

    def _send_error_response(self, code: int, message: str) -> str:
        """Send error response."""
        status_bytes = _STATUS_LINES.get(code)
        if status_bytes is None:
            status_bytes = f"{code} Error".encode('latin-1')

        body = code.to_bytes(2, 'big')  # Avoid string formatting for common path
        body = f"{code} {message}".encode('utf-8')

        headers = [
            (b'Content-Type', b'text/plain'),
            (b'Content-Length', str(len(body)).encode('ascii')),
            (b'Connection', b'close'),
        ]

        self.keep_alive = False
        return self._prepare_response_fast(status_bytes, headers, body)

    def write_ready(self) -> str:
        """Handle write readiness.

        Called when the FD is ready for writing.

        Returns:
            Action string: "continue", "read_pending", or "close"
        """
        if not self.write_buffer:
            if self.keep_alive:
                self._reset_for_keepalive()
                return "read_pending"
            return "close"

        try:
            written = os.write(self.fd, bytes(self.write_buffer))
            del self.write_buffer[:written]
        except (BlockingIOError, OSError):
            pass

        if self.write_buffer:
            return "continue"  # More to write

        # Response complete
        if self.keep_alive:
            self._reset_for_keepalive()
            return "read_pending"
        return "close"

    def _reset_for_keepalive(self):
        """Reset state for next request on keep-alive connection."""
        self.buffer.clear()
        self.write_buffer.clear()
        self.parsed_request = None
        self.request_body = None
        self.content_length = 0
        self.chunked = False
        self.body_received = 0
        self.state = 'reading_request'

    def connection_lost(self):
        """Called when connection closes."""
        self.closed = True
        self.parsed_request = None
        self.request_body = None


# =============================================================================
# Global App Registry
# =============================================================================

_global_wsgi_app: Optional[Callable] = None
_global_asgi_app: Optional[Callable] = None


def set_wsgi_app(app: Callable):
    """Set global WSGI app for HTTPProtocol.

    Args:
        app: WSGI application callable
    """
    global _global_wsgi_app
    _global_wsgi_app = app


def set_asgi_app(app: Callable):
    """Set global ASGI app for HTTPProtocol.

    Args:
        app: ASGI application callable
    """
    global _global_asgi_app
    _global_asgi_app = app


def get_protocol_factory(worker_class: str = 'wsgi'):
    """Get protocol factory configured for worker class.

    Args:
        worker_class: 'wsgi' or 'asgi'

    Returns:
        Factory function that creates HTTPProtocol instances
    """
    def factory():
        proto = HTTPProtocol()
        proto.worker_class = worker_class
        return proto
    return factory


# =============================================================================
# Integration with erlang.reactor
# =============================================================================

# If erlang.reactor is available, set up integration
try:
    import erlang.reactor as reactor

    def setup_http_reactor(wsgi_app=None, asgi_app=None, worker_class='wsgi'):
        """Set up HTTP reactor with given app.

        Args:
            wsgi_app: WSGI application callable (optional)
            asgi_app: ASGI application callable (optional)
            worker_class: 'wsgi' or 'asgi'
        """
        if wsgi_app:
            set_wsgi_app(wsgi_app)
        if asgi_app:
            set_asgi_app(asgi_app)
        reactor.set_protocol_factory(get_protocol_factory(worker_class))

except ImportError:
    # erlang.reactor not available
    def setup_http_reactor(*args, **kwargs):
        raise RuntimeError("erlang.reactor not available")
