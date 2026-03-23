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

"""ASGI handler using Cowboy loop handler with direct message passing.

Design inspired by gunicorn's ASGI worker:
- BodyReceiver: Handles request body with Future-based waiting
- ASGIProtocol: Manages request lifecycle and response batching
- Response sent via erlang.send() directly to Cowboy handler
"""

import asyncio
from typing import Callable, Optional

try:
    import erlang
    from erlang import ByteChannel, ByteChannelClosed
    HAS_ERLANG = True
    _erlang_send = erlang.send
except ImportError:
    HAS_ERLANG = False
    erlang = None
    _erlang_send = None
    ByteChannel = None
    ByteChannelClosed = Exception

# Pre-allocated message constants (avoid dict allocation per request)
_EMPTY_BODY_MSG = {'type': 'http.request', 'body': b'', 'more_body': False}
_DISCONNECT_MSG = {'type': 'http.disconnect'}


class BodyReceiver:
    """Body receiver with Future-based waiting (gunicorn pattern).

    Handles three body modes:
    - empty: No body expected
    - inline: Small body passed directly from Erlang
    - channel: Large/streaming body via ByteChannel

    Uses asyncio.Future for efficient async waiting without polling.
    """

    __slots__ = ('_mode', '_data', '_channel', '_complete', '_disconnected',
                 '_waiter', '_chunks')

    def __init__(self, body_ref):
        self._complete = False
        self._disconnected = False
        self._waiter = None
        self._chunks = []

        # Detect body mode from ref
        if body_ref == b'empty' or body_ref == 'empty':
            self._mode = 'empty'
            self._data = None
            self._channel = None
            self._complete = True
        elif isinstance(body_ref, tuple):
            tag = body_ref[0]
            if tag == b'body' or tag == 'body':
                self._mode = 'inline'
                data = body_ref[1]
                # Ensure bytes (Erlang binary may decode as str)
                if isinstance(data, str):
                    data = data.encode('latin-1')
                self._data = data
                self._channel = None
            elif tag == b'channel' or tag == 'channel':
                self._mode = 'channel'
                self._data = None
                self._channel = ByteChannel(body_ref[1])
            else:
                # Unknown tuple, treat as channel ref
                self._mode = 'channel'
                self._data = None
                self._channel = ByteChannel(body_ref)
        else:
            # Legacy: raw channel ref
            self._mode = 'channel'
            self._data = None
            self._channel = ByteChannel(body_ref)

    def signal_disconnect(self):
        """Signal client disconnection."""
        self._disconnected = True
        self._wake_waiter()

    def _wake_waiter(self):
        """Wake pending receive() call."""
        if self._waiter is not None and not self._waiter.done():
            self._waiter.set_result(None)

    async def receive(self) -> dict:
        """ASGI receive callable with fast paths."""
        # Already disconnected
        if self._disconnected:
            return _DISCONNECT_MSG

        # Fast path: empty body
        if self._mode == 'empty':
            return _EMPTY_BODY_MSG

        # Fast path: inline body (complete body passed directly)
        if self._mode == 'inline':
            self._mode = 'done'
            return {'type': 'http.request', 'body': self._data, 'more_body': False}

        # Body already consumed
        if self._mode == 'done' or self._complete:
            return _EMPTY_BODY_MSG

        # Fast path: chunks already buffered
        if self._chunks:
            return self._pop_chunk()

        # Channel mode: read from ByteChannel
        return await self._receive_from_channel()

    def _pop_chunk(self) -> dict:
        """Pop buffered chunk and return message."""
        chunk = self._chunks.pop(0)
        more = bool(self._chunks) or not self._complete
        if not more:
            self._mode = 'done'
        return {'type': 'http.request', 'body': chunk, 'more_body': more}

    async def _receive_from_channel(self) -> dict:
        """Read body chunk from ByteChannel."""
        try:
            chunk = await self._channel.async_receive_bytes()
            if chunk:
                return {'type': 'http.request', 'body': chunk, 'more_body': True}
            # Empty chunk but channel still open - wait for more
            return {'type': 'http.request', 'body': b'', 'more_body': True}
        except ByteChannelClosed:
            self._complete = True
            self._mode = 'done'
            return _EMPTY_BODY_MSG


class ASGIProtocol:
    """ASGI protocol handler with response batching (gunicorn-inspired).

    Optimizations:
    - Uses __slots__ to reduce memory and attribute access overhead
    - Delegates body handling to BodyReceiver class
    - Batches headers + body for simple responses (single message)
    - Structured response state tracking
    """

    __slots__ = ('_caller_pid', '_app', '_scope', '_body_receiver', '_send_fn',
                 '_status', '_headers', '_response_started', '_response_finished')

    def __init__(self, caller_pid, app: Callable, scope: dict, body_receiver: BodyReceiver):
        self._caller_pid = caller_pid
        self._app = app
        self._scope = scope
        self._body_receiver = body_receiver
        self._send_fn = _erlang_send

        # Response state (buffer headers for batching)
        self._status = None
        self._headers = None
        self._response_started = False
        self._response_finished = False

    async def receive(self) -> dict:
        """ASGI receive - delegates to BodyReceiver."""
        return await self._body_receiver.receive()

    async def send(self, message: dict) -> None:
        """ASGI send callable with simplified protocol.

        Uses 3 message types:
        - start_response: headers + first chunk
        - chunk: subsequent body chunks
        - fin: end of response
        """
        if self._response_finished:
            raise RuntimeError("Response already completed")

        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            if self._response_started:
                raise RuntimeError("http.response.start already sent")

            # Buffer headers for batching with first body
            self._status = message.get('status', 200)
            self._headers = message.get('headers', [])
            self._response_started = True

        elif msg_type == 'http.response.body':
            if not self._response_started:
                raise RuntimeError("http.response.start must be sent first")

            body = message.get('body', b'')
            if isinstance(body, str):
                body = body.encode('utf-8')

            more_body = message.get('more_body', False)

            if self._headers is not None:
                # First body - send start_response with headers + first chunk
                self._send_fn(self._caller_pid,
                             (b'start_response', self._status, self._headers, body))
                self._headers = None
            else:
                # Subsequent chunk
                if body:
                    self._send_fn(self._caller_pid, (b'chunk', body))

            if not more_body:
                # Send fin to terminate
                self._send_fn(self._caller_pid, b'fin')
                self._response_finished = True

        elif msg_type == 'http.response.informational':
            status = message.get('status', 100)
            headers = message.get('headers', [])
            if status == 103:
                self._send_fn(self._caller_pid, (b'early_hints', headers))

        elif msg_type == 'http.disconnect':
            self._response_finished = True

    async def run(self):
        """Run the ASGI application."""
        try:
            await self._app(self._scope, self.receive, self.send)

            # Ensure response is completed
            if not self._response_finished:
                if not self._response_started:
                    # No response started - send error response
                    self._send_fn(self._caller_pid,
                                 (b'start_response', 500, [], b''))
                    self._send_fn(self._caller_pid, b'fin')
                elif self._headers is not None:
                    # Headers buffered but no body sent - send empty response
                    self._send_fn(self._caller_pid,
                                 (b'start_response', self._status, self._headers, b''))
                    self._send_fn(self._caller_pid, b'fin')
                else:
                    # Streaming was started but not finished - send fin
                    self._send_fn(self._caller_pid, b'fin')

        except asyncio.CancelledError:
            # Client disconnected - signal to body receiver
            self._body_receiver.signal_disconnect()
            raise
        except Exception as e:
            self._send_fn(self._caller_pid, (b'error', str(e).encode('utf-8')))


# =============================================================================
# Entry point
# =============================================================================

async def handle_asgi(caller_pid, app_module: str, app_callable: str,
                      scope: dict, req_body_ref):
    """Handle ASGI request.

    Entry point called from hornbeam_asgi.erl.
    Response is sent directly via erlang.send().

    req_body_ref can be:
    - 'empty' or b'empty': no request body
    - (b'body', data): small body passed inline (< 64KB)
    - (b'channel', channel_ref): large/streaming body via channel
    """
    if not HAS_ERLANG:
        return

    # Get app
    app = _get_app(app_module, app_callable)

    # Wrap scope['state'] if present
    if 'state' in scope:
        mount_id = scope.get('mount_id')
        scope['state'] = _MutableStateProxy(scope['state'], mount_id)

    # Create body receiver (handles body mode detection)
    body_receiver = BodyReceiver(req_body_ref)

    # Create and run protocol
    protocol = ASGIProtocol(caller_pid, app, scope, body_receiver)
    await protocol.run()


# =============================================================================
# Helpers
# =============================================================================

_preloaded_app: Callable = None
_preloaded_key: tuple = None


def preload_app(app_module: str, app_callable: str) -> bytes:
    """Preload ASGI application at startup."""
    global _preloaded_app, _preloaded_key

    import importlib
    module = importlib.import_module(app_module)
    app = getattr(module, app_callable)

    _preloaded_app = app
    _preloaded_key = (app_module, app_callable)

    return b'ok'


def _get_app(module_name: str, callable_name: str) -> Callable:
    """Get ASGI application."""
    global _preloaded_app, _preloaded_key

    if _preloaded_key == (module_name, callable_name):
        return _preloaded_app

    import importlib
    module = importlib.import_module(module_name)
    return getattr(module, callable_name)


class _MutableStateProxy(dict):
    """Dict that syncs mutations to Erlang ETS."""

    __slots__ = ('_mount_id', '_lifespan_pid')

    def __init__(self, initial_state: dict, mount_id=None):
        super().__init__(initial_state)
        self._mount_id = mount_id
        self._lifespan_pid = None
        if HAS_ERLANG:
            try:
                self._lifespan_pid = erlang.whereis("hornbeam_lifespan")
            except Exception:
                pass

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if self._lifespan_pid is not None:
            try:
                if self._mount_id is not None:
                    _erlang_send(self._lifespan_pid,
                                (b'update_state', self._mount_id, key, value))
                else:
                    _erlang_send(self._lifespan_pid, (b'update_state', key, value))
            except Exception:
                pass
