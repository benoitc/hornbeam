---
title: Channels Chat
description: Real-time chat with channels and presence
order: 23
---

# Channels Chat Example

A real-time chat application using channels with presence tracking, broadcasting, and a JavaScript client.

**Source**: [examples/channels_chat/](https://github.com/benoitc/hornbeam/tree/main/examples/channels_chat)

## Project Structure

```
examples/channels_chat/
├── app.py           # Channel handlers and ASGI app
├── index.html       # Chat UI with Hornbeam JS client
├── Dockerfile       # Container deployment
└── docker-compose.yml
```

## Server Code

```python
# app.py
from hornbeam_channels import channel, broadcast, broadcast_from, Socket
from hornbeam_presence import Presence

# Create the channel for chat rooms
room = channel("room:*")


@room.on_join
def join_room(topic, topic_params, params, socket):
    """Handle joining a chat room."""
    room_id = topic_params.get("room_id", "unknown")
    username = params.get("username", "anonymous")

    # Require username
    if not username or username == "anonymous":
        return ('error', {"reason": "username required"})

    # Store user info in socket assigns
    socket = socket.assign("room_id", room_id)
    socket = socket.assign("username", username)

    # Track presence
    presence = Presence(topic)
    presence.track(socket, f"user:{username}", {
        "username": username,
        "joined_at": "now"
    })

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
    """Handle a new chat message."""
    body = payload.get("body", "")
    username = socket.assigns.get("username", "anonymous")

    if not body:
        return ('reply', {"status": "error", "reason": "empty message"}, socket)

    # Broadcast to all users except sender
    broadcast_from(socket, "new_msg", {
        "username": username,
        "body": body
    })

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
    """Get recent message history."""
    # In a real app, fetch from database
    history = [
        {"username": "system", "body": "Welcome to the chat!"}
    ]
    return ('reply', {"messages": history}, socket)
```

## JavaScript Client

```javascript
let socket, channel, presence;

function joinRoom() {
    const username = document.getElementById('username').value.trim();
    const room = document.getElementById('room').value.trim();

    // Create socket connection
    socket = new Hornbeam.Socket('/ws', {
        params: { token: 'demo' },
        logger: (kind, msg, data) => console.log(`${kind}: ${msg}`, data)
    });

    socket.onOpen(() => updateStatus('Connected'));
    socket.onClose(() => updateStatus('Disconnected'));
    socket.onError((error) => console.error('Socket error:', error));

    // Create channel
    channel = socket.channel(`room:${room}`, { username: username });

    // Set up presence
    presence = new Hornbeam.Presence(channel);

    presence.onJoin((id, current, newPres) => {
        if (!current) {
            addMessage('System', `${newPres.metas[0].username} joined`, true);
        }
    });

    presence.onLeave((id, current, leftPres) => {
        if (current.metas.length === 0) {
            addMessage('System', `${leftPres.metas[0].username} left`, true);
        }
    });

    presence.onSync(() => renderPresences());

    // Handle incoming messages
    channel.on('new_msg', (payload) => {
        addMessage(payload.username, payload.body);
    });

    channel.on('typing', (payload) => {
        if (payload.typing) {
            document.getElementById('typing-indicator').textContent =
                `${payload.username} is typing...`;
        } else {
            document.getElementById('typing-indicator').textContent = '';
        }
    });

    // Join the channel
    channel.join()
        .receive('ok', (resp) => {
            console.log('Joined successfully', resp);
            showChatArea();
        })
        .receive('error', (resp) => {
            alert('Failed to join: ' + (resp.reason || 'Unknown error'));
        });

    socket.connect();
}

function sendMessage() {
    const input = document.getElementById('message-input');
    const body = input.value.trim();
    if (!body) return;

    channel.push('new_msg', { body: body })
        .receive('ok', () => {
            addMessage(username, body);
            input.value = '';
        })
        .receive('error', (resp) => {
            console.error('Send error', resp);
        });
}

function renderPresences() {
    const users = presence.list((id, {metas}) => metas[0]);
    document.getElementById('users').innerHTML = users.map(meta =>
        `<span class="user">${meta.username}</span>`
    ).join('');
}

function leaveRoom() {
    channel.leave().receive('ok', () => console.log('Left room'));
    socket.disconnect();
}
```

## Running

### With Hornbeam CLI

```bash
hornbeam run examples/channels_chat:app
```

Open http://localhost:8000 in multiple browser windows to test.

### With Docker

```bash
cd examples/channels_chat
docker-compose up
```

### From Erlang Shell

```erlang
rebar3 shell

hornbeam:start("examples.channels_chat.app:app", #{
    worker_class => asgi,
    pythonpath => ["examples/channels_chat"],
    workers => 4
}).
```

## Features

1. **Channels** - Decorator-based API for event handlers
2. **Presence Tracking** - Know who's online with CRDT-backed presence
3. **Broadcasting** - Send messages to all or exclude sender
4. **Typing Indicators** - Real-time typing status
5. **Wildcard Topics** - `room:*` pattern matches any room
6. **Socket Assigns** - Per-connection state storage
7. **JavaScript Client** - Full-featured client with presence sync

## Protocol

Messages use the channel protocol format:

```json
[join_ref, ref, topic, event, payload]
```

| Field | Description |
|-------|-------------|
| `join_ref` | Reference for the join message |
| `ref` | Unique reference for this message |
| `topic` | Channel topic (e.g., `room:lobby`) |
| `event` | Event name (e.g., `new_msg`, `hb_join`) |
| `payload` | Event data |

### System Events

| Event | Direction | Purpose |
|-------|-----------|---------|
| `hb_join` | Client → Server | Join a channel |
| `hb_leave` | Client → Server | Leave a channel |
| `hb_reply` | Server → Client | Reply to a push |
| `hb_close` | Server → Client | Channel closed |
| `hb_error` | Server → Client | Channel error |
| `presence_state` | Server → Client | Full presence state |
| `presence_diff` | Server → Client | Presence changes |

## Next Steps

- [Channels Guide](../guides/channels.md) - Full channels documentation
- [WebSocket Chat](./websocket-chat.md) - Simpler WebSocket approach
- [Erlang Integration](../guides/erlang-integration.md) - ETS, RPC, Pub/Sub
