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

"""Simple ASGI chat application example.

This demonstrates an ASGI application with WebSocket support (when available).
For HTTP requests, it provides a simple chat interface.
"""

import json


async def application(scope, receive, send):
    """ASGI application for chat demo."""
    if scope['type'] == 'http':
        await handle_http(scope, receive, send)
    elif scope['type'] == 'websocket':
        await handle_websocket(scope, receive, send)


async def handle_http(scope, receive, send):
    """Handle HTTP requests."""
    path = scope.get('path', '/')
    method = scope.get('method', 'GET')

    if path == '/':
        # Return chat page
        body = b'''<!DOCTYPE html>
<html>
<head>
    <title>Hornbeam Chat</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 600px; margin: 50px auto; }
        #messages { height: 400px; border: 1px solid #ccc; overflow-y: scroll; padding: 10px; }
        #input { width: 80%; padding: 10px; }
        button { padding: 10px 20px; }
    </style>
</head>
<body>
    <h1>Hornbeam ASGI Chat</h1>
    <div id="messages"></div>
    <input type="text" id="input" placeholder="Type a message...">
    <button onclick="sendMessage()">Send</button>

    <script>
        const ws = new WebSocket('ws://' + window.location.host + '/ws');
        const messages = document.getElementById('messages');
        const input = document.getElementById('input');

        ws.onmessage = function(event) {
            const msg = JSON.parse(event.data);
            messages.innerHTML += '<p><b>' + msg.user + ':</b> ' + msg.text + '</p>';
            messages.scrollTop = messages.scrollHeight;
        };

        ws.onopen = function() {
            messages.innerHTML += '<p><i>Connected to chat server</i></p>';
        };

        ws.onclose = function() {
            messages.innerHTML += '<p><i>Disconnected from server</i></p>';
        };

        function sendMessage() {
            const text = input.value.trim();
            if (text) {
                ws.send(JSON.stringify({text: text}));
                input.value = '';
            }
        }

        input.addEventListener('keypress', function(e) {
            if (e.key === 'Enter') sendMessage();
        });
    </script>
</body>
</html>
'''
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [
                [b'content-type', b'text/html'],
                [b'content-length', str(len(body)).encode()],
            ],
        })
        await send({
            'type': 'http.response.body',
            'body': body,
        })
    elif path == '/api/messages' and method == 'POST':
        # Simple HTTP API for sending messages
        body = b''
        while True:
            message = await receive()
            body += message.get('body', b'')
            if not message.get('more_body', False):
                break

        data = json.loads(body)
        response = json.dumps({'status': 'ok', 'message': data})

        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [
                [b'content-type', b'application/json'],
                [b'content-length', str(len(response)).encode()],
            ],
        })
        await send({
            'type': 'http.response.body',
            'body': response.encode(),
        })
    else:
        body = b'Not Found'
        await send({
            'type': 'http.response.start',
            'status': 404,
            'headers': [[b'content-type', b'text/plain']],
        })
        await send({
            'type': 'http.response.body',
            'body': body,
        })


async def handle_websocket(scope, receive, send):
    """Handle WebSocket connections."""
    # Accept connection
    await send({'type': 'websocket.accept'})

    user_id = 0
    try:
        while True:
            message = await receive()
            if message['type'] == 'websocket.connect':
                user_id += 1
                continue
            elif message['type'] == 'websocket.disconnect':
                break
            elif message['type'] == 'websocket.receive':
                data = json.loads(message.get('text', '{}'))
                text = data.get('text', '')

                # Broadcast back (in a real app, you'd broadcast to all clients)
                response = json.dumps({
                    'user': f'User-{user_id}',
                    'text': text
                })
                await send({
                    'type': 'websocket.send',
                    'text': response
                })
    except Exception as e:
        print(f"WebSocket error: {e}")
    finally:
        await send({'type': 'websocket.close'})
