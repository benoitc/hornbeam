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

"""Presence API for hornbeam.

This module provides distributed presence tracking backed by an
ORSWOT CRDT on the Erlang side.

Example usage:

    from hornbeam_presence import Presence

    # Create a presence instance for a topic
    presence = Presence("room:lobby")

    # Track a user's presence
    presence.track(socket, f"user:{user_id}", {
        "name": username,
        "status": "online",
        "joined_at": time.time()
    })

    # List all presences
    users = presence.list()
    # Returns: {"user:123": {"metas": [{"name": "Alice", ...}]}}

    # Update presence metadata
    presence.update(socket, f"user:{user_id}", {
        "status": "away"
    })

    # Untrack when done
    presence.untrack(socket, f"user:{user_id}")
"""

from typing import Any, Dict, List, Optional


class Presence:
    """Distributed presence tracking for a topic.

    Each Presence instance is bound to a specific topic and provides
    methods to track, untrack, and list presences.

    The underlying ORSWOT CRDT ensures eventual consistency across
    all nodes in the cluster.
    """

    def __init__(self, topic: str):
        """Create a presence tracker for a topic.

        Args:
            topic: The topic to track presences for (e.g., "room:lobby")
        """
        self.topic = topic

    def track(self, socket: Any, key: str, meta: Dict[str, Any]) -> bool:
        """Track a presence for a key.

        Args:
            socket: The socket object (contains channel_pid for monitoring)
            key: Unique identifier for the presence (e.g., "user:123")
            meta: Metadata dict (e.g., {"name": "Alice", "status": "online"})

        Returns:
            True if tracked successfully (queued for execution)
        """
        # Queue the presence operation to be executed by Erlang after handler returns
        # This avoids "callback pending" errors from erlport re-entrancy
        try:
            from hornbeam_channels import _queue_presence_op
            _queue_presence_op("track", self.topic, key, meta)
            return True
        except ImportError:
            # Fallback to direct call if not in channel context
            try:
                import erlang
                if hasattr(socket, 'channel_pid'):
                    pid = socket.channel_pid
                elif isinstance(socket, dict):
                    pid = socket.get('channel_pid')
                else:
                    pid = socket
                result = erlang.call('hornbeam_presence', 'track',
                                     self.topic, pid, key, meta)
                return result == 'ok'
            except Exception as e:
                print(f"Presence track error: {e}")
                return False

    def untrack(self, socket: Any, key: str) -> bool:
        """Untrack a specific presence key.

        Args:
            socket: The socket object
            key: The key to untrack

        Returns:
            True if untracked successfully
        """
        try:
            import erlang

            if hasattr(socket, 'channel_pid'):
                pid = socket.channel_pid
            elif isinstance(socket, dict):
                pid = socket.get('channel_pid')
            else:
                pid = socket

            erlang.cast('hornbeam_presence', 'untrack',
                        self.topic, pid, key)
            return True
        except Exception as e:
            print(f"Presence untrack error: {e}")
            return False

    def untrack_all(self, socket: Any) -> bool:
        """Untrack all presences for a socket.

        Args:
            socket: The socket object

        Returns:
            True if untracked successfully
        """
        try:
            import erlang

            if hasattr(socket, 'channel_pid'):
                pid = socket.channel_pid
            elif isinstance(socket, dict):
                pid = socket.get('channel_pid')
            else:
                pid = socket

            erlang.cast('hornbeam_presence', 'untrack_all',
                        self.topic, pid)
            return True
        except Exception as e:
            print(f"Presence untrack_all error: {e}")
            return False

    def update(self, socket: Any, key: str, meta: Dict[str, Any]) -> bool:
        """Update presence metadata for a key.

        This is equivalent to untrack + track with new metadata.

        Args:
            socket: The socket object
            key: The presence key to update
            meta: New metadata dict

        Returns:
            True if updated successfully
        """
        try:
            import erlang

            if hasattr(socket, 'channel_pid'):
                pid = socket.channel_pid
            elif isinstance(socket, dict):
                pid = socket.get('channel_pid')
            else:
                pid = socket

            result = erlang.call('hornbeam_presence', 'update',
                                 self.topic, pid, key, meta)
            return result == 'ok'
        except Exception as e:
            print(f"Presence update error: {e}")
            return False

    def list(self) -> Dict[str, Dict[str, Any]]:
        """List all presences for the topic.

        Returns:
            Dict mapping keys to presence info:
            {
                "user:123": {"metas": [{"name": "Alice", ...}]},
                "user:456": {"metas": [{"name": "Bob", ...}]}
            }
        """
        try:
            import erlang
            result = erlang.call('hornbeam_presence', 'list', self.topic)
            return _convert_presence_list(result)
        except Exception as e:
            print(f"Presence list error: {e}")
            return {}

    def get(self, key: str) -> Optional[Dict[str, Any]]:
        """Get presence info for a specific key.

        Args:
            key: The presence key

        Returns:
            Presence info dict or None if not found:
            {"metas": [{"name": "Alice", ...}]}
        """
        try:
            import erlang
            result = erlang.call('hornbeam_presence', 'get_by_key',
                                 self.topic, key)
            if result is None:
                return None
            return _convert_presence_entry(result)
        except Exception as e:
            print(f"Presence get error: {e}")
            return None


def _convert_presence_list(data: Any) -> Dict[str, Dict[str, Any]]:
    """Convert Erlang presence list to Python format."""
    if not isinstance(data, dict):
        return {}

    result = {}
    for k, v in data.items():
        key = _to_str(k)
        result[key] = _convert_presence_entry(v)
    return result


def _convert_presence_entry(data: Any) -> Dict[str, Any]:
    """Convert a single presence entry."""
    if not isinstance(data, dict):
        return {"metas": []}

    metas_key = 'metas' if 'metas' in data else b'metas'
    metas = data.get(metas_key, [])

    if isinstance(metas, list):
        converted_metas = [_convert_meta(m) for m in metas]
    else:
        converted_metas = []

    return {"metas": converted_metas}


def _convert_meta(meta: Any) -> Dict[str, Any]:
    """Convert a metadata dict."""
    if not isinstance(meta, dict):
        return {}

    result = {}
    for k, v in meta.items():
        key = _to_str(k)
        if isinstance(v, bytes):
            result[key] = v.decode('utf-8', errors='replace')
        elif isinstance(v, dict):
            result[key] = _convert_meta(v)
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
# Convenience Functions
# =============================================================================


def track(topic: str, socket: Any, key: str, meta: Dict[str, Any]) -> bool:
    """Track a presence (convenience function).

    Args:
        topic: The topic
        socket: The socket object
        key: Presence key
        meta: Metadata dict

    Returns:
        True if tracked successfully
    """
    return Presence(topic).track(socket, key, meta)


def untrack(topic: str, socket: Any, key: str) -> bool:
    """Untrack a presence (convenience function)."""
    return Presence(topic).untrack(socket, key)


def list_presences(topic: str) -> Dict[str, Dict[str, Any]]:
    """List presences for a topic (convenience function)."""
    return Presence(topic).list()
