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

"""ASGI handler using asyncio.Protocol-style push/pull pattern.

This module implements ASGI request handling using a Protocol pattern:

- ASGIProtocol handles the request lifecycle
- Data flows via callbacks (data_received, eof_received)
- Buffer + Event pattern for ASGI receive()
- Clean separation of concerns

The protocol mirrors asyncio.Protocol's interface but adapts it for
Erlang channel communication.
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


class ASGIProtocol:
    """Protocol-style ASGI handler.

    Mirrors asyncio.Protocol interface but adapted for Erlang channels.
    Handles the full request/response lifecycle.
    """

    def __init__(self, caller_pid, app: Callable, scope: dict,
                 req_channel: ByteChannel, resp_channel: ByteChannel):
        self._caller_pid = caller_pid
        self._app = app
        self._scope = scope
        self._req_channel = req_channel
        self._resp_channel = resp_channel
        self._send_fn = _erlang_send

        # Body state (like asyncio.Protocol)
        self._buffer = bytearray()
        self._body_event = asyncio.Event()
        self._eof_received = False
        self._disconnected = False

        # Response state
        self._response_started = False
        self._response_finished = False

        # Tasks
        self._reader_task: Optional[asyncio.Task] = None
        self._app_task: Optional[asyncio.Task] = None

    # =========================================================================
    # Protocol callbacks (asyncio.Protocol style)
    # =========================================================================

    def connection_made(self):
        """Called when channel is ready."""
        # Start the channel reader
        self._reader_task = asyncio.create_task(self._read_channel())

    def data_received(self, data: bytes):
        """Called when body data is received."""
        self._buffer.extend(data)
        self._body_event.set()

    def eof_received(self):
        """Called when body is complete (channel closed)."""
        self._eof_received = True
        self._body_event.set()

    def connection_lost(self, exc: Optional[Exception]):
        """Called when connection is lost."""
        self._disconnected = True
        self._eof_received = True
        self._body_event.set()
        if self._app_task and not self._app_task.done():
            self._app_task.cancel()

    # =========================================================================
    # Channel reader (bridges channel to Protocol callbacks)
    # =========================================================================

    async def _read_channel(self):
        """Read from channel and dispatch to Protocol callbacks."""
        try:
            while True:
                try:
                    chunk = await self._req_channel.async_receive_bytes()
                    if chunk:
                        self.data_received(chunk)
                except ByteChannelClosed:
                    self.eof_received()
                    break
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            self.connection_lost(exc)

    # =========================================================================
    # ASGI interface
    # =========================================================================

    async def receive(self) -> dict:
        """ASGI receive callable."""
        if self._disconnected:
            return {'type': 'http.disconnect'}

        # Return buffered data if available
        if self._buffer:
            body = bytes(self._buffer)
            self._buffer.clear()
            return {
                'type': 'http.request',
                'body': body,
                'more_body': not self._eof_received,
            }

        # EOF with no data
        if self._eof_received:
            return {
                'type': 'http.request',
                'body': b'',
                'more_body': False,
            }

        # Wait for data
        await self._body_event.wait()
        self._body_event.clear()

        if self._disconnected:
            return {'type': 'http.disconnect'}

        # Return buffered data
        body = bytes(self._buffer)
        self._buffer.clear()

        return {
            'type': 'http.request',
            'body': body,
            'more_body': not self._eof_received,
        }

    async def send(self, message: dict) -> None:
        """ASGI send callable."""
        if self._response_finished:
            raise RuntimeError("Response already completed")

        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            if self._response_started:
                raise RuntimeError("http.response.start already sent")

            status = message.get('status', 200)
            headers = message.get('headers', [])
            self._send_fn(self._caller_pid, (b'headers', status, headers))
            self._response_started = True

        elif msg_type == 'http.response.body':
            if not self._response_started:
                raise RuntimeError("http.response.start must be sent first")

            body = message.get('body', b'')
            if isinstance(body, str):
                body = body.encode('utf-8')

            more_body = message.get('more_body', False)

            try:
                if body:
                    self._resp_channel.send_bytes(body)
            except ByteChannelClosed:
                self._response_finished = True
                raise OSError("Client disconnected")

            if not more_body:
                self._resp_channel.close()
                self._response_finished = True

        elif msg_type == 'http.response.informational':
            status = message.get('status', 100)
            headers = message.get('headers', [])
            if status == 103:
                self._send_fn(self._caller_pid, (b'early_hints', headers))

        elif msg_type == 'http.disconnect':
            self._resp_channel.close()
            self._response_finished = True

    # =========================================================================
    # Lifecycle
    # =========================================================================

    async def run(self):
        """Run the ASGI application."""
        self.connection_made()

        try:
            await self._app(self._scope, self.receive, self.send)

            # Ensure response is completed
            if not self._response_finished:
                if not self._response_started:
                    self._send_fn(self._caller_pid, (b'headers', 500, []))
                try:
                    self._resp_channel.close()
                except ByteChannelClosed:
                    pass

        except Exception as e:
            try:
                self._resp_channel.close()
                self._send_fn(self._caller_pid, (b'error', str(e).encode('utf-8')))
            except Exception:
                pass

        finally:
            # Cleanup
            if self._reader_task and not self._reader_task.done():
                self._reader_task.cancel()
                try:
                    await self._reader_task
                except asyncio.CancelledError:
                    pass


# =============================================================================
# Entry point
# =============================================================================

async def handle_asgi_loop(caller_pid, app_module: str, app_callable: str,
                           scope: dict, req_body_ch, resp_body_ch):
    """Handle ASGI request using Protocol pattern.

    Entry point called from hornbeam_asgi_loop.erl.
    """
    if not HAS_ERLANG:
        return

    # Wrap channels
    req_channel = ByteChannel(req_body_ch)
    resp_channel = ByteChannel(resp_body_ch)

    # Get app
    app = _get_app(app_module, app_callable)

    # Wrap scope['state'] if present
    if 'state' in scope:
        mount_id = scope.get('mount_id')
        scope['state'] = _MutableStateProxy(scope['state'], mount_id)

    # Create and run protocol
    protocol = ASGIProtocol(caller_pid, app, scope, req_channel, resp_channel)
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
