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

"""High-performance ASGI worker using py_event_loop.

This module provides an ASGI worker that uses the Erlang event loop
for true async execution. It supports:

- Full async execution via py_event_loop
- Streaming responses via erlang.send()
- Sub-millisecond latency using Erlang timers
- No message passing overhead for continuations

Architecture:
1. Erlang submits task to py_event_loop:create_task()
2. Python runs async app with Erlang-backed event loop
3. Response streamed via erlang.send() as chunks arrive
4. Event-driven - no polling, no busy waiting
"""

import asyncio
import importlib
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import erlang
    from erlang import ByteChannel, ByteChannelClosed
    HAS_ERLANG = True
    # Cache erlang.send for faster lookups (avoids attribute access per call)
    _erlang_send = erlang.send
except ImportError:
    HAS_ERLANG = False
    erlang = None
    _erlang_send = None
    ByteChannel = None
    ByteChannelClosed = Exception


class _MutableStateProxy(dict):
    """A dict subclass that syncs mutations back to Erlang ETS.

    When items are set, the change is sent to hornbeam_lifespan process
    which persists it to ETS. Subsequent requests see the updated value.

    This implements ASGI-compliant mutable scope['state'] behavior.
    """

    __slots__ = ('_mount_id', '_lifespan_pid')

    def __init__(self, initial_state: dict, mount_id: Optional[str] = None):
        super().__init__(initial_state)
        self._mount_id = mount_id
        # Lookup hornbeam_lifespan PID once at construction
        self._lifespan_pid = None
        if HAS_ERLANG:
            try:
                self._lifespan_pid = erlang.whereis("hornbeam_lifespan")
            except Exception:
                pass

    def __setitem__(self, key, value):
        # Update local dict
        super().__setitem__(key, value)
        # Send update to Erlang (fire-and-forget)
        if self._lifespan_pid is not None:
            try:
                if self._mount_id is not None:
                    # Multi-app mode: {update_state, MountId, Key, Value}
                    _erlang_send(self._lifespan_pid,
                                (b'update_state', self._mount_id, key, value))
                else:
                    # Single-app mode: {update_state, Key, Value}
                    _erlang_send(self._lifespan_pid,
                                (b'update_state', key, value))
            except Exception:
                pass  # Don't fail request if state sync fails

    def update(self, other=None, **kwargs):
        """Override update to sync each key."""
        if other:
            for k, v in (other.items() if hasattr(other, 'items') else other):
                self[k] = v
        for k, v in kwargs.items():
            self[k] = v

    def setdefault(self, key, default=None):
        """Override setdefault to sync if key is added."""
        if key not in self:
            self[key] = default
        return self[key]


# ============================================================================
# App loading and preloading
# ============================================================================

# Cached app reference - set by preload_app() for fast access
_preloaded_app: Callable = None
_preloaded_key: Tuple[str, str] = None


def preload_app(app_module: str, app_callable: str) -> bytes:
    """Preload ASGI application at startup for zero-overhead access."""
    global _preloaded_app, _preloaded_key

    # erlang_python converts binaries to str automatically (UTF-8 decode in C)
    module_name = app_module
    callable_name = app_callable

    module = importlib.import_module(module_name)
    app = getattr(module, callable_name)

    _preloaded_app = app
    _preloaded_key = (module_name, callable_name)

    return b'ok'


def _get_app(module_name: str, callable_name: str) -> Callable:
    """Get ASGI application - uses preloaded app if available."""
    if _preloaded_key == (module_name, callable_name):
        return _preloaded_app

    # Fallback: import on demand
    module = importlib.import_module(module_name)
    return getattr(module, callable_name)


# ============================================================================
# Helpers
# ============================================================================

def _to_bytes(val) -> bytes:
    """Convert string to bytes."""
    if isinstance(val, bytes):
        return val
    if isinstance(val, str):
        return val.encode('utf-8')
    return b''




# ============================================================================
# Pre-allocated messages
# ============================================================================

_DISCONNECT_MSG = {'type': 'http.disconnect'}


# ============================================================================
# Main entry point: handle_asgi (async)
# ============================================================================

async def handle_asgi(caller_pid, app_module: bytes, app_callable: bytes,
                      scope: dict, req_body_ch, resp_body_ch):
    """Handle an ASGI request asynchronously.

    This is the main entry point called from Erlang via py_event_loop:create_task.
    Uses byte channels for body data and erlang.send() for control messages.

    Transport design:
    - Control plane (mailbox): headers, early_hints, error, response (small)
    - Data plane (byte channels): request body (ReqBodyCh), response body (RespBodyCh)

    Args:
        caller_pid: Erlang PID to send control messages to
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict
        req_body_ch: ByteChannel reference for reading request body
        resp_body_ch: ByteChannel reference for writing response body
    """
    if not HAS_ERLANG:
        return

    # erlang_python converts binaries to str in C (UTF-8 decode)
    module_name = app_module
    callable_name = app_callable

    # Wrap channel references
    req_channel = ByteChannel(req_body_ch)
    resp_channel = ByteChannel(resp_body_ch)

    try:
        # Get app (preloaded or import on demand)
        app = _get_app(module_name, callable_name)

        # Wrap scope['state'] with mutable proxy that syncs to Erlang ETS
        # This implements ASGI-compliant mutable state behavior
        if 'state' in scope:
            mount_id = scope.get('mount_id')
            scope['state'] = _MutableStateProxy(scope['state'], mount_id)

        # Create receive/send callables with byte channels
        receive = _ASGIReceive(req_channel)
        send = _ASGISend(caller_pid, resp_channel)

        # Run ASGI app
        await app(scope, receive, send)

        # Ensure completion is signaled
        if not send.finished:
            if not send.headers_sent:
                _erlang_send(caller_pid, (b'headers', 500, []))
            # close the channel to signal EOF
            try:
                resp_channel.close()
            except ByteChannelClosed:
                pass
    except Exception as e:
        try:
            # close the channel, then send error
            resp_channel.close()
            _erlang_send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass


class _ASGIReceive:
    """ASGI receive callable using ByteChannel for request body.

    Reads request body chunks from the byte channel provided by Erlang.
    Channel close signals EOF (no more body data).
    """
    __slots__ = ('channel', 'disconnected', '_eof_reached')

    def __init__(self, channel):
        """Initialize receive callable.

        Args:
            channel: ByteChannel for reading request body from Erlang
        """
        self.channel = channel
        self.disconnected = False
        self._eof_reached = False

    async def __call__(self) -> dict:
        if self.disconnected:
            return _DISCONNECT_MSG

        if self._eof_reached:
            # Already reached EOF - return disconnect
            self.disconnected = True
            return _DISCONNECT_MSG

        chunk = await self._read_chunk()
        if not chunk:
            # Channel closed = EOF
            self._eof_reached = True
            return {'type': 'http.request', 'body': b'', 'more_body': False}
        # Got data - return with more_body=True (may have more)
        return {'type': 'http.request', 'body': chunk, 'more_body': True}
            
    async def _read_chunk(self) -> bytes | None:
        """Read next chunk asynchronously.

        Channel close signals EOF.
        """
        try:
            chunk = await self.channel.async_receive_bytes()
            return chunk
        except ByteChannelClosed:
            return None


class _ASGISend:
    """ASGI send callable using ByteChannel for response body.

    Transport design:
    - Control plane (erlang.send): headers, early_hints, response (small)
    - Data plane (ByteChannel): response body for streaming

    For small responses (< BUFFER_THRESHOLD), sends complete response via
    erlang.send() for efficiency. For larger/streaming responses, sends
    headers via erlang.send() and body via ByteChannel.
    """
    __slots__ = ('caller_pid', 'resp_channel', 'status', 'headers',
                 'headers_sent', 'body_parts', 'finished', '_send', '_total_size')

    # Buffer small responses before sending (optimization)
    BUFFER_THRESHOLD = 65536

    def __init__(self, caller_pid, resp_channel):
        """Initialize send callable.

        Args:
            caller_pid: Erlang PID for control messages
            resp_channel: ByteChannel for writing response body
        """
        self.caller_pid = caller_pid
        self.resp_channel = resp_channel
        self._send = _erlang_send  # Cached function reference
        self.status = None
        self.headers = []
        self.headers_sent = False
        self.body_parts = []  # Buffer for small responses
        self.finished = False
        self._total_size = 0

    async def __call__(self, message: dict) -> None:
        if self.finished:
            raise RuntimeError("Response already completed")

        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            if self.headers_sent:
                raise RuntimeError("http.response.start already sent")
            self.status = message.get('status', 200)
            self.headers = message.get('headers', [])
            self._send(self.caller_pid, (b'headers', self.status or 200, self.headers))
            self.headers_sent = True

        elif msg_type == 'http.response.body':
            if not self.headers_sent:
                raise RuntimeError("http.response.start must be sent before http.response.body")

            body_part = message.get('body', b'')
            if isinstance(body_part, str):
                body_part = body_part.encode('utf-8')

            more_body = message.get('more_body', False)

            # Send body to channel
            try:
                self.resp_channel.send_bytes(body_part)
            except ByteChannelClosed:
                self.finished = True
                raise OSError("Client disconnected")

            if not more_body:
                self.resp_channel.close()
                self.finished = True

        elif msg_type == 'http.response.informational':
            # Early hints (103) - control message via mailbox
            status = message.get('status', 100)
            headers = message.get('headers', [])
            if status == 103:
                self._send(self.caller_pid, (b'early_hints', headers))

        elif msg_type == 'http.disconnect':
            # We close the channel to signal EOF
            self.resp_channel.close()
            self.finished = True


# ============================================================================
# Synchronous wrapper for context_call
# ============================================================================

def handle_asgi_sync(caller_pid, app_module: bytes, app_callable: bytes,
                     scope: dict, req_body_ch, resp_body_ch):
    """Synchronous wrapper that runs handle_asgi with erlang.run().

    This is used when calling from py_nif:context_call() which expects
    a synchronous function. Uses erlang.run() for proper Erlang event
    loop integration.

    Args:
        caller_pid: Erlang PID to send control messages to
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict
        req_body_ch: ByteChannel reference for reading request body
        resp_body_ch: ByteChannel reference for writing response body
    """
    if not HAS_ERLANG:
        return b'error'

    try:
        # Use erlang.run() for proper Erlang event loop integration
        erlang.run(handle_asgi(caller_pid, app_module, app_callable, scope,
                               req_body_ch, resp_body_ch))
        return b'done'
    except Exception as e:
        try:
            _erlang_send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass
        return b'error'


# ============================================================================
# WebSocket support
# ============================================================================

async def handle_websocket(caller_pid, app_module: bytes, app_callable: bytes,
                           scope: dict, channel_ref):
    """Handle a WebSocket connection.

    WebSocket messages are received from and sent to the channel.
    The app can send/receive messages asynchronously.

    Args:
        caller_pid: Erlang PID for control messages
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict with type='websocket'
        channel_ref: Channel reference for WebSocket messages
    """
    if not HAS_ERLANG:
        return

    from erlang import Channel, ChannelClosed

    # erlang_python converts binaries to str in C (UTF-8 decode)
    module_name = app_module
    callable_name = app_callable

    channel = Channel(channel_ref)
    connected = False
    closed = False

    async def receive() -> dict:
        nonlocal connected, closed

        if closed:
            return {'type': 'websocket.disconnect', 'code': 1000}

        try:
            msg = channel.receive(timeout=60000)

            if isinstance(msg, tuple):
                tag = msg[0]

                if tag == b'connect' or tag == 'connect':
                    connected = True
                    return {'type': 'websocket.connect'}

                elif tag == b'text' or tag == 'text':
                    # Text from channel - already str from erlang_python
                    return {'type': 'websocket.receive', 'text': msg[1]}

                elif tag == b'bytes' or tag == 'bytes':
                    return {'type': 'websocket.receive', 'bytes': _to_bytes(msg[1])}

                elif tag == b'disconnect' or tag == 'disconnect':
                    code = msg[1] if len(msg) > 1 else 1000
                    closed = True
                    return {'type': 'websocket.disconnect', 'code': code}

            elif msg == b'connect' or msg == 'connect':
                connected = True
                return {'type': 'websocket.connect'}

        except ChannelClosed:
            closed = True
            return {'type': 'websocket.disconnect', 'code': 1006}

        return {'type': 'websocket.disconnect', 'code': 1000}

    async def send(message: dict) -> None:
        nonlocal connected, closed

        msg_type = message.get('type', '')

        if msg_type == 'websocket.accept':
            connected = True
            subprotocol = message.get('subprotocol')
            headers = message.get('headers', [])
            _erlang_send(caller_pid, (b'accept', subprotocol, headers))

        elif msg_type == 'websocket.send':
            if 'text' in message:
                _erlang_send(caller_pid, (b'text', message['text']))
            elif 'bytes' in message:
                _erlang_send(caller_pid, (b'bytes', message['bytes']))

        elif msg_type == 'websocket.close':
            code = message.get('code', 1000)
            reason = message.get('reason', '')
            _erlang_send(caller_pid, (b'close', code, reason))
            closed = True

    try:
        app = _get_app(module_name, callable_name)
        await app(scope, receive, send)

        # Ensure close is sent
        if not closed:
            _erlang_send(caller_pid, (b'close', 1000, b''))

    except Exception as e:
        try:
            _erlang_send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass


def handle_request_direct(args_tuple) -> None:
    """Legacy entry point - uses sync wrapper."""
    if not HAS_ERLANG:
        return

    caller_pid, app_module, app_callable, scope, req_body_ch, resp_body_ch = args_tuple
    handle_asgi_sync(caller_pid, app_module, app_callable, scope,
                     req_body_ch, resp_body_ch)
