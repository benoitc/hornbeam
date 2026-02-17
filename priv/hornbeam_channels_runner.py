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

"""Channel handler runner for hornbeam.

This module bridges Erlang channel calls to Python channel handlers.
It is called by hornbeam_channel_registry.erl via py:call.
"""

from typing import Any, Dict, List, Tuple, Optional
import importlib
import sys


def handle_call(module: str, function: str, args: List[Any]) -> Any:
    """Handle a call from Erlang to a Python channel handler.

    Args:
        module: The channel pattern (used as module identifier)
        function: The function to call ('join', 'leave', 'event')
        args: Arguments to pass to the handler

    Returns:
        Result of the handler call
    """
    from hornbeam_channels import get_channel, Socket

    # Get the channel for this pattern
    channel = get_channel(module)
    if channel is None:
        return {'error': {'reason': f'Channel not found: {module}'}}

    if function == 'join':
        return _handle_join(channel, args)
    elif function == 'leave':
        return _handle_leave(channel, args)
    elif function == 'event':
        return _handle_event(channel, args)
    else:
        return {'error': {'reason': f'Unknown function: {function}'}}


def _handle_join(channel, args: List[Any]) -> Any:
    """Handle a join request.

    Args: [topic, topic_params, params, socket_data]

    Returns a tuple with optional presence operations:
        ('ok', response, socket, presence_ops) or
        ('error', reason)
    """
    from hornbeam_channels import Socket, _get_pending_presence_ops

    if len(args) < 4:
        return ('error', {'reason': 'Invalid join arguments'})

    topic = args[0]
    topic_params = _convert_params(args[1])
    params = _convert_params(args[2])
    socket = _socket_from_erlang(args[3])

    result = channel.handle_join(topic, topic_params, params, socket)

    # Get any pending presence operations queued during handler execution
    presence_ops = _get_pending_presence_ops()

    if result[0] == 'ok':
        # ('ok', response, socket, presence_ops)
        response = result[1]
        new_socket = result[2] if len(result) > 2 else socket
        return ('ok', response, _socket_to_erlang(new_socket), presence_ops)
    else:
        # ('error', reason)
        return ('error', result[1])


def _handle_leave(channel, args: List[Any]) -> Any:
    """Handle a leave request.

    Args: [topic, socket_data]
    """
    from hornbeam_channels import Socket

    if len(args) < 2:
        return None

    topic = args[0]
    socket = _socket_from_erlang(args[1])

    channel.handle_leave(topic, socket)
    return None


def _handle_event(channel, args: List[Any]) -> Any:
    """Handle an event.

    Args: [event, payload, socket_data]

    Returns a tuple with optional broadcasts list:
        ('reply', response, socket, broadcasts) or
        ('noreply', socket, broadcasts) or
        ('stop', reason, socket, broadcasts)
    """
    from hornbeam_channels import Socket, _get_pending_broadcasts

    if len(args) < 3:
        return ('noreply', {}, [])

    event = args[0]
    payload = _convert_params(args[1])
    socket = _socket_from_erlang(args[2])

    result = channel.handle_event(event, payload, socket)

    # Get any pending broadcasts queued during handler execution
    broadcasts = _get_pending_broadcasts()

    if result[0] == 'reply':
        # ('reply', response, socket, broadcasts)
        response = result[1]
        new_socket = result[2] if len(result) > 2 else socket
        return ('reply', response, _socket_to_erlang(new_socket), broadcasts)
    elif result[0] == 'stop':
        # ('stop', reason, socket, broadcasts)
        reason = result[1]
        new_socket = result[2] if len(result) > 2 else socket
        return ('stop', reason, _socket_to_erlang(new_socket), broadcasts)
    else:
        # ('noreply', socket, broadcasts)
        new_socket = result[1] if len(result) > 1 else socket
        if isinstance(new_socket, Socket):
            return ('noreply', _socket_to_erlang(new_socket), broadcasts)
        return ('noreply', {}, broadcasts)


def _socket_from_erlang(data: Any) -> 'Socket':
    """Convert Erlang socket data to a Python Socket object."""
    from hornbeam_channels import Socket

    if isinstance(data, dict):
        # Handle both string and binary keys
        assigns = data.get('assigns', data.get(b'assigns', {}))
        if isinstance(assigns, dict):
            # Convert binary keys to strings
            assigns = {
                (k.decode() if isinstance(k, bytes) else k): v
                for k, v in assigns.items()
            }
        channel_pid = data.get('channel_pid', data.get(b'channel_pid'))
        return Socket(
            channel_pid=channel_pid,
            session_id=_to_str(data.get('session_id', data.get(b'session_id', ''))),
            topic=_to_str(data.get('topic', data.get(b'topic', ''))),
            join_ref=_to_str(data.get('join_ref', data.get(b'join_ref', ''))),
            assigns=assigns
        )
    return Socket()


def _socket_to_erlang(socket: 'Socket') -> Dict[str, Any]:
    """Convert a Python Socket to Erlang format."""
    return {
        'channel_pid': socket.channel_pid,
        'session_id': socket.session_id,
        'topic': socket.topic,
        'join_ref': socket.join_ref,
        'assigns': socket.assigns
    }


def _convert_params(params: Any) -> Dict[str, Any]:
    """Convert params from Erlang format to Python dict."""
    if not isinstance(params, dict):
        return {}

    result = {}
    for k, v in params.items():
        key = _to_str(k)
        if isinstance(v, bytes):
            result[key] = v.decode('utf-8', errors='replace')
        elif isinstance(v, dict):
            result[key] = _convert_params(v)
        else:
            result[key] = v
    return result


def _to_str(value: Any) -> str:
    """Convert a value to string."""
    if isinstance(value, bytes):
        return value.decode('utf-8', errors='replace')
    if value is None:
        return ''
    return str(value)


# =============================================================================
# Channel Registration
# =============================================================================


def register_channels(module_path: str) -> List[Dict[str, Any]]:
    """Load a Python module and return registered channel patterns.

    This is called during application startup to discover channel handlers.

    Args:
        module_path: Python module path to load

    Returns:
        List of channel info dicts: [{"pattern": "room:*", "module": "...", "type": "python"}]
    """
    from hornbeam_channels import list_channels

    # Clear and reimport
    if module_path in sys.modules:
        del sys.modules[module_path]

    try:
        importlib.import_module(module_path)
    except ImportError as e:
        print(f"Failed to import channel module {module_path}: {e}")
        return []

    # Get all registered channels
    channels = list_channels()
    return [
        {
            "pattern": pattern,
            "module": pattern,  # Use pattern as identifier
            "type": "python"
        }
        for pattern in channels.keys()
    ]


def get_registered_patterns() -> List[str]:
    """Get all registered channel patterns."""
    from hornbeam_channels import list_channels
    return list(list_channels().keys())


_app_loaded = False

def _ensure_app_loaded():
    """Ensure the ASGI app module is loaded so channels are registered."""
    global _app_loaded
    if _app_loaded:
        return

    try:
        # Try to import the app module - this triggers channel registration
        import app
        _app_loaded = True
    except ImportError:
        pass


def find_handler_for_topic(topic: str) -> Optional[Dict[str, Any]]:
    """Find a Python channel handler that matches this topic.

    Called by Erlang when no handler is registered for a topic.
    This allows lazy registration of Python handlers.

    Args:
        topic: The topic to find a handler for (e.g., "room:lobby")

    Returns:
        Handler info dict or None if not found
    """
    # Import the app module to ensure channels are registered
    _ensure_app_loaded()

    from hornbeam_channels import list_channels

    # Convert topic to string if bytes
    if isinstance(topic, bytes):
        topic = topic.decode('utf-8')

    topic_parts = topic.split(':')

    # Check each registered channel pattern
    for pattern, channel in list_channels().items():
        pattern_parts = pattern.split(':')

        if _matches_pattern(pattern_parts, topic_parts):
            return {
                "pattern": pattern,
                "module": pattern,  # Use pattern as module identifier
                "type": "python"
            }

    return None


def _matches_pattern(pattern_parts: List[str], topic_parts: List[str]) -> bool:
    """Check if a topic matches a pattern with wildcards."""
    if len(pattern_parts) != len(topic_parts):
        return False

    for pattern_part, topic_part in zip(pattern_parts, topic_parts):
        if pattern_part == '*':
            continue  # Wildcard matches anything
        if pattern_part != topic_part:
            return False

    return True
