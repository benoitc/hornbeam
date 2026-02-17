---
title: WebSocket Chat
description: Real-time chat with WebSocket and Pub/Sub
order: 22
---

# WebSocket Chat Example

A real-time chat application using WebSocket, ETS for user state, and Erlang Pub/Sub for message broadcasting.

## Project Structure

```
chat_demo/
├── app.py           # ASGI application
├── static/
│   └── index.html   # Chat UI
└── requirements.txt
```

## Server Code

```python
# app.py
import asyncio
import json
import uuid
from datetime import datetime
from hornbeam_erlang import (
    state_get, state_set, state_delete, state_incr,
    state_keys, publish, subscribe, unsubscribe
)

class ChatRoom:
    def __init__(self, room_id):
        self.room_id = room_id
        self.topic = f'chat:{room_id}'

    def add_user(self, user_id, username):
        state_set(f'room:{self.room_id}:user:{user_id}', {
            'username': username,
            'joined_at': datetime.now().isoformat()
        })
        state_incr(f'room:{self.room_id}:user_count')

    def remove_user(self, user_id):
        state_delete(f'room:{self.room_id}:user:{user_id}')
        state_incr(f'room:{self.room_id}:user_count', -1)

    def get_users(self):
        keys = state_keys(f'room:{self.room_id}:user:')
        users = []
        for key in keys:
            user = state_get(key)
            if user:
                users.append(user)
        return users

    def add_message(self, user_id, username, text):
        msg_id = state_incr(f'room:{self.room_id}:msg_seq')
        message = {
            'id': msg_id,
            'user_id': user_id,
            'username': username,
            'text': text,
            'timestamp': datetime.now().isoformat()
        }

        # Store last 100 messages
        state_set(f'room:{self.room_id}:msg:{msg_id}', message)

        # Broadcast to all subscribers
        publish(self.topic, {
            'type': 'message',
            'data': message
        })

        return message

    def get_recent_messages(self, limit=50):
        seq = state_get(f'room:{self.room_id}:msg_seq') or 0
        messages = []

        for i in range(max(1, seq - limit + 1), seq + 1):
            msg = state_get(f'room:{self.room_id}:msg:{i}')
            if msg:
                messages.append(msg)

        return messages


async def application(scope, receive, send):
    if scope['type'] == 'http':
        await handle_http(scope, receive, send)
    elif scope['type'] == 'websocket':
        await handle_websocket(scope, receive, send)


async def handle_http(scope, receive, send):
    path = scope.get('path', '/')

    if path == '/':
        # Serve chat UI
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [[b'content-type', b'text/html']],
        })
        await send({
            'type': 'http.response.body',
            'body': get_chat_html().encode(),
        })

    elif path == '/api/rooms':
        # List rooms
        rooms = []
        for key in state_keys('room:'):
            if ':user_count' in key:
                room_id = key.split(':')[1]
                count = state_get(key) or 0
                rooms.append({'id': room_id, 'users': count})

        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [[b'content-type', b'application/json']],
        })
        await send({
            'type': 'http.response.body',
            'body': json.dumps(rooms).encode(),
        })

    else:
        await send({
            'type': 'http.response.start',
            'status': 404,
            'headers': [[b'content-type', b'text/plain']],
        })
        await send({
            'type': 'http.response.body',
            'body': b'Not Found',
        })


async def handle_websocket(scope, receive, send):
    # Parse room from path: /ws/room-name
    path = scope.get('path', '/ws/general')
    room_id = path.split('/')[-1] or 'general'

    room = ChatRoom(room_id)
    user_id = str(uuid.uuid4())
    username = None

    # Accept connection
    await send({'type': 'websocket.accept'})

    # Subscribe to room topic
    subscribe(room.topic)

    try:
        while True:
            message = await receive()

            if message['type'] == 'websocket.disconnect':
                break

            if message['type'] == 'websocket.receive':
                data = json.loads(message.get('text', '{}'))
                msg_type = data.get('type')

                if msg_type == 'join':
                    username = data.get('username', f'user_{user_id[:8]}')
                    room.add_user(user_id, username)

                    # Send join confirmation
                    await send({
                        'type': 'websocket.send',
                        'text': json.dumps({
                            'type': 'joined',
                            'user_id': user_id,
                            'username': username,
                            'room': room_id,
                            'users': room.get_users(),
                            'recent_messages': room.get_recent_messages()
                        })
                    })

                    # Broadcast user joined
                    publish(room.topic, {
                        'type': 'user_joined',
                        'data': {'user_id': user_id, 'username': username}
                    })

                elif msg_type == 'message' and username:
                    text = data.get('text', '').strip()
                    if text:
                        room.add_message(user_id, username, text)

                elif msg_type == 'typing' and username:
                    publish(room.topic, {
                        'type': 'typing',
                        'data': {'user_id': user_id, 'username': username}
                    })

            # Check for pub/sub messages
            # In real implementation, use async pub/sub receiver
            # This is simplified for demonstration

    finally:
        if username:
            room.remove_user(user_id)
            publish(room.topic, {
                'type': 'user_left',
                'data': {'user_id': user_id, 'username': username}
            })
        unsubscribe(room.topic)


def get_chat_html():
    return '''<!DOCTYPE html>
<html>
<head>
    <title>Hornbeam Chat</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: system-ui; background: #1a1a2e; color: #eee; }
        .container { max-width: 800px; margin: 0 auto; height: 100vh; display: flex; flex-direction: column; }
        .header { padding: 1rem; background: #16213e; border-bottom: 1px solid #0f3460; }
        .header h1 { font-size: 1.5rem; color: #4a7c50; }
        .messages { flex: 1; overflow-y: auto; padding: 1rem; }
        .message { margin-bottom: 0.5rem; padding: 0.5rem; background: #16213e; border-radius: 8px; }
        .message .username { color: #4a7c50; font-weight: bold; }
        .message .time { color: #666; font-size: 0.8rem; }
        .message .text { margin-top: 0.25rem; }
        .input-area { padding: 1rem; background: #16213e; border-top: 1px solid #0f3460; }
        .input-area form { display: flex; gap: 0.5rem; }
        .input-area input { flex: 1; padding: 0.75rem; border: none; border-radius: 8px; background: #1a1a2e; color: #eee; }
        .input-area button { padding: 0.75rem 1.5rem; border: none; border-radius: 8px; background: #4a7c50; color: #fff; cursor: pointer; }
        .input-area button:hover { background: #3d6a43; }
        .join-form { padding: 2rem; text-align: center; }
        .join-form input { width: 200px; margin-right: 0.5rem; }
        .users { padding: 0.5rem 1rem; background: #0f3460; font-size: 0.9rem; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Hornbeam Chat</h1>
        </div>
        <div class="users" id="users">Users: -</div>
        <div class="messages" id="messages"></div>
        <div class="input-area">
            <div class="join-form" id="join-form">
                <input type="text" id="username" placeholder="Enter username">
                <button onclick="join()">Join Chat</button>
            </div>
            <form id="message-form" style="display:none" onsubmit="sendMessage(event)">
                <input type="text" id="message" placeholder="Type a message..." autocomplete="off">
                <button type="submit">Send</button>
            </form>
        </div>
    </div>
    <script>
        let ws;
        const room = 'general';

        function connect() {
            ws = new WebSocket(`ws://${location.host}/ws/${room}`);

            ws.onmessage = (event) => {
                const data = JSON.parse(event.data);
                handleMessage(data);
            };

            ws.onclose = () => {
                setTimeout(connect, 1000);
            };
        }

        function join() {
            const username = document.getElementById('username').value.trim();
            if (!username) return;

            ws.send(JSON.stringify({ type: 'join', username }));
            document.getElementById('join-form').style.display = 'none';
            document.getElementById('message-form').style.display = 'flex';
        }

        function sendMessage(e) {
            e.preventDefault();
            const input = document.getElementById('message');
            const text = input.value.trim();
            if (!text) return;

            ws.send(JSON.stringify({ type: 'message', text }));
            input.value = '';
        }

        function handleMessage(data) {
            if (data.type === 'joined') {
                updateUsers(data.users);
                data.recent_messages.forEach(addMessage);
            } else if (data.type === 'message') {
                addMessage(data.data);
            } else if (data.type === 'user_joined') {
                addSystemMessage(`${data.data.username} joined`);
            } else if (data.type === 'user_left') {
                addSystemMessage(`${data.data.username} left`);
            }
        }

        function addMessage(msg) {
            const div = document.createElement('div');
            div.className = 'message';
            div.innerHTML = `
                <span class="username">${msg.username}</span>
                <span class="time">${new Date(msg.timestamp).toLocaleTimeString()}</span>
                <div class="text">${escapeHtml(msg.text)}</div>
            `;
            document.getElementById('messages').appendChild(div);
            div.scrollIntoView();
        }

        function addSystemMessage(text) {
            const div = document.createElement('div');
            div.className = 'message';
            div.innerHTML = `<em style="color:#666">${text}</em>`;
            document.getElementById('messages').appendChild(div);
        }

        function updateUsers(users) {
            document.getElementById('users').textContent = `Users: ${users.map(u => u.username).join(', ')}`;
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        connect();
    </script>
</body>
</html>'''
```

## Running

```erlang
rebar3 shell

hornbeam:start("app:application", #{
    worker_class => asgi,
    pythonpath => ["chat_demo"],
    workers => 4,
    websocket_timeout => 300000  % 5 min timeout
}).
```

Open http://localhost:8000 in multiple browsers to test.

## Features

1. **Multiple rooms** - Join different rooms via URL path
2. **User presence** - Track who's online
3. **Message history** - Load recent messages on join
4. **ETS storage** - Messages and users in ETS
5. **Pub/Sub** - Real-time message broadcasting
6. **Typing indicators** - Show who's typing

## Next Steps

- [Embedding Service](./embedding-service.md) - ML with ETS caching
- [WebSocket Guide](../guides/websocket.md) - WebSocket details
