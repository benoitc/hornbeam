"""Example Phoenix-style Channels chat application.

This demonstrates the channel and presence APIs for a real-time chat room.

Run with:
    hornbeam run examples/channels_chat:app

Then connect with the JavaScript client or test with:
    python examples/channels_chat/test_client.py
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'priv'))

from hornbeam_channels import channel, broadcast, broadcast_from, Socket
from hornbeam_presence import Presence

# Create the channel for chat rooms
room = channel("room:*")


@room.on_join
def join_room(topic, topic_params, params, socket):
    """Handle joining a chat room.

    Args:
        topic: The full topic (e.g., "room:lobby")
        topic_params: Extracted params (e.g., {"room_id": "lobby"})
        params: Client-provided join params (e.g., {"username": "Alice"})
        socket: The Socket object

    Returns:
        ('ok', response, socket) or ('error', reason)
    """
    room_id = topic_params.get("room_id", "unknown")
    username = params.get("username", "anonymous")

    # Check if user provided a username
    if not username or username == "anonymous":
        return ('error', {"reason": "username required"})

    # Store user info in socket assigns
    socket = socket.assign("room_id", room_id)
    socket = socket.assign("username", username)

    # Track presence
    presence = Presence(topic)
    presence.track(socket, f"user:{username}", {
        "username": username,
        "joined_at": "now"  # In real app, use actual timestamp
    })

    # Return success with room info
    return ('ok', {
        "room_id": room_id,
        "message": f"Welcome to {room_id}!"
    }, socket)


@room.on_leave
def leave_room(topic, socket):
    """Handle leaving a chat room."""
    username = socket.assigns.get("username", "unknown")
    print(f"User {username} left {topic}")


@room.on("new_msg")
def handle_new_message(payload, socket):
    """Handle a new chat message.

    Broadcasts the message to all users in the room.
    """
    body = payload.get("body", "")
    username = socket.assigns.get("username", "anonymous")

    if not body:
        return ('reply', {"status": "error", "reason": "empty message"}, socket)

    # Build the message to broadcast
    message = {
        "username": username,
        "body": body
    }

    # Broadcast to all users except sender
    broadcast_from(socket, "new_msg", message)

    # Reply to sender with confirmation
    return ('reply', {"status": "ok"}, socket)


@room.on("typing")
def handle_typing(payload, socket):
    """Handle typing indicator."""
    username = socket.assigns.get("username", "anonymous")
    is_typing = payload.get("typing", False)

    # Broadcast typing status to others
    broadcast_from(socket, "typing", {
        "username": username,
        "typing": is_typing
    })

    return ('noreply', socket)


@room.on("get_history")
def handle_get_history(payload, socket):
    """Get recent message history.

    In a real app, this would fetch from a database.
    """
    # Return mock history
    history = [
        {"username": "system", "body": "Welcome to the chat!"}
    ]
    return ('reply', {"messages": history}, socket)


# ASGI app - serves static files and handles non-channel WebSockets
async def app(scope, receive, send):
    """ASGI app for serving the chat UI.

    Channels are handled by the channel protocol, not ASGI.
    This serves the HTML/JS files and handles non-channel WebSocket connections.
    """
    if scope["type"] == "http":
        path = scope.get("path", "/")

        # Serve index.html
        if path == "/" or path == "/index.html":
            await serve_file(send, "index.html", "text/html")
        # Serve hornbeam.js from js directory
        elif path == "/hornbeam.js" or path == "/js/hornbeam.js":
            js_path = os.path.join(os.path.dirname(__file__), "..", "..", "js", "hornbeam.js")
            await serve_file_path(send, js_path, "application/javascript")
        else:
            # 404 for other paths
            await send({
                "type": "http.response.start",
                "status": 404,
                "headers": [[b"content-type", b"text/plain"]],
            })
            await send({
                "type": "http.response.body",
                "body": b"Not Found",
            })

    elif scope["type"] == "websocket":
        # Non-channel WebSocket connections
        message = await receive()
        if message["type"] == "websocket.connect":
            await send({"type": "websocket.accept"})
            await send({
                "type": "websocket.send",
                "text": "Use channel protocol [join_ref, ref, topic, event, payload]"
            })


async def serve_file(send, filename, content_type):
    """Serve a file from the same directory as this script."""
    filepath = os.path.join(os.path.dirname(__file__), filename)
    await serve_file_path(send, filepath, content_type)


async def serve_file_path(send, filepath, content_type):
    """Serve a file from an absolute path."""
    try:
        with open(filepath, "rb") as f:
            content = f.read()
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [[b"content-type", content_type.encode()]],
        })
        await send({
            "type": "http.response.body",
            "body": content,
        })
    except FileNotFoundError:
        await send({
            "type": "http.response.start",
            "status": 404,
            "headers": [[b"content-type", b"text/plain"]],
        })
        await send({
            "type": "http.response.body",
            "body": f"File not found: {filepath}".encode(),
        })


if __name__ == "__main__":
    print("Channels Chat Example")
    print("=====================")
    print()
    print("Registered channels:")
    from hornbeam_channels import list_channels
    for pattern, ch in list_channels().items():
        print(f"  - {pattern}")
    print()
    print("Run with: hornbeam run examples/channels_chat:app")
