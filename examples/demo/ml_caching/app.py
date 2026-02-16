# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0

"""ML Caching Demo - FastAPI + Erlang ETS.

This example demonstrates using Erlang ETS for caching ML embeddings.
When running under Hornbeam, cache survives Python crashes and is
shared across all workers.

Run standalone:
    cd examples/demo/ml_caching
    pip install -r requirements.txt
    uvicorn app:app --reload

Run with Hornbeam:
    hornbeam:start("app:app", #{
        worker_class => asgi,
        pythonpath => ["examples/demo/ml_caching"]
    }).

Test:
    curl -X POST http://localhost:8000/embed \
         -H "Content-Type: application/json" \
         -d '{"text": "Hello world"}'
"""

from fastapi import FastAPI
from pydantic import BaseModel
import hashlib
import time

# Import hornbeam Erlang integration (with fallback for standalone)
_cache = {}
_counters = {}
USING_ERLANG = False

try:
    from hornbeam_erlang import state_get as _erl_state_get
    from hornbeam_erlang import state_set as _erl_state_set
    from hornbeam_erlang import state_incr as _erl_state_incr
    # Test that Erlang calls actually work
    _erl_state_incr("_test_connection", 0)
    USING_ERLANG = True

    def state_get(key):
        return _erl_state_get(key)

    def state_set(key, value, ttl=None):
        _erl_state_set(key, value)

    def state_incr(key, delta=1):
        return _erl_state_incr(key, delta)

except Exception:
    # Fallback: in-memory cache for standalone testing
    USING_ERLANG = False

    def state_get(key):
        return _cache.get(key)

    def state_set(key, value, ttl=None):
        _cache[key] = value

    def state_incr(key, delta=1):
        _counters[key] = _counters.get(key, 0) + delta
        return _counters[key]


app = FastAPI(
    title="ML Caching Demo",
    description="Embedding service with Erlang ETS caching"
)

# Lazy-loaded model
_model = None


def get_model():
    """Lazy load the sentence transformer model."""
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer('all-MiniLM-L6-v2')
    return _model


class EmbedRequest(BaseModel):
    text: str


class EmbedResponse(BaseModel):
    embedding: list[float]
    cached: bool = False
    latency_ms: float


class MetricsResponse(BaseModel):
    cache_hits: int
    cache_misses: int
    total_requests: int
    hit_rate: float
    using_erlang: bool


@app.post("/embed", response_model=EmbedResponse)
async def embed(request: EmbedRequest):
    """Generate embedding with Erlang ETS cache.

    First request computes embedding (~45ms).
    Subsequent requests return cached value (~0.1ms).
    """
    start = time.perf_counter()

    # Create cache key from text hash
    cache_key = f"embed:{hashlib.md5(request.text.encode()).hexdigest()}"

    # Check Erlang ETS cache first
    cached = state_get(cache_key)
    if cached:
        state_incr("cache_hits")
        latency = (time.perf_counter() - start) * 1000
        return EmbedResponse(
            embedding=cached,
            cached=True,
            latency_ms=round(latency, 2)
        )

    # Compute embedding
    embedding = get_model().encode(request.text).tolist()

    # Store in Erlang ETS cache
    state_set(cache_key, embedding, ttl=3600)
    state_incr("cache_misses")

    latency = (time.perf_counter() - start) * 1000
    return EmbedResponse(
        embedding=embedding,
        cached=False,
        latency_ms=round(latency, 2)
    )


@app.get("/metrics", response_model=MetricsResponse)
async def metrics():
    """Get cache metrics from Erlang shared state."""
    hits = state_get("cache_hits") or 0
    misses = state_get("cache_misses") or 0
    total = hits + misses

    return MetricsResponse(
        cache_hits=hits,
        cache_misses=misses,
        total_requests=total,
        hit_rate=round(hits / total, 3) if total > 0 else 0.0,
        using_erlang=USING_ERLANG
    )


@app.get("/")
async def root():
    """Service info."""
    return {
        "service": "ML Caching Demo",
        "endpoints": {
            "POST /embed": "Generate embedding (with caching)",
            "GET /metrics": "View cache statistics"
        },
        "using_erlang": USING_ERLANG
    }
