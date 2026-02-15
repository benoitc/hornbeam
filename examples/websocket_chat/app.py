# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0

"""WebSocket Chat Room Example.

This example demonstrates:
- ASGI WebSocket protocol
- Erlang ETS for storing room state
- Broadcasting messages to room members

Run with:
    hornbeam:start("websocket_chat.app:app", #{worker_class => asgi}).

Test with:
    websocat ws://localhost:8000/chat/general

Message format:
    {"type": "message", "text": "Hello everyone!"}
    {"type": "join", "username": "alice"}
"""

import json
from typing import Dict, Set

# Import hornbeam utilities
try:
    from hornbeam_erlang import state_get, state_set, state_incr
except ImportError:
    def state_get(k): return None
    def state_set(k, v): pass
    def state_incr(k, d=1): return d


# In-memory connections (per-process, use ETS for cross-process)
# In production, use Erlang pubsub for cross-node messaging
rooms: Dict[str, Set[str]] = {}


async def handle_http(scope, receive, send):
    """Handle HTTP requests (health check, room info)."""
    path = scope['path']

    if path == '/health':
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [(b'content-type', b'application/json')]
        })
        await send({
            'type': 'http.response.body',
            'body': json.dumps({'status': 'ok'}).encode()
        })
    elif path.startswith('/rooms/'):
        room_name = path[7:]  # Remove '/rooms/'
        room_count = state_get(f'room:{room_name}:count') or 0
        messages = state_get(f'room:{room_name}:recent') or []

        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [(b'content-type', b'application/json')]
        })
        await send({
            'type': 'http.response.body',
            'body': json.dumps({
                'room': room_name,
                'connections': room_count,
                'recent_messages': messages[-10:]
            }).encode()
        })
    else:
        # Simple HTML page for testing
        html = """
<!DOCTYPE html>
<html>
<head><title>WebSocket Chat</title></head>
<body>
    <h1>WebSocket Chat</h1>
    <div id="messages" style="height:300px;overflow-y:scroll;border:1px solid #ccc;padding:10px;"></div>
    <input type="text" id="input" placeholder="Type a message..." style="width:80%">
    <button onclick="sendMessage()">Send</button>
    <script>
        const room = 'general';
        const ws = new WebSocket(`ws://${location.host}/chat/${room}`);
        const messages = document.getElementById('messages');
        const input = document.getElementById('input');

        ws.onmessage = (e) => {
            const msg = JSON.parse(e.data);
            messages.innerHTML += `<p><b>${msg.username || 'Anonymous'}:</b> ${msg.text}</p>`;
            messages.scrollTop = messages.scrollHeight;
        };

        ws.onopen = () => {
            ws.send(JSON.stringify({type: 'join', username: 'Guest' + Math.floor(Math.random()*1000)}));
        };

        function sendMessage() {
            if (input.value) {
                ws.send(JSON.stringify({type: 'message', text: input.value}));
                input.value = '';
            }
        }

        input.onkeypress = (e) => { if (e.key === 'Enter') sendMessage(); };
    </script>
</body>
</html>
        """
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [(b'content-type', b'text/html')]
        })
        await send({
            'type': 'http.response.body',
            'body': html.encode()
        })


async def handle_websocket(scope, receive, send):
    """Handle WebSocket chat connection."""
    path = scope['path']

    # Extract room name from path: /chat/{room_name}
    if not path.startswith('/chat/'):
        return

    room_name = path[6:]  # Remove '/chat/'
    username = 'Anonymous'

    # Wait for connection
    message = await receive()
    if message['type'] != 'websocket.connect':
        return

    # Accept connection
    await send({'type': 'websocket.accept'})

    # Track connection
    state_incr(f'room:{room_name}:count', 1)
    state_incr('ws_connections', 1)

    try:
        # Message loop
        while True:
            message = await receive()

            if message['type'] == 'websocket.disconnect':
                break

            if message['type'] == 'websocket.receive':
                try:
                    if 'text' in message:
                        data = json.loads(message['text'])
                    else:
                        data = json.loads(message['bytes'].decode())

                    msg_type = data.get('type', 'message')

                    if msg_type == 'join':
                        username = data.get('username', 'Anonymous')
                        # Notify room
                        await send({
                            'type': 'websocket.send',
                            'text': json.dumps({
                                'type': 'system',
                                'text': f'{username} joined the room'
                            })
                        })

                    elif msg_type == 'message':
                        text = data.get('text', '')
                        if text:
                            # Store message in ETS
                            recent = state_get(f'room:{room_name}:recent') or []
                            recent.append({
                                'username': username,
                                'text': text
                            })
                            # Keep last 100 messages
                            state_set(f'room:{room_name}:recent', recent[-100:])
                            state_incr('ws_messages', 1)

                            # Echo back (in real app, broadcast to all connections)
                            await send({
                                'type': 'websocket.send',
                                'text': json.dumps({
                                    'type': 'message',
                                    'username': username,
                                    'text': text
                                })
                            })

                except json.JSONDecodeError:
                    await send({
                        'type': 'websocket.send',
                        'text': json.dumps({
                            'type': 'error',
                            'text': 'Invalid JSON'
                        })
                    })

    finally:
        # Cleanup
        state_incr(f'room:{room_name}:count', -1)
        state_incr('ws_disconnections', 1)


async def app(scope, receive, send):
    """Main ASGI application."""
    if scope['type'] == 'http':
        await handle_http(scope, receive, send)
    elif scope['type'] == 'websocket':
        await handle_websocket(scope, receive, send)
