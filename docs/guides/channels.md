---
title: Channels & Presence
description: Real-time communication with multiplexed channels
order: 15
---

# Channels & Presence

Hornbeam provides channels for building real-time applications. Channels multiplex many topics over a single WebSocket connection, with built-in support for presence tracking, broadcasting, and event handling.

## How Channels Work

Channels are multiplexed topics over a single WebSocket connection:

- **Socket**: The WebSocket connection to the server
- **Channel**: A topic-based connection (e.g., `room:lobby`)
- **Events**: Messages sent/received on a channel
- **Presence**: Track who's online in a channel

The wire protocol uses JSON arrays: `[join_ref, ref, topic, event, payload]`

## Python API

### Defining Channels

Create a channel with a topic pattern. Patterns can include wildcards (`*`) to match any segment:

```python
from hornbeam_channels import channel, broadcast, broadcast_from

# Create a channel with wildcard pattern
room = channel("room:*")
```

### Join Handler

Handle join requests with `@channel.on_join`:

```python
@room.on_join
def join_room(topic, topic_params, params, socket):
    """Handle joining a chat room.

    Args:
        topic: The full topic (e.g., "room:lobby")
        topic_params: Extracted params (e.g., {"room_id": "lobby"})
        params: Client-provided join params (e.g., {"username": "Alice"})
        socket: The Socket object

    Returns:
        ('ok', response, socket) - Successful join
        ('error', reason) - Rejected join
    """
    room_id = topic_params.get("room_id", "unknown")
    username = params.get("username", "anonymous")

    if not username or username == "anonymous":
        return ('error', {"reason": "username required"})

    # Store user info in socket assigns
    socket = socket.assign("room_id", room_id)
    socket = socket.assign("username", username)

    return ('ok', {
        "room_id": room_id,
        "message": f"Welcome to {room_id}!"
    }, socket)
```

### Event Handlers

Handle events with `@channel.on("event_name")`:

```python
@room.on("new_msg")
def handle_new_message(payload, socket):
    """Handle a new chat message.

    Returns:
        ('reply', response, socket) - Reply to the client
        ('noreply', socket) - No reply needed
        ('stop', reason, socket) - Stop the channel
    """
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
```

### Leave Handler

Handle cleanup when a user leaves:

```python
@room.on_leave
def leave_room(topic, socket):
    """Handle leaving a chat room."""
    username = socket.assigns.get("username", "unknown")
    print(f"User {username} left {topic}")
```

### Socket Assigns

Store per-connection state using `socket.assign()`:

```python
# Store a single value
socket = socket.assign("username", "Alice")

# Access stored values
username = socket.assigns.get("username")

# Merge multiple values
socket = socket.merge_assigns({"role": "admin", "joined_at": "now"})
```

## Broadcasting

### broadcast(topic, event, payload)

Send a message to all subscribers of a topic:

```python
from hornbeam_channels import broadcast

# Broadcast to all users in a room
broadcast("room:lobby", "new_msg", {
    "username": "System",
    "body": "Welcome!"
})
```

### broadcast_from(socket, event, payload)

Send a message to all subscribers except the sender:

```python
from hornbeam_channels import broadcast_from

@room.on("new_msg")
def handle_message(payload, socket):
    # Broadcast to others (not back to sender)
    broadcast_from(socket, "new_msg", {
        "username": socket.assigns["username"],
        "body": payload["body"]
    })
    return ('noreply', socket)
```

## Presence

Track who's online in a channel with the Presence API. Presence is backed by CRDT (Conflict-free Replicated Data Type) for cluster-wide consistency.

### Tracking Users

```python
from hornbeam_presence import Presence

@room.on_join
def join_room(topic, topic_params, params, socket):
    username = params.get("username")
    socket = socket.assign("username", username)

    # Track this user's presence
    presence = Presence(topic)
    presence.track(socket, f"user:{username}", {
        "username": username,
        "joined_at": "now",
        "status": "online"
    })

    return ('ok', {"message": "Joined!"}, socket)
```

### Updating Presence

```python
@room.on("update_status")
def handle_status(payload, socket):
    username = socket.assigns["username"]
    status = payload.get("status", "online")

    presence = Presence(socket.topic)
    presence.update(socket, f"user:{username}", {
        "username": username,
        "status": status
    })

    return ('noreply', socket)
```

### Listing Presences

```python
from hornbeam_presence import Presence

# Get all presences for a topic
presence = Presence("room:lobby")
users = presence.list()
# Returns: {"user:alice": {"metas": [{"username": "Alice", ...}]}}

# Get a specific presence
alice = presence.get("user:alice")
# Returns: {"metas": [{"username": "Alice", "status": "online"}]}
```

### Presence Events

The client receives automatic events when presence changes:

- `presence_state` - Full state on join
- `presence_diff` - Changes (joins/leaves)

## JavaScript Client

### Socket Connection

```javascript
// Connect to the WebSocket endpoint
const socket = new Hornbeam.Socket('/ws', {
    params: { token: 'user_token' },
    logger: (kind, msg, data) => console.log(`${kind}: ${msg}`, data)
});

socket.onOpen(() => console.log('Connected'));
socket.onClose(() => console.log('Disconnected'));
socket.onError((error) => console.error('Error:', error));

socket.connect();
```

### Joining Channels

```javascript
// Create a channel
const channel = socket.channel('room:lobby', { username: 'Alice' });

// Join with callbacks
channel.join()
    .receive('ok', (resp) => {
        console.log('Joined!', resp);
    })
    .receive('error', (resp) => {
        console.error('Join failed:', resp.reason);
    })
    .receive('timeout', () => {
        console.error('Timeout');
    });
```

### Sending and Receiving Events

```javascript
// Send an event
channel.push('new_msg', { body: 'Hello!' })
    .receive('ok', () => console.log('Sent'))
    .receive('error', (e) => console.error('Error:', e));

// Receive events
channel.on('new_msg', (payload) => {
    console.log(`${payload.username}: ${payload.body}`);
});
```

### Presence Sync

```javascript
// Set up presence tracking
const presence = new Hornbeam.Presence(channel);

presence.onJoin((id, current, newPres) => {
    if (!current) {
        console.log(`${newPres.metas[0].username} joined`);
    }
});

presence.onLeave((id, current, leftPres) => {
    if (current.metas.length === 0) {
        console.log(`${leftPres.metas[0].username} left`);
    }
});

presence.onSync(() => {
    // Render updated presence list
    const users = presence.list((id, {metas}) => metas[0]);
    console.log('Online:', users.map(u => u.username));
});
```

### Leaving Channels

```javascript
channel.leave()
    .receive('ok', () => console.log('Left channel'));

// Disconnect socket entirely
socket.disconnect();
```

## Topic Patterns

Channels support wildcard patterns for flexible routing:

| Pattern | Matches | topic_params |
|---------|---------|--------------|
| `room:lobby` | `room:lobby` only | `{}` |
| `room:*` | `room:lobby`, `room:123` | `{"room_id": "lobby"}` |
| `chat:*:*` | `chat:team:general` | `{"chat_id": "team", "channel_id": "general"}` |

## Error Handling

```python
@room.on("risky_action")
def handle_risky(payload, socket):
    try:
        result = do_something_risky(payload)
        return ('reply', {"result": result}, socket)
    except ValueError as e:
        return ('reply', {"error": str(e)}, socket)
    except Exception as e:
        # Stop the channel on fatal errors
        return ('stop', str(e), socket)
```

## Running

Start your channel application:

```bash
hornbeam run your_module:app
```

Or from Erlang:

```erlang
hornbeam:start("your_module:app", #{
    worker_class => asgi,
    channel_modules => ["your_module"]
}).
```

## Next Steps

- [Channels Chat Example](../examples/channels-chat.md) - Full chat application
- [WebSocket Guide](./websocket.md) - Raw WebSocket for simpler use cases
- [Erlang Integration](./erlang-integration.md) - ETS, RPC, Pub/Sub details
