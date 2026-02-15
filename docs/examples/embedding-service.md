---
title: Embedding Service
description: Production ML embedding service with ETS caching
order: 23
---

# Embedding Service Example

A production-ready embedding service using sentence-transformers with ETS-backed caching for high-throughput semantic search.

## Project Structure

```
embedding_service/
├── app.py              # FastAPI application
├── embeddings.py       # Embedding logic
├── search.py           # Search implementation
├── config.py           # Configuration
└── requirements.txt
```

## Application Code

```python
# app.py
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from hornbeam_erlang import state_get, state_set, state_incr
from hornbeam_ml import cached_inference, cache_stats
import numpy as np
from typing import Optional

# ============================================================
# Configuration
# ============================================================

class Config:
    MODEL_NAME = 'all-MiniLM-L6-v2'
    CACHE_PREFIX = 'emb'
    MAX_BATCH_SIZE = 100
    SIMILARITY_THRESHOLD = 0.5

config = Config()

# ============================================================
# Models
# ============================================================

class EmbedRequest(BaseModel):
    texts: list[str]
    cache: bool = True

class EmbedResponse(BaseModel):
    embeddings: list[list[float]]
    dimensions: int
    cached_count: int

class IndexRequest(BaseModel):
    id: str
    text: str
    metadata: Optional[dict] = None

class SearchRequest(BaseModel):
    query: str
    top_k: int = 10
    threshold: float = 0.5

class SearchResult(BaseModel):
    id: str
    text: str
    score: float
    metadata: Optional[dict]

# ============================================================
# ML Model
# ============================================================

model = None

@asynccontextmanager
async def lifespan(app):
    global model
    print(f"Loading model: {config.MODEL_NAME}")
    from sentence_transformers import SentenceTransformer
    model = SentenceTransformer(config.MODEL_NAME)
    print(f"Model loaded. Dimensions: {model.get_sentence_embedding_dimension()}")

    # Warm up cache
    _ = model.encode("warmup")

    yield

    model = None

app = FastAPI(
    title="Embedding Service",
    description="High-performance embedding service with ETS caching",
    lifespan=lifespan
)

# ============================================================
# Embedding Endpoints
# ============================================================

@app.post("/embed", response_model=EmbedResponse)
async def embed(request: EmbedRequest):
    """Generate embeddings for texts."""
    if len(request.texts) > config.MAX_BATCH_SIZE:
        raise HTTPException(
            status_code=400,
            detail=f"Maximum batch size is {config.MAX_BATCH_SIZE}"
        )

    state_incr('metrics:embed_requests')
    state_incr('metrics:embed_texts', len(request.texts))

    embeddings = []
    cached_count = 0

    for text in request.texts:
        if request.cache:
            # Use cached inference
            emb = cached_inference(
                model.encode,
                text,
                cache_prefix=config.CACHE_PREFIX
            )
            # Check if it was a cache hit
            if state_get(f'_cache_hit'):
                cached_count += 1
        else:
            emb = model.encode(text)

        embeddings.append(emb.tolist())

    return EmbedResponse(
        embeddings=embeddings,
        dimensions=len(embeddings[0]) if embeddings else 0,
        cached_count=cached_count
    )

@app.post("/embed/batch")
async def embed_batch(request: EmbedRequest):
    """Batch embed for better throughput (less caching)."""
    if len(request.texts) > config.MAX_BATCH_SIZE:
        raise HTTPException(status_code=400, detail="Batch too large")

    state_incr('metrics:batch_requests')

    # Batch encode is more efficient but doesn't use per-item cache
    embeddings = model.encode(request.texts)

    return {
        'embeddings': embeddings.tolist(),
        'dimensions': embeddings.shape[1]
    }

# ============================================================
# Index & Search
# ============================================================

@app.post("/index")
async def index_document(request: IndexRequest):
    """Index a document for search."""
    state_incr('metrics:index_requests')

    # Generate embedding
    embedding = cached_inference(model.encode, request.text)

    # Store document
    doc = {
        'id': request.id,
        'text': request.text,
        'embedding': embedding.tolist(),
        'metadata': request.metadata or {}
    }
    state_set(f'doc:{request.id}', doc)

    # Update index stats
    state_incr('index:doc_count')

    return {'indexed': request.id}

@app.delete("/index/{doc_id}")
async def delete_document(doc_id: str):
    """Remove document from index."""
    from hornbeam_erlang import state_delete

    if not state_get(f'doc:{doc_id}'):
        raise HTTPException(status_code=404, detail="Document not found")

    state_delete(f'doc:{doc_id}')
    state_incr('index:doc_count', -1)

    return {'deleted': doc_id}

@app.post("/search", response_model=list[SearchResult])
async def search(request: SearchRequest):
    """Semantic search across indexed documents."""
    state_incr('metrics:search_requests')

    # Get query embedding
    query_emb = cached_inference(model.encode, request.query)
    query_emb = np.array(query_emb)

    # Search all documents
    from hornbeam_erlang import state_keys

    results = []
    for key in state_keys('doc:'):
        doc = state_get(key)
        if not doc:
            continue

        doc_emb = np.array(doc['embedding'])

        # Cosine similarity
        similarity = np.dot(query_emb, doc_emb) / (
            np.linalg.norm(query_emb) * np.linalg.norm(doc_emb)
        )

        if similarity >= request.threshold:
            results.append(SearchResult(
                id=doc['id'],
                text=doc['text'],
                score=float(similarity),
                metadata=doc.get('metadata')
            ))

    # Sort by score
    results.sort(key=lambda x: x.score, reverse=True)

    return results[:request.top_k]

# ============================================================
# Stats & Health
# ============================================================

@app.get("/stats")
async def get_stats():
    """Get service statistics."""
    ml_cache = cache_stats()

    return {
        'model': config.MODEL_NAME,
        'index': {
            'documents': state_get('index:doc_count') or 0
        },
        'requests': {
            'embed': state_get('metrics:embed_requests') or 0,
            'batch': state_get('metrics:batch_requests') or 0,
            'search': state_get('metrics:search_requests') or 0,
            'index': state_get('metrics:index_requests') or 0
        },
        'cache': {
            'hits': ml_cache.get('hits', 0),
            'misses': ml_cache.get('misses', 0),
            'hit_rate': ml_cache.get('hit_rate', 0)
        }
    }

@app.get("/health")
async def health():
    return {
        'status': 'healthy',
        'model_loaded': model is not None
    }
```

## Running

```erlang
rebar3 shell

hornbeam:start("app:app", #{
    worker_class => asgi,
    lifespan => on,
    pythonpath => ["embedding_service"],
    workers => 4,
    timeout => 60000
}).
```

## Usage

```bash
# Index documents
curl -X POST http://localhost:8000/index \
  -H "Content-Type: application/json" \
  -d '{"id": "1", "text": "Python is a programming language", "metadata": {"category": "tech"}}'

curl -X POST http://localhost:8000/index \
  -H "Content-Type: application/json" \
  -d '{"id": "2", "text": "Erlang is great for concurrent systems"}'

curl -X POST http://localhost:8000/index \
  -H "Content-Type: application/json" \
  -d '{"id": "3", "text": "Machine learning uses neural networks"}'

# Search
curl -X POST http://localhost:8000/search \
  -H "Content-Type: application/json" \
  -d '{"query": "programming languages", "top_k": 5}'

# Direct embedding
curl -X POST http://localhost:8000/embed \
  -H "Content-Type: application/json" \
  -d '{"texts": ["Hello world", "How are you?"]}'

# Check stats
curl http://localhost:8000/stats
```

## Requirements

```
# requirements.txt
fastapi>=0.100
sentence-transformers>=2.0
numpy>=1.20
```

## Performance Tips

1. **Use batch endpoints** for bulk operations
2. **Enable caching** for repeated queries
3. **Increase workers** for more parallelism
4. **Use GPU** for faster inference (install torch with CUDA)

## Next Steps

- [Distributed ML](./distributed-ml) - Scale across cluster
- [ML Integration Guide](../guides/ml-integration) - More patterns
