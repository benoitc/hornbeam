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

Simple design:
- Request body: read from Erlang channel in receive()
- Response: send via erlang.send() directly to Cowboy handler
- No buffering, no extra tasks
"""

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
    """ASGI handler using Erlang channels for request body.

    Simple design: read from channel directly in receive(), no buffering.
    """

    def __init__(self, caller_pid, app: Callable, scope: dict,
                 req_channel: Optional[ByteChannel]):
        self._caller_pid = caller_pid
        self._app = app
        self._scope = scope
        self._req_channel = req_channel  # None for no-body requests
        self._send_fn = _erlang_send

        # Response state
        self._response_started = False
        self._response_finished = False

    # =========================================================================
    # ASGI interface
    # =========================================================================

    async def receive(self) -> dict:
        """ASGI receive callable - reads directly from channel."""
        # No body case
        if self._req_channel is None:
            return {'type': 'http.request', 'body': b'', 'more_body': False}

        # Read from channel
        try:
            chunk = await self._req_channel.async_receive_bytes()
            return {
                'type': 'http.request',
                'body': chunk if chunk else b'',
                'more_body': True,
            }
        except ByteChannelClosed:
            return {'type': 'http.request', 'body': b'', 'more_body': False}

    async def send(self, message: dict) -> None:
        """ASGI send callable.

        Uses erlang.send() directly for all response data - no channel overhead.
        """
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

            # Send body directly via erlang.send - no channel overhead
            self._send_fn(self._caller_pid, (b'body', body, more_body))

            if not more_body:
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
                    self._send_fn(self._caller_pid, (b'headers', 500, []))
                self._send_fn(self._caller_pid, (b'body', b'', False))

        except Exception as e:
            self._send_fn(self._caller_pid, (b'error', str(e).encode('utf-8')))


# =============================================================================
# Entry point
# =============================================================================

async def handle_asgi_loop(caller_pid, app_module: str, app_callable: str,
                           scope: dict, req_body_ch):
    """Handle ASGI request using Protocol pattern.

    Entry point called from hornbeam_asgi_loop.erl.
    Response is sent directly via erlang.send() - no channel needed.
    """
    if not HAS_ERLANG:
        return

    # Wrap request channel (may be 'empty' atom for no-body requests)
    if req_body_ch == 'empty' or req_body_ch == b'empty':
        req_channel = None
    else:
        req_channel = ByteChannel(req_body_ch)

    # Get app
    app = _get_app(app_module, app_callable)

    # Wrap scope['state'] if present
    if 'state' in scope:
        mount_id = scope.get('mount_id')
        scope['state'] = _MutableStateProxy(scope['state'], mount_id)

    # Create and run protocol
    protocol = ASGIProtocol(caller_pid, app, scope, req_channel)
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
