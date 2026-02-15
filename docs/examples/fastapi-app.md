---
title: FastAPI Application
description: Running FastAPI on Hornbeam with async features
order: 21
---

# FastAPI Application Example

This example demonstrates a FastAPI application on Hornbeam with async endpoints, WebSocket support, and ML integration.

## Project Structure

```
fastapi_demo/
├── app.py           # FastAPI application
├── models.py        # Pydantic models
├── ml.py            # ML model loading
└── requirements.txt
```

## Application Code

```python
# app.py
from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from hornbeam_erlang import (
    state_get, state_set, state_incr, state_delete,
    state_keys, publish
)
from hornbeam_ml import cached_inference
import asyncio
import json

# ============================================================
# Models
# ============================================================

class Item(BaseModel):
    name: str
    description: str | None = None
    price: float

class ItemResponse(BaseModel):
    id: int
    name: str
    description: str | None
    price: float

class EmbedRequest(BaseModel):
    text: str

class SearchRequest(BaseModel):
    query: str
    top_k: int = 5

# ============================================================
# Lifespan: Load ML models at startup
# ============================================================

ml_model = None

@asynccontextmanager
async def lifespan(app):
    global ml_model
    # Startup
    print("Loading ML model...")
    from sentence_transformers import SentenceTransformer
    ml_model = SentenceTransformer('all-MiniLM-L6-v2')
    print("Model loaded!")

    yield

    # Shutdown
    ml_model = None
    print("Cleanup complete")

app = FastAPI(
    title="FastAPI on Hornbeam",
    lifespan=lifespan
)

# ============================================================
# Middleware
# ============================================================

@app.middleware("http")
async def track_requests(request, call_next):
    state_incr('metrics:requests')
    response = await call_next(request)
    state_incr(f'metrics:status:{response.status_code}')
    return response

# ============================================================
# CRUD Endpoints
# ============================================================

@app.post("/items/", response_model=ItemResponse)
async def create_item(item: Item):
    item_id = state_incr('items:seq')

    item_data = {
        'id': item_id,
        **item.model_dump()
    }
    state_set(f'item:{item_id}', item_data)

    # Notify subscribers
    publish('items:created', item_data)

    return item_data

@app.get("/items/", response_model=list[ItemResponse])
async def list_items():
    keys = state_keys('item:')
    items = []
    for key in keys:
        if key.startswith('item:') and ':' not in key[5:]:
            item = state_get(key)
            if item:
                items.append(item)
    return items

@app.get("/items/{item_id}", response_model=ItemResponse)
async def get_item(item_id: int):
    item = state_get(f'item:{item_id}')
    if not item:
        raise HTTPException(status_code=404, detail="Item not found")
    return item

@app.delete("/items/{item_id}")
async def delete_item(item_id: int):
    if not state_get(f'item:{item_id}'):
        raise HTTPException(status_code=404, detail="Item not found")

    state_delete(f'item:{item_id}')
    publish('items:deleted', {'id': item_id})
    return {"deleted": item_id}

# ============================================================
# ML Endpoints
# ============================================================

@app.post("/embed")
async def embed_text(request: EmbedRequest):
    """Generate embedding with caching."""
    embedding = cached_inference(ml_model.encode, request.text)
    return {
        'text': request.text,
        'embedding': embedding.tolist(),
        'dimensions': len(embedding)
    }

@app.post("/search")
async def semantic_search(request: SearchRequest):
    """Search items by semantic similarity."""
    import numpy as np

    query_embedding = cached_inference(ml_model.encode, request.query)
    query_embedding = np.array(query_embedding)

    # Get all items with embeddings
    results = []
    for key in state_keys('item:'):
        if ':emb' in key:
            continue

        item = state_get(key)
        if not item:
            continue

        # Get or compute embedding
        emb_key = f'{key}:emb'
        item_emb = state_get(emb_key)

        if not item_emb:
            text = f"{item['name']} {item.get('description', '')}"
            item_emb = cached_inference(ml_model.encode, text).tolist()
            state_set(emb_key, item_emb)

        # Compute similarity
        item_emb = np.array(item_emb)
        similarity = np.dot(query_embedding, item_emb) / (
            np.linalg.norm(query_embedding) * np.linalg.norm(item_emb)
        )

        results.append({
            **item,
            'score': float(similarity)
        })

    # Sort by similarity
    results.sort(key=lambda x: x['score'], reverse=True)
    return results[:request.top_k]

# ============================================================
# Streaming
# ============================================================

@app.get("/stream")
async def stream_data():
    """Stream data using Server-Sent Events."""
    async def generate():
        for i in range(10):
            data = {
                'count': i,
                'requests': state_get('metrics:requests') or 0
            }
            yield f"data: {json.dumps(data)}\n\n"
            await asyncio.sleep(1)
        yield "data: {\"done\": true}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream"
    )

# ============================================================
# WebSocket
# ============================================================

class ConnectionManager:
    def __init__(self):
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)
        state_incr('ws:connections')

    def disconnect(self, websocket: WebSocket):
        self.active_connections.remove(websocket)
        state_incr('ws:connections', -1)

    async def broadcast(self, message: str):
        for connection in self.active_connections:
            await connection.send_text(message)

manager = ConnectionManager()

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_text()
            message = json.loads(data)

            # Echo back with metadata
            response = {
                'received': message,
                'connections': len(manager.active_connections),
                'timestamp': asyncio.get_event_loop().time()
            }
            await websocket.send_text(json.dumps(response))

    except WebSocketDisconnect:
        manager.disconnect(websocket)

@app.websocket("/ws/broadcast")
async def broadcast_endpoint(websocket: WebSocket):
    """WebSocket that broadcasts to all connections."""
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_text()
            # Broadcast to all connected clients
            await manager.broadcast(data)
    except WebSocketDisconnect:
        manager.disconnect(websocket)

# ============================================================
# Metrics
# ============================================================

@app.get("/metrics")
async def get_metrics():
    from hornbeam_ml import cache_stats

    return {
        'requests': {
            'total': state_get('metrics:requests') or 0,
            'status_200': state_get('metrics:status:200') or 0,
            'status_404': state_get('metrics:status:404') or 0,
        },
        'items': {
            'count': len([k for k in state_keys('item:') if ':' not in k[5:]]),
        },
        'websocket': {
            'connections': state_get('ws:connections') or 0,
        },
        'ml_cache': cache_stats()
    }

# ============================================================
# Health check
# ============================================================

@app.get("/health")
async def health():
    return {
        'status': 'healthy',
        'model_loaded': ml_model is not None
    }
```

## Running with Hornbeam

```erlang
rebar3 shell

hornbeam:start("app:app", #{
    worker_class => asgi,
    lifespan => on,
    pythonpath => ["fastapi_demo"],
    workers => 4
}).
```

## Testing

```bash
# Health check
curl http://localhost:8000/health

# Create items
curl -X POST http://localhost:8000/items/ \
  -H "Content-Type: application/json" \
  -d '{"name": "Laptop", "description": "High-performance laptop", "price": 999.99}'

curl -X POST http://localhost:8000/items/ \
  -H "Content-Type: application/json" \
  -d '{"name": "Phone", "description": "Smartphone with great camera", "price": 699.99}'

# List items
curl http://localhost:8000/items/

# Generate embedding
curl -X POST http://localhost:8000/embed \
  -H "Content-Type: application/json" \
  -d '{"text": "high quality electronics"}'

# Semantic search
curl -X POST http://localhost:8000/search \
  -H "Content-Type: application/json" \
  -d '{"query": "computing device", "top_k": 2}'

# Stream events
curl http://localhost:8000/stream

# Metrics
curl http://localhost:8000/metrics
```

### WebSocket Testing

```python
import asyncio
import websockets

async def test_ws():
    async with websockets.connect('ws://localhost:8000/ws') as ws:
        await ws.send('{"message": "Hello!"}')
        response = await ws.recv()
        print(response)

asyncio.run(test_ws())
```

## Requirements

```
# requirements.txt
fastapi>=0.100
uvicorn>=0.20
sentence-transformers>=2.0
numpy>=1.20
```

## Key Features Demonstrated

1. **Lifespan events** for ML model loading
2. **ETS caching** for embeddings
3. **Semantic search** with cached vectors
4. **WebSocket** with connection management
5. **Server-Sent Events** streaming
6. **Metrics** endpoint with cache stats
7. **Pub/Sub** for item notifications

## Next Steps

- [WebSocket Chat Example](./websocket-chat) - Full chat application
- [Embedding Service Example](./embedding-service) - Production ML service
