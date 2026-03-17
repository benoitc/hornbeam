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
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False
    erlang = None


# ============================================================================
# App loading and preloading
# ============================================================================

# Cached app reference - set by preload_app() for fast access
_preloaded_app: Callable = None
_preloaded_key: Tuple[str, str] = None


def preload_app(app_module: bytes, app_callable: bytes) -> bytes:
    """Preload ASGI application at startup for zero-overhead access."""
    global _preloaded_app, _preloaded_key

    module_name = app_module.decode('utf-8') if isinstance(app_module, bytes) else app_module
    callable_name = app_callable.decode('utf-8') if isinstance(app_callable, bytes) else app_callable

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
                      scope: dict, buffer):
    """Handle an ASGI request asynchronously.

    This is the main entry point called from Erlang via erlang.run().
    Uses erlang.send() to stream response directly to caller.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict
        buffer: py_buffer for request body, or 'empty' atom for bodyless requests
    """
    if not HAS_ERLANG:
        return

    # Convert bytes to strings
    module_name = _to_str(app_module)
    callable_name = _to_str(app_callable)

    # Determine buffer for receive (None for bodyless requests)
    if buffer == b'empty' or (hasattr(buffer, '__class__') and buffer.__class__.__name__ == 'Atom'):
        actual_buffer = None
    else:
        actual_buffer = buffer

    try:
        # Get app (preloaded or import on demand)
        app = _get_app(module_name, callable_name)

        # Create receive/send callables
        receive = _ASGIReceive(actual_buffer)
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
    """ASGI receive callable with async buffer support."""
    __slots__ = ('buffer', 'body_sent', 'disconnected', '_cached_body')

    def __init__(self, buffer):
        self.buffer = buffer  # py_buffer or None for empty
        self.body_sent = False
        self.disconnected = False
        self._cached_body = None

    async def __call__(self) -> dict:
        if self.disconnected:
            return _DISCONNECT_MSG

        if not self.body_sent:
            self.body_sent = True
            body = await self._read_body()
            return {'type': 'http.request', 'body': body, 'more_body': False}

        return _DISCONNECT_MSG

    async def _read_body(self) -> bytes:
        """Read body from buffer using async non-blocking reads."""
        if self._cached_body is not None:
            return self._cached_body

        if self.buffer is None:
            self._cached_body = b''
            return b''

        # Use non-blocking reads with asyncio yield
        chunks = []
        while True:
            # Check if data available
            if hasattr(self.buffer, 'readable_amount'):
                available = self.buffer.readable_amount()
                if available > 0:
                    chunk = self.buffer.read_nonblock(available)
                    if chunk:
                        chunks.append(chunk)
                elif hasattr(self.buffer, 'at_eof') and self.buffer.at_eof():
                    break
                else:
                    # Yield to event loop while waiting for data
                    await asyncio.sleep(0)
            else:
                # Fallback: blocking read (buffer already complete)
                chunk = self.buffer.read() if hasattr(self.buffer, 'read') else b''
                if chunk:
                    chunks.append(chunk)
                break

        self._cached_body = b''.join(chunks)
        return self._cached_body


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
# Synchronous wrapper for context_call
# ============================================================================

def handle_asgi_sync(caller_pid, app_module: bytes, app_callable: bytes,
                     scope: dict, buffer):
    """Synchronous wrapper that runs handle_asgi with erlang.run().

    This is used when calling from py_nif:context_call() which expects
    a synchronous function. Uses erlang.run() for proper Erlang event
    loop integration.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app (bytes)
        app_callable: Name of ASGI callable in module (bytes)
        scope: ASGI scope dict
        buffer: py_buffer for request body, or 'empty' atom for bodyless requests
    """
    if not HAS_ERLANG:
        return b'error'

    try:
        # Use erlang.run() for proper Erlang event loop integration
        erlang.run(handle_asgi(caller_pid, app_module, app_callable, scope, buffer))
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


def handle_request_direct(args_tuple) -> None:
    """Legacy entry point - uses sync wrapper."""
    if not HAS_ERLANG:
        return

    caller_pid, app_module, app_callable, scope, buffer = args_tuple
    handle_asgi_sync(caller_pid, app_module, app_callable, scope, buffer)
