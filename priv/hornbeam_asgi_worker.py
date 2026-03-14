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
import threading
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import erlang
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False
    erlang = None


# ============================================================================
# App loading
# ============================================================================

_app_cache: Dict[Tuple[str, str], Callable] = {}
_app_cache_lock = threading.Lock()


def _load_app(module_name: str, callable_name: str) -> Callable:
    """Load an ASGI application with thread-safe caching."""
    cache_key = (module_name, callable_name)

    if cache_key in _app_cache:
        return _app_cache[cache_key]

    with _app_cache_lock:
        if cache_key in _app_cache:
            return _app_cache[cache_key]

        if module_name not in sys.modules:
            module = importlib.import_module(module_name)
        else:
            module = sys.modules[module_name]

        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


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


def _to_str(val) -> str:
    """Convert bytes to string."""
    if isinstance(val, bytes):
        return val.decode('utf-8', errors='replace')
    if isinstance(val, str):
        return val
    return str(val) if val is not None else ''


# ============================================================================
# Pre-allocated messages
# ============================================================================

_DISCONNECT_MSG = {'type': 'http.disconnect'}


# ============================================================================
# Main entry point: handle_asgi (async)
# ============================================================================

async def handle_asgi(caller_pid, app_module: bytes, app_callable: bytes,
                      scope: dict, body: bytes):
    """Handle an ASGI request asynchronously.

    This is the main entry point called from Erlang via py_event_loop.
    Uses erlang.send() to stream response directly to caller.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict
        body: Request body bytes

    Note: This function MUST be called via py_event_loop:create_task()
    or erlang.run() for proper async execution.
    """
    if not HAS_ERLANG:
        return

    # Convert bytes to strings
    module_name = _to_str(app_module)
    callable_name = _to_str(app_callable)

    # Ensure body is bytes
    if isinstance(body, str):
        body = body.encode('utf-8')
    elif not isinstance(body, bytes):
        body = b''

    try:
        # Load app
        app = _load_app(module_name, callable_name)

        # Create receive/send callables
        receive = _ASGIReceive(body)
        send = _ASGISend(caller_pid)

        # Run ASGI app
        await app(scope, receive, send)

        # Ensure completion is signaled
        if not send.finished:
            if not send.headers_sent:
                erlang.send(caller_pid, (b'headers', 500, []))
            erlang.send(caller_pid, b'done')

    except Exception as e:
        try:
            erlang.send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass


class _ASGIReceive:
    """ASGI receive callable with streaming support."""
    __slots__ = ('body', 'body_sent', 'channel', 'disconnected')

    def __init__(self, body: bytes, channel=None):
        self.body = body
        self.body_sent = False
        self.channel = channel  # Optional channel for streaming body
        self.disconnected = False

    async def __call__(self) -> dict:
        if self.disconnected:
            return _DISCONNECT_MSG

        if not self.body_sent:
            self.body_sent = True

            # If we have a channel, read body from it
            if self.channel is not None:
                body, more_body = await self._read_from_channel()
                if not more_body:
                    self.body_sent = True
                return {'type': 'http.request', 'body': body, 'more_body': more_body}

            # Use pre-loaded body
            return {'type': 'http.request', 'body': self.body, 'more_body': False}

        return _DISCONNECT_MSG

    async def _read_from_channel(self) -> Tuple[bytes, bool]:
        """Read body chunk from channel (for streaming uploads)."""
        from erlang import Channel, ChannelClosed

        try:
            msg = self.channel.receive(timeout=30000)

            if msg == b'body_done' or msg == 'body_done':
                return b'', False

            if isinstance(msg, tuple) and len(msg) == 2:
                tag, chunk = msg
                if tag == b'body_chunk' or tag == 'body_chunk':
                    return _to_bytes(chunk), True

        except ChannelClosed:
            self.disconnected = True

        return b'', False


class _ASGISend:
    """ASGI send callable that streams to Erlang via erlang.send()."""
    __slots__ = ('caller_pid', 'status', 'headers', 'headers_sent',
                 'body_parts', 'finished', 'buffering')

    # Buffer small responses before sending
    BUFFER_THRESHOLD = 65536

    def __init__(self, caller_pid, buffering: bool = True):
        self.caller_pid = caller_pid
        self.status = None
        self.headers = []
        self.headers_sent = False
        self.body_parts = []
        self.finished = False
        self.buffering = buffering

    async def __call__(self, message: dict) -> None:
        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            self.status = message.get('status', 200)
            self.headers = message.get('headers', [])

            if not self.buffering:
                # Send headers immediately for streaming
                erlang.send(self.caller_pid, (b'headers', self.status, self.headers))
                self.headers_sent = True

        elif msg_type == 'http.response.body':
            body_part = message.get('body', b'')
            if isinstance(body_part, str):
                body_part = body_part.encode('utf-8')

            more_body = message.get('more_body', False)

            if self.buffering and not self.headers_sent:
                # Buffer body parts
                if body_part:
                    self.body_parts.append(body_part)

                total_size = sum(len(p) for p in self.body_parts)

                if not more_body:
                    # Done - send complete response
                    body = b''.join(self.body_parts)
                    erlang.send(self.caller_pid,
                               (b'response', self.status or 500, self.headers, body))
                    self.finished = True

                elif total_size >= self.BUFFER_THRESHOLD:
                    # Switch to streaming
                    erlang.send(self.caller_pid, (b'headers', self.status or 500, self.headers))
                    self.headers_sent = True
                    for part in self.body_parts:
                        erlang.send(self.caller_pid, (b'chunk', part))
                    self.body_parts.clear()
                    self.buffering = False

            else:
                # Streaming mode
                if not self.headers_sent:
                    erlang.send(self.caller_pid, (b'headers', self.status or 500, self.headers))
                    self.headers_sent = True

                if body_part:
                    erlang.send(self.caller_pid, (b'chunk', body_part))

                if not more_body:
                    erlang.send(self.caller_pid, b'done')
                    self.finished = True

        elif msg_type == 'http.response.informational':
            # Early hints (103)
            status = message.get('status', 100)
            headers = message.get('headers', [])
            if status == 103:
                erlang.send(self.caller_pid, (b'early_hints', headers))

        elif msg_type == 'http.disconnect':
            self.finished = True


# ============================================================================
# Streaming request body support
# ============================================================================

async def handle_asgi_streaming(caller_pid, app_module: bytes, app_callable: bytes,
                                scope: dict, channel_ref):
    """Handle an ASGI request with streaming request body.

    This variant reads the request body from a channel, enabling
    streaming uploads without buffering the entire body.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict
        channel_ref: Channel reference for receiving body chunks
    """
    if not HAS_ERLANG:
        return

    from erlang import Channel

    module_name = _to_str(app_module)
    callable_name = _to_str(app_callable)

    try:
        app = _load_app(module_name, callable_name)

        channel = Channel(channel_ref)
        receive = _ASGIReceive(b'', channel=channel)
        send = _ASGISend(caller_pid, buffering=False)  # Always stream response

        await app(scope, receive, send)

        if not send.finished:
            if not send.headers_sent:
                erlang.send(caller_pid, (b'headers', 500, []))
            erlang.send(caller_pid, b'done')

    except Exception as e:
        try:
            erlang.send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass


# ============================================================================
# Synchronous wrapper for context_call
# ============================================================================

def handle_asgi_sync(caller_pid, app_module: bytes, app_callable: bytes,
                     scope: dict, body: bytes):
    """Synchronous wrapper that runs handle_asgi with erlang.run().

    This is used when calling from py_nif:context_call() which expects
    a synchronous function. Uses erlang.run() to get proper event loop.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict
        body: Request body bytes
    """
    if not HAS_ERLANG:
        return b'error'

    try:
        # Use erlang.run() for proper Erlang event loop integration
        erlang.run(handle_asgi(caller_pid, app_module, app_callable, scope, body))
        return b'done'
    except Exception as e:
        try:
            erlang.send(caller_pid, (b'error', str(e).encode('utf-8')))
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

    module_name = _to_str(app_module)
    callable_name = _to_str(app_callable)

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
                    return {'type': 'websocket.receive', 'text': _to_str(msg[1])}

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
            erlang.send(caller_pid, (b'accept', subprotocol, headers))

        elif msg_type == 'websocket.send':
            if 'text' in message:
                erlang.send(caller_pid, (b'text', message['text']))
            elif 'bytes' in message:
                erlang.send(caller_pid, (b'bytes', message['bytes']))

        elif msg_type == 'websocket.close':
            code = message.get('code', 1000)
            reason = message.get('reason', '')
            erlang.send(caller_pid, (b'close', code, reason))
            closed = True

    try:
        app = _load_app(module_name, callable_name)
        await app(scope, receive, send)

        # Ensure close is sent
        if not closed:
            erlang.send(caller_pid, (b'close', 1000, b''))

    except Exception as e:
        try:
            erlang.send(caller_pid, (b'error', str(e).encode('utf-8')))
        except Exception:
            pass


# ============================================================================
# Legacy entry points (for backwards compatibility)
# ============================================================================

def handle_request_direct(args_tuple) -> None:
    """Legacy entry point - uses sync wrapper."""
    if not HAS_ERLANG:
        return

    channel_ref, caller_pid, app_module, app_callable, scope, body = args_tuple
    handle_asgi_sync(caller_pid, app_module, app_callable, scope, body)
