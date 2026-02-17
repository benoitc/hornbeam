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

"""WebSocket runner module for hornbeam.

This module handles ASGI WebSocket protocol communication between
Erlang and Python ASGI applications.

Adapted from gunicorn (MIT License).
https://github.com/benoitc/gunicorn
"""

import asyncio
import importlib
import sys
from collections import deque
from typing import Dict, Any, Optional, List


# Install uvloop as the default event loop policy (once per interpreter)
def _install_uvloop() -> bool:
    """Install uvloop as the default asyncio event loop policy."""
    try:
        import uvloop
        uvloop.install()
        return True
    except ImportError:
        return False


_install_uvloop()


# Active WebSocket sessions
# Each session stores the ASGI app instance and message queues
_sessions: Dict[str, 'WebSocketSession'] = {}


class WebSocketSession:
    """Manages a single WebSocket connection session.

    Each session maintains:
    - The ASGI scope
    - Message queues for send/receive
    - The running ASGI application task
    """

    def __init__(self, scope: dict, app_module: str, app_callable: str):
        self.scope = scope
        self.app_module = app_module
        self.app_callable = app_callable
        self.app = None
        self.task = None

        # Message queues
        self.receive_queue: asyncio.Queue = None
        self.send_queue: deque = deque()

        # Broadcast queue - messages to be published via Erlang pubsub
        self.broadcast_queue: deque = deque()

        # State
        self.accepted = False
        self.closed = False
        self.close_code: Optional[int] = None

        # Event loop for this session
        self.loop = None

    def load_app(self):
        """Load the ASGI application."""
        if self.app_module in sys.modules:
            del sys.modules[self.app_module]
        module = importlib.import_module(self.app_module)
        self.app = getattr(module, self.app_callable)

    async def receive(self) -> dict:
        """ASGI receive callable."""
        return await self.receive_queue.get()

    async def send(self, message: dict) -> None:
        """ASGI send callable."""
        msg_type = message.get('type', '')

        if msg_type == 'websocket.accept':
            self.accepted = True
            self.send_queue.append(message)

        elif msg_type == 'websocket.send':
            if not self.accepted:
                raise RuntimeError("Cannot send before accepting connection")
            self.send_queue.append(message)

        elif msg_type == 'websocket.close':
            self.closed = True
            self.close_code = message.get('code', 1000)
            self.send_queue.append(message)

        elif msg_type == 'websocket.http.response.start':
            # Denial response - reject with HTTP response
            self.send_queue.append(message)

        elif msg_type == 'websocket.http.response.body':
            # Denial response body
            self.send_queue.append(message)

    def collect_messages(self) -> List[dict]:
        """Collect all pending messages to send to Erlang."""
        messages = list(self.send_queue)
        self.send_queue.clear()
        # Include any broadcast requests
        for broadcast in self.broadcast_queue:
            messages.append({
                'type': 'hornbeam.broadcast',
                'topic': broadcast['topic'],
                'message': broadcast['message']
            })
        self.broadcast_queue.clear()
        return messages

    def add_broadcast(self, topic: str, message: Any) -> None:
        """Queue a broadcast to be sent via Erlang pubsub."""
        self.broadcast_queue.append({'topic': topic, 'message': message})


def _get_or_create_loop():
    """Get or create an event loop."""
    try:
        return asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.new_event_loop()


async def _run_app_until_response(session: WebSocketSession, event: dict) -> List[dict]:
    """Run the ASGI app until it produces a response."""
    # Import SuspensionRequired to avoid catching it
    try:
        from erlang import SuspensionRequired
    except ImportError:
        SuspensionRequired = None

    # Add event to receive queue
    await session.receive_queue.put(event)

    # If app task isn't running, start it
    if session.task is None or session.task.done():
        session.task = asyncio.create_task(
            session.app(session.scope, session.receive, session.send)
        )

    # Wait a short time for response
    try:
        # Give the app a chance to process the event
        await asyncio.sleep(0.001)

        # Wait for app to produce output or finish
        for _ in range(100):  # Max 100 iterations
            if session.send_queue:
                break
            if session.task.done():
                # Check if task raised an exception
                try:
                    session.task.result()
                except BaseException as e:
                    # Re-raise SuspensionRequired
                    if SuspensionRequired and isinstance(e, SuspensionRequired):
                        raise
                    return [{'type': 'websocket.close', 'code': 1011,
                            'reason': str(e)[:125]}]
                break
            await asyncio.sleep(0.001)

    except BaseException as e:
        # Re-raise SuspensionRequired
        if SuspensionRequired and isinstance(e, SuspensionRequired):
            raise
        return [{'type': 'websocket.close', 'code': 1011, 'reason': str(e)[:125]}]

    return session.collect_messages()


def start_session(app_module: str, app_callable: str,
                  scope: dict, session_id: str) -> dict:
    """Start a new WebSocket session.

    Called by Erlang when a WebSocket upgrade is detected.
    Returns the initial response (accept/close/deny).

    Args:
        app_module: Python module containing the ASGI app
        app_callable: Name of the ASGI callable
        scope: ASGI WebSocket scope
        session_id: Unique session identifier

    Returns:
        Initial response message (websocket.accept or websocket.close)
    """
    # Add session_id to scope so the app can access it for pubsub
    scope['session_id'] = session_id

    # Create session
    session = WebSocketSession(scope, app_module, app_callable)

    # Load the app
    session.load_app()

    # Create event loop for this session
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    session.loop = loop
    session.receive_queue = asyncio.Queue()

    # Store session
    _sessions[session_id] = session

    # Import SuspensionRequired to avoid catching it
    try:
        from erlang import SuspensionRequired
    except ImportError:
        SuspensionRequired = None

    # Send connect event and get response
    connect_event = {'type': 'websocket.connect'}

    try:
        responses = loop.run_until_complete(
            _run_app_until_response(session, connect_event)
        )
    except BaseException as e:
        # Re-raise SuspensionRequired
        if SuspensionRequired and isinstance(e, SuspensionRequired):
            raise
        # Clean up on error
        del _sessions[session_id]
        loop.close()
        return {'type': 'websocket.close', 'code': 1011, 'reason': str(e)[:125]}

    # Return first response (should be accept or close)
    if responses:
        return responses[0]
    else:
        # No response - default to close
        del _sessions[session_id]
        loop.close()
        return {'type': 'websocket.close', 'code': 1002,
                'reason': 'No response from application'}


def receive_message(app_module: str, app_callable: str,
                    session_id: str, msg_type: str, data: bytes) -> List[dict]:
    """Handle a received WebSocket message.

    Called by Erlang when a text or binary frame is received.

    Args:
        app_module: Python module (for reference)
        app_callable: ASGI callable name (for reference)
        session_id: Session identifier
        msg_type: 'text' or 'bytes'
        data: Message data

    Returns:
        List of response messages to send back
    """
    session = _sessions.get(session_id)
    if session is None:
        return [{'type': 'websocket.close', 'code': 1002,
                'reason': 'Session not found'}]

    # Build receive event
    if msg_type == 'text':
        if isinstance(data, bytes):
            data = data.decode('utf-8', errors='replace')
        event = {'type': 'websocket.receive', 'text': data}
    else:
        if isinstance(data, str):
            data = data.encode('utf-8')
        event = {'type': 'websocket.receive', 'bytes': data}

    # Import SuspensionRequired to avoid catching it
    try:
        from erlang import SuspensionRequired
    except ImportError:
        SuspensionRequired = None

    # Run app with this event
    try:
        asyncio.set_event_loop(session.loop)
        responses = session.loop.run_until_complete(
            _run_app_until_response(session, event)
        )
        return responses if responses else []
    except BaseException as e:
        # Re-raise SuspensionRequired
        if SuspensionRequired and isinstance(e, SuspensionRequired):
            raise
        return [{'type': 'websocket.close', 'code': 1011, 'reason': str(e)[:125]}]


def disconnect(app_module: str, app_callable: str,
               session_id: str, code: int) -> None:
    """Handle WebSocket disconnection.

    Called by Erlang when the WebSocket connection is closed.

    Args:
        app_module: Python module (for reference)
        app_callable: ASGI callable name (for reference)
        session_id: Session identifier
        code: Close code
    """
    session = _sessions.pop(session_id, None)
    if session is None:
        return

    # Send disconnect event to app
    disconnect_event = {'type': 'websocket.disconnect', 'code': code}

    try:
        asyncio.set_event_loop(session.loop)
        session.loop.run_until_complete(
            _run_app_until_response(session, disconnect_event)
        )
    except Exception:
        pass  # Ignore errors during disconnect
    finally:
        # Clean up
        if session.task and not session.task.done():
            session.task.cancel()
            try:
                session.loop.run_until_complete(session.task)
            except asyncio.CancelledError:
                pass
        session.loop.close()


def get_session_count() -> int:
    """Get the number of active WebSocket sessions."""
    return len(_sessions)


def get_session_ids() -> List[str]:
    """Get all active session IDs."""
    return list(_sessions.keys())


# =============================================================================
# Broadcast API - queue messages for Erlang to publish after py:call returns
# =============================================================================

def broadcast(session_id: str, topic: str, message: Any) -> bool:
    """Queue a message to be broadcast via Erlang pubsub.

    This function queues the message to be published after the current
    py:call returns to Erlang. This avoids nested Erlang calls.

    Args:
        session_id: The WebSocket session ID
        topic: Topic name to publish to
        message: Message to publish (will be JSON encoded and sent as text frame)

    Returns:
        True if queued successfully, False if session not found
    """
    session = _sessions.get(session_id)
    if session is None:
        return False
    session.add_broadcast(topic, message)
    return True
