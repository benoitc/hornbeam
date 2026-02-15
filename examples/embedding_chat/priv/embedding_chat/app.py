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

"""FastAPI app for embedding and chat.

Endpoints:
- POST /embed - Get embeddings (calls Erlang hook)
- POST /similarity - Compute similarity
- POST /find_similar - Find most similar text
- GET /chat - Chat UI (WebSocket at /ws handled by Erlang)
"""

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from typing import List

from hornbeam_erlang import execute

app = FastAPI(
    title="Embedding Chat API",
    description="Sentence embeddings via Erlang + WebSocket echo",
    version="1.0.0"
)


class EmbedRequest(BaseModel):
    texts: List[str]


class EmbedResponse(BaseModel):
    embeddings: List[List[float]]
    dimension: int
    count: int


class SimilarityRequest(BaseModel):
    text1: str
    text2: str


class SimilarityResponse(BaseModel):
    similarity: float
    interpretation: str


class FindSimilarRequest(BaseModel):
    query: str
    candidates: List[str]


class FindSimilarResponse(BaseModel):
    index: int
    score: float
    match: str


@app.get("/")
async def root():
    """API information."""
    return {
        "name": "Embedding Chat API",
        "endpoints": {
            "POST /embed": "Get embeddings for texts",
            "POST /similarity": "Compute similarity between two texts",
            "POST /find_similar": "Find most similar text",
            "GET /chat": "Chat UI with WebSocket"
        }
    }


@app.post("/embed", response_model=EmbedResponse)
async def embed(request: EmbedRequest):
    """Get embeddings for texts."""
    embeddings = execute("embeddings", "embed", request.texts)
    return EmbedResponse(
        embeddings=embeddings,
        dimension=len(embeddings[0]) if embeddings else 0,
        count=len(embeddings)
    )


@app.post("/similarity", response_model=SimilarityResponse)
async def similarity(request: SimilarityRequest):
    """Compute cosine similarity between two texts."""
    score = execute("embeddings", "similarity", request.text1, request.text2)

    if score >= 0.8:
        interpretation = "Very similar (same meaning)"
    elif score >= 0.5:
        interpretation = "Similar (related)"
    elif score >= 0.3:
        interpretation = "Somewhat related"
    else:
        interpretation = "Different topics"

    return SimilarityResponse(
        similarity=round(score, 4),
        interpretation=interpretation
    )


@app.post("/find_similar", response_model=FindSimilarResponse)
async def find_similar(request: FindSimilarRequest):
    """Find the most similar text from candidates."""
    index, score, match = execute("embeddings", "find_similar",
                                  request.query, request.candidates)
    return FindSimilarResponse(
        index=index,
        score=round(score, 4),
        match=match
    )


@app.get("/chat", response_class=HTMLResponse)
async def chat():
    """Chat UI with WebSocket (handled by Erlang)."""
    return """
<!DOCTYPE html>
<html>
<head>
    <title>Erlang WebSocket Chat</title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
        }
        h1 { color: #333; }
        .info {
            background: #e3f2fd;
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
        }
        .info code {
            background: #bbdefb;
            padding: 2px 6px;
            border-radius: 4px;
        }
        #chat-container {
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        #messages {
            height: 400px;
            overflow-y: auto;
            padding: 15px;
            border-bottom: 1px solid #eee;
        }
        .message {
            margin: 10px 0;
            padding: 10px 15px;
            border-radius: 18px;
            max-width: 80%;
        }
        .message.sent {
            background: #0084ff;
            color: white;
            margin-left: auto;
        }
        .message.received {
            background: #e4e6eb;
            color: #050505;
        }
        .message.system {
            background: #d4edda;
            color: #155724;
            text-align: center;
            max-width: 100%;
        }
        #input-container {
            display: flex;
            padding: 15px;
        }
        #message-input {
            flex: 1;
            padding: 12px 15px;
            border: 1px solid #ddd;
            border-radius: 24px;
            font-size: 16px;
        }
        #send-btn {
            background: #0084ff;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 24px;
            margin-left: 10px;
            cursor: pointer;
        }
        #status {
            padding: 10px 15px;
            font-size: 0.85em;
        }
        .connected { color: #28a745; }
        .disconnected { color: #dc3545; }
    </style>
</head>
<body>
    <h1>Erlang WebSocket Echo</h1>

    <div class="info">
        <strong>Architecture:</strong>
        <ul>
            <li>This page: <code>FastAPI</code> (Python ASGI)</li>
            <li>WebSocket at <code>/ws</code>: <code>cowboy_websocket</code> (pure Erlang)</li>
            <li>Erlang echoes messages with a counter</li>
        </ul>
    </div>

    <div id="chat-container">
        <div id="status" class="disconnected">Disconnected</div>
        <div id="messages"></div>
        <div id="input-container">
            <input type="text" id="message-input" placeholder="Type a message..." disabled>
            <button id="send-btn" disabled>Send</button>
        </div>
    </div>

    <script>
        const messagesDiv = document.getElementById('messages');
        const statusDiv = document.getElementById('status');
        const input = document.getElementById('message-input');
        const sendBtn = document.getElementById('send-btn');
        let ws = null;

        function addMessage(text, type) {
            const msg = document.createElement('div');
            msg.className = `message ${type}`;
            msg.textContent = text;
            messagesDiv.appendChild(msg);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }

        function connect() {
            const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            ws = new WebSocket(`${protocol}//${location.host}/ws`);

            ws.onopen = () => {
                statusDiv.textContent = 'Connected to Erlang WebSocket';
                statusDiv.className = 'connected';
                input.disabled = false;
                sendBtn.disabled = false;
                input.focus();
            };

            ws.onmessage = (e) => addMessage(e.data, 'received');

            ws.onclose = () => {
                statusDiv.textContent = 'Disconnected - Reconnecting...';
                statusDiv.className = 'disconnected';
                input.disabled = true;
                sendBtn.disabled = true;
                setTimeout(connect, 2000);
            };
        }

        function send() {
            const text = input.value.trim();
            if (text && ws?.readyState === WebSocket.OPEN) {
                ws.send(text);
                addMessage(text, 'sent');
                input.value = '';
            }
        }

        sendBtn.onclick = send;
        input.onkeypress = (e) => { if (e.key === 'Enter') send(); };
        connect();
    </script>
</body>
</html>
"""
