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

"""Channels API for hornbeam.

This module provides a decorator-based API for building real-time
channel handlers.

Example usage:

    from hornbeam_channels import channel, broadcast

    room = channel("room:*")

    @room.on_join
    def join(topic, topic_params, params, socket):
        room_id = topic_params["room_id"]
        return ('ok', {"room": room_id}, socket.assign("room_id", room_id))

    @room.on("new_msg")
    def handle_msg(payload, socket):
        broadcast(socket.topic, "new_msg", payload)
        return ('noreply', socket)
"""

from typing import Any, Callable, Dict, Optional, Tuple, Union
from dataclasses import dataclass, field


# Registry of channel handlers
_channels: Dict[str, 'Channel'] = {}

# Pending broadcasts to be executed after handler returns
# This avoids the "callback pending" error when calling Erlang from inside a callback
_pending_broadcasts: list = []

# Pending presence operations to be executed after handler returns
_pending_presence_ops: list = []


def _queue_broadcast(broadcast_type: str, topic: str, event: str, payload: dict, sender_pid=None):
    """Queue a broadcast to be executed after the handler returns."""
    _pending_broadcasts.append({
        "type": broadcast_type,
        "topic": topic,
        "event": event,
        "payload": payload,
        "sender_pid": sender_pid
    })


def _get_pending_broadcasts() -> list:
    """Get and clear pending broadcasts."""
    global _pending_broadcasts
    broadcasts = _pending_broadcasts[:]
    _pending_broadcasts = []
    return broadcasts


def _queue_presence_op(op_type: str, topic: str, key: str, meta: dict = None):
    """Queue a presence operation to be executed after the handler returns."""
    _pending_presence_ops.append({
        "op": op_type,
        "topic": topic,
        "key": key,
        "meta": meta
    })


def _get_pending_presence_ops() -> list:
    """Get and clear pending presence operations."""
    global _pending_presence_ops
    ops = _pending_presence_ops[:]
    _pending_presence_ops = []
    return ops


@dataclass
class Socket:
    """Represents a channel socket connection.

    The socket holds connection state and allows assigning arbitrary
    key-value pairs that persist across handler calls.
    """
    channel_pid: Any = None
    session_id: str = ""
    topic: str = ""
    join_ref: str = ""
    assigns: Dict[str, Any] = field(default_factory=dict)

    def assign(self, key: str, value: Any) -> 'Socket':
        """Assign a value to the socket, returning a new socket."""
        new_assigns = dict(self.assigns)
        new_assigns[key] = value
        return Socket(
            channel_pid=self.channel_pid,
            session_id=self.session_id,
            topic=self.topic,
            join_ref=self.join_ref,
            assigns=new_assigns
        )

    def merge_assigns(self, assigns: Dict[str, Any]) -> 'Socket':
        """Merge assigns into the socket, returning a new socket."""
        new_assigns = dict(self.assigns)
        new_assigns.update(assigns)
        return Socket(
            channel_pid=self.channel_pid,
            session_id=self.session_id,
            topic=self.topic,
            join_ref=self.join_ref,
            assigns=new_assigns
        )

    def to_dict(self) -> Dict[str, Any]:
        """Convert socket to a dictionary for Erlang."""
        return {
            "channel_pid": self.channel_pid,
            "session_id": self.session_id,
            "topic": self.topic,
            "join_ref": self.join_ref,
            "assigns": self.assigns
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'Socket':
        """Create a socket from a dictionary (from Erlang)."""
        return cls(
            channel_pid=data.get("channel_pid"),
            session_id=data.get("session_id", ""),
            topic=data.get("topic", ""),
            join_ref=data.get("join_ref", ""),
            assigns=data.get("assigns", {})
        )


class Channel:
    """A channel definition with topic pattern and event handlers.

    Channels are defined with a topic pattern that may include wildcards:
    - "room:lobby" - exact match
    - "room:*" - wildcard matching any segment
    - "chat:*:*" - multiple wildcards
    """

    def __init__(self, pattern: str):
        self.pattern = pattern
        self._join_handler: Optional[Callable] = None
        self._leave_handler: Optional[Callable] = None
        self._event_handlers: Dict[str, Callable] = {}

        # Register this channel in Python
        _channels[pattern] = self

        # Register with Erlang channel registry
        self._register_with_erlang()

    def _register_with_erlang(self):
        """Register this channel pattern with Erlang channel registry."""
        try:
            import erlang
            handler_info = {
                "module": self.pattern,  # Use pattern as identifier
                "type": "python"
            }
            erlang.call('hornbeam_channel_registry', 'register',
                        self.pattern, handler_info)
        except ImportError:
            # Not running under Erlang, skip registration
            pass
        except Exception as e:
            # Log but don't fail - might not be running yet
            print(f"Warning: Could not register channel {self.pattern}: {e}")

    def on_join(self, func: Callable) -> Callable:
        """Decorator for the join handler.

        The handler receives:
        - topic: The specific topic being joined (e.g., "room:123")
        - topic_params: Extracted params from wildcards (e.g., {"room_id": "123"})
        - params: Client-provided join parameters
        - socket: The Socket object

        Returns:
        - ('ok', response, socket) - Successful join with response data
        - ('error', reason) - Rejected join with error reason
        """
        self._join_handler = func
        return func

    def on_leave(self, func: Callable) -> Callable:
        """Decorator for the leave handler.

        The handler receives:
        - topic: The topic being left
        - socket: The Socket object

        No return value is expected.
        """
        self._leave_handler = func
        return func

    def on(self, event: str) -> Callable:
        """Decorator for event handlers.

        The handler receives:
        - payload: The event payload
        - socket: The Socket object

        Returns:
        - ('reply', response, socket) - Reply to the client
        - ('noreply', socket) - No reply needed
        - ('stop', reason, socket) - Stop the channel
        """
        def decorator(func: Callable) -> Callable:
            self._event_handlers[event] = func
            return func
        return decorator

    def handle_join(self, topic: str, topic_params: Dict[str, str],
                    params: Dict[str, Any], socket: Socket) -> Tuple:
        """Handle a join request."""
        if self._join_handler is None:
            return ('ok', {}, socket)

        try:
            result = self._join_handler(topic, topic_params, params, socket)
            return _normalize_join_result(result, socket)
        except Exception as e:
            # Re-raise SuspensionRequired so the C executor can handle
            # Erlang callbacks (e.g. state_get/state_set from handlers)
            try:
                from erlang import SuspensionRequired
                if isinstance(e, SuspensionRequired):
                    raise
            except ImportError:
                pass
            return ('error', {"reason": str(e)})

    def handle_leave(self, topic: str, socket: Socket) -> None:
        """Handle a leave request."""
        if self._leave_handler is not None:
            try:
                self._leave_handler(topic, socket)
            except Exception as e:
                # Re-raise SuspensionRequired so the C executor can handle
                # Erlang callbacks (e.g. state_get/state_set from handlers)
                try:
                    from erlang import SuspensionRequired
                    if isinstance(e, SuspensionRequired):
                        raise
                except ImportError:
                    pass

    def handle_event(self, event: str, payload: Dict[str, Any],
                     socket: Socket) -> Tuple:
        """Handle an event."""
        handler = self._event_handlers.get(event)
        if handler is None:
            return ('noreply', socket)

        try:
            result = handler(payload, socket)
            return _normalize_event_result(result, socket)
        except Exception as e:
            # Re-raise SuspensionRequired so the C executor can handle
            # Erlang callbacks (e.g. state_get/state_set from handlers)
            try:
                from erlang import SuspensionRequired
                if isinstance(e, SuspensionRequired):
                    raise
            except ImportError:
                pass
            return ('stop', str(e), socket)


def _normalize_join_result(result: Any, socket: Socket) -> Tuple:
    """Normalize join handler result to standard format."""
    if isinstance(result, tuple):
        if len(result) == 2:
            status, data = result
            if status == 'ok':
                return ('ok', data, socket)
            elif status == 'error':
                return ('error', data)
        elif len(result) == 3:
            status, data, new_socket = result
            if status == 'ok':
                if isinstance(new_socket, Socket):
                    return ('ok', data, new_socket)
                return ('ok', data, socket)
            elif status == 'error':
                return ('error', data)
    return ('ok', {}, socket)


def _normalize_event_result(result: Any, socket: Socket) -> Tuple:
    """Normalize event handler result to standard format."""
    if isinstance(result, tuple):
        if len(result) == 2:
            status, data = result
            if status == 'reply':
                return ('reply', data, socket)
            elif status == 'noreply':
                if isinstance(data, Socket):
                    return ('noreply', data)
                return ('noreply', socket)
            elif status == 'stop':
                return ('stop', data, socket)
        elif len(result) == 3:
            status, data, new_socket = result
            if status == 'reply':
                if isinstance(new_socket, Socket):
                    return ('reply', data, new_socket)
                return ('reply', data, socket)
            elif status == 'noreply':
                if isinstance(data, Socket):
                    return ('noreply', data)
                return ('noreply', socket)
            elif status == 'stop':
                if isinstance(new_socket, Socket):
                    return ('stop', data, new_socket)
                return ('stop', data, socket)
    return ('noreply', socket)


def channel(pattern: str) -> Channel:
    """Create a new channel with the given topic pattern.

    Args:
        pattern: Topic pattern, may include wildcards (*)
                 e.g., "room:*", "chat:*:messages"

    Returns:
        A Channel instance that can be used with decorators
    """
    return Channel(pattern)


def get_channel(pattern: str) -> Optional[Channel]:
    """Get a channel by its pattern."""
    return _channels.get(pattern)


def list_channels() -> Dict[str, Channel]:
    """Get all registered channels."""
    return dict(_channels)


# =============================================================================
# Broadcasting API
# =============================================================================


def broadcast(topic: str, event: str, payload: Dict[str, Any]) -> None:
    """Broadcast a message to all subscribers of a topic.

    Args:
        topic: The topic to broadcast to (e.g., "room:lobby")
        event: The event name (e.g., "new_msg")
        payload: The message payload
    """
    # Queue the broadcast to be executed by Erlang after the handler returns
    # This avoids "callback pending" errors from erlport re-entrancy
    _queue_broadcast("broadcast", topic, event, payload)


def broadcast_from(socket: Socket, event: str, payload: Dict[str, Any]) -> None:
    """Broadcast a message to all subscribers except the sender.

    Args:
        socket: The sender's socket (will be excluded from broadcast)
        event: The event name
        payload: The message payload
    """
    # Queue the broadcast to be executed by Erlang after the handler returns
    # The socket.topic is used since Erlang will use self() as the sender PID
    _queue_broadcast("broadcast_from", socket.topic, event, payload)


def push(socket: Socket, event: str, payload: Dict[str, Any]) -> None:
    """Push a message to a specific client.

    Args:
        socket: The target socket
        event: The event name
        payload: The message payload
    """
    try:
        import erlang
        erlang.call('hornbeam_channel', 'push',
                    socket.channel_pid, socket.topic, event, payload)
    except Exception:
        pass


# =============================================================================
# Channel Registration (called from Erlang during app startup)
# =============================================================================


def register_channel(pattern: str, module: str) -> bool:
    """Register a channel pattern with its Python module.

    This is called from Erlang to register channel handlers.

    Args:
        pattern: Topic pattern (e.g., "room:*")
        module: Python module path containing the channel definition

    Returns:
        True if registration successful
    """
    try:
        import importlib

        # Import the module to execute the channel() and decorator calls
        if module in __import__('sys').modules:
            del __import__('sys').modules[module]
        importlib.import_module(module)

        # Check if the pattern was registered
        return pattern in _channels
    except Exception as e:
        print(f"Failed to register channel {pattern}: {e}")
        return False


def get_handler_info(pattern: str) -> Optional[Dict[str, Any]]:
    """Get handler info for a pattern (for Erlang to store in registry)."""
    channel = _channels.get(pattern)
    if channel is None:
        return None
    return {
        "module": pattern,  # Use pattern as module identifier
        "type": "python"
    }
