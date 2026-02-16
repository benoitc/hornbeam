# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0

"""Real-time Chat Demo - FastAPI WebSocket + Erlang Pub/Sub.

This example demonstrates real-time messaging using Erlang's pg
(process groups) for cluster-wide pub/sub.

Run with Hornbeam:
    hornbeam:start("app:app", #{
        worker_class => asgi,
        pythonpath => ["examples/demo/realtime_chat"]
    }).

Test:
    Open http://localhost:8000 in multiple browser tabs
    Messages broadcast to all connected clients

For cluster setup:
    # Node 1
    rebar3 shell --sname chat1
    > hornbeam:start("app:app", #{port => 8001, ...}).

    # Node 2
    rebar3 shell --sname chat2
    > net_adm:ping('chat1@hostname').
    > hornbeam:start("app:app", #{port => 8002, ...}).

    # Messages from :8001 reach clients on :8002 via Erlang pg
"""

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from typing import Dict, Set
from contextlib import asynccontextmanager

# Try to import hornbeam broadcast (works when running under Hornbeam)
_state: Dict[str, int] = {}
USING_HORNBEAM = False

try:
    from hornbeam_websocket_runner import broadcast as hornbeam_broadcast
    USING_HORNBEAM = True
except ImportError:
    # Fallback for standalone testing
    def hornbeam_broadcast(session_id, topic, message):
        return False


def state_incr(key, delta=1):
    _state[key] = _state.get(key, 0) + delta
    return _state[key]

def state_get(key):
    return _state.get(key)


# Track connections per room (for local broadcasting fallback when not using Erlang)
room_connections: Dict[str, Set[WebSocket]] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    """ASGI lifespan handler."""
    yield


app = FastAPI(
    title="Real-time Chat Demo",
    description="WebSocket chat with Erlang pub/sub",
    lifespan=lifespan
)


HTML_PAGE = """
<!DOCTYPE html>
<html>
<head>
    <title>Hornbeam Chat</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; }
        #messages { height: 400px; overflow-y: auto; border: 1px solid #ccc; padding: 10px; margin-bottom: 10px; background: #f9f9f9; }
        .message { margin: 5px 0; padding: 8px; background: white; border-radius: 4px; }
        .system { color: #666; font-style: italic; }
        .user { color: #333; }
        .username { font-weight: bold; color: #4a7c50; }
        input { padding: 10px; width: 70%; }
        button { padding: 10px 20px; background: #4a7c50; color: white; border: none; cursor: pointer; }
        button:hover { background: #2c5530; }
        .status { font-size: 12px; color: #666; margin-bottom: 10px; }
    </style>
</head>
<body>
    <h1>Hornbeam Real-time Chat</h1>
    <div class="status">
        Room: <strong id="room">general</strong> |
        Status: <span id="status">Connecting...</span> |
        Users: <span id="users">0</span>
    </div>
    <div id="messages"></div>
    <input type="text" id="input" placeholder="Type a message..." autofocus>
    <button onclick="send()">Send</button>

    <script>
        const room = new URLSearchParams(location.search).get('room') || 'general';
        document.getElementById('room').textContent = room;

        const ws = new WebSocket(`ws://${location.host}/chat/${room}`);
        const messages = document.getElementById('messages');
        const input = document.getElementById('input');
        const status = document.getElementById('status');

        let username = 'Guest' + Math.floor(Math.random() * 1000);

        ws.onopen = () => {
            status.textContent = 'Connected';
            status.style.color = '#4a7c50';
            ws.send(JSON.stringify({ type: 'join', username }));
        };

        ws.onclose = () => {
            status.textContent = 'Disconnected';
            status.style.color = '#c00';
        };

        ws.onmessage = (e) => {
            const msg = JSON.parse(e.data);
            const div = document.createElement('div');
            div.className = 'message ' + (msg.type === 'system' ? 'system' : 'user');

            if (msg.type === 'system') {
                div.textContent = msg.text;
            } else {
                div.innerHTML = '<span class="username">' + (msg.username || 'Anonymous') + ':</span> ' + msg.text;
            }

            messages.appendChild(div);
            messages.scrollTop = messages.scrollHeight;

            if (msg.users !== undefined) {
                document.getElementById('users').textContent = msg.users;
            }
        };

        function send() {
            if (input.value.trim()) {
                ws.send(JSON.stringify({ type: 'message', text: input.value }));
                input.value = '';
            }
        }

        input.onkeypress = (e) => { if (e.key === 'Enter') send(); };
    </script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
async def home():
    """Serve chat HTML page."""
    return HTML_PAGE


@app.websocket("/chat/{room}")
async def chat(websocket: WebSocket, room: str):
    """WebSocket chat endpoint with Erlang pubsub.

    Erlang auto-subscribes this WebSocket to the topic based on URL path:
    /chat/general -> topic "chat:general"

    We use hornbeam_broadcast() to queue messages for Erlang to publish
    after the py:call returns (avoiding nested Erlang calls).
    """
    await websocket.accept()
    username = "Anonymous"
    topic = f"chat:{room}"

    # Get session_id from ASGI scope (set by hornbeam)
    session_id = websocket.scope.get("session_id")
    print(f"DEBUG: session_id={session_id}, USING_HORNBEAM={USING_HORNBEAM}", flush=True)

    # Track connection
    state_incr(f"room:{room}:connections")
    state_incr("ws_total_connections")

    # For local fallback when not running under Hornbeam
    if room not in room_connections:
        room_connections[room] = set()
    room_connections[room].add(websocket)

    try:
        while True:
            data = await websocket.receive_json()
            msg_type = data.get("type", "message")

            if msg_type == "join":
                username = data.get("username", "Anonymous")
                broadcast_msg = {
                    "type": "system",
                    "text": f"{username} joined the room",
                    "users": len(room_connections.get(room, set()))
                }
            elif msg_type == "message":
                text = data.get("text", "")
                if not text:
                    continue
                state_incr("ws_messages")
                broadcast_msg = {
                    "type": "message",
                    "username": username,
                    "text": text
                }
            else:
                continue

            # Broadcast to all clients
            if session_id and USING_HORNBEAM:
                # Queue for Erlang pubsub - Erlang publishes after py:call returns
                hornbeam_broadcast(session_id, topic, broadcast_msg)
            else:
                # Local broadcast for standalone testing
                for conn in list(room_connections.get(room, set())):
                    try:
                        await conn.send_json(broadcast_msg)
                    except:
                        room_connections.get(room, set()).discard(conn)

    except WebSocketDisconnect:
        pass
    finally:
        room_connections.get(room, set()).discard(websocket)
        state_incr(f"room:{room}:connections", -1)

        # Notify remaining users
        leave_msg = {
            "type": "system",
            "text": f"{username} left the room",
            "users": len(room_connections.get(room, set()))
        }
        if session_id and USING_HORNBEAM:
            hornbeam_broadcast(session_id, topic, leave_msg)
        else:
            for conn in list(room_connections.get(room, set())):
                try:
                    await conn.send_json(leave_msg)
                except:
                    pass


@app.get("/stats")
async def stats():
    """Get chat statistics."""
    return {
        "total_connections": state_get("ws_total_connections") or 0,
        "total_messages": state_get("ws_messages") or 0,
        "using_hornbeam": USING_HORNBEAM
    }
