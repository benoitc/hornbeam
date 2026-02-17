# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0

"""ML Caching Demo - FastAPI Web App.

This FastAPI app is started by Hornbeam and uses Erlang hooks for embeddings.
The hook "embeddings" is registered by the ml_caching_embedder Erlang process,
which routes calls to the Python EmbeddingApp.

Architecture:
1. ml_caching_app starts the OTP application
2. ml_caching_embedder GenServer:
   - Initializes Python EmbeddingApp via py:call()
   - Registers "embeddings" hook in Erlang
3. Hornbeam starts this FastAPI app
4. FastAPI calls execute("embeddings", "embed", ...) which routes through Erlang

Run as part of ml_caching OTP app:
    rebar3 shell
    > ml_caching_app:start().
    > hornbeam:start("app:app", #{worker_class => asgi}).

Test:
    curl -X POST http://localhost:8000/embed \
         -H "Content-Type: application/json" \
         -d '{"text": "Hello world"}'
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import hashlib
import time

# Import hornbeam Erlang integration
try:
    from hornbeam_erlang import execute, state_get, state_set, state_incr
    USING_ERLANG = True
except ImportError:
    USING_ERLANG = False

    def execute(app_path, action, *args, **kwargs):
        raise RuntimeError("Erlang not available - run under hornbeam")

    def state_get(key):
        return None

    def state_set(key, value):
        pass

    def state_incr(key, delta=1):
        return 0


app = FastAPI(
    title="ML Caching Demo",
    description="Embedding service with Erlang hooks and ETS caching"
)


class EmbedRequest(BaseModel):
    text: str


class EmbedResponse(BaseModel):
    embedding: list[float]
    cached: bool
    latency_ms: float


class SimilarityRequest(BaseModel):
    text1: str
    text2: str


class SimilarityResponse(BaseModel):
    similarity: float
    latency_ms: float


class MetricsResponse(BaseModel):
    cache_hits: int
    cache_misses: int
    total_requests: int
    hit_rate: float
    using_erlang: bool


@app.post("/embed", response_model=EmbedResponse)
async def embed(request: EmbedRequest):
    """Generate embedding with ETS cache.

    First request computes embedding (~45ms).
    Subsequent requests return cached value (~0.1ms).
    """
    if not USING_ERLANG:
        raise HTTPException(status_code=503, detail="Erlang not available")

    start = time.perf_counter()

    # Check ETS cache first
    cache_key = f"embed:{hashlib.md5(request.text.encode()).hexdigest()}"
    cached_embedding = state_get(cache_key)

    if cached_embedding is not None:
        # Cache hit
        state_incr("cache_hits")
        latency = (time.perf_counter() - start) * 1000
        return EmbedResponse(
            embedding=cached_embedding,
            cached=True,
            latency_ms=round(latency, 2)
        )

    # Cache miss - compute embedding via hook
    # This calls the Erlang hook registered by ml_caching_embedder
    try:
        embeddings = execute("embeddings", "embed", [request.text])
        embedding = embeddings[0]  # Single text, single embedding
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    # Store in cache
    state_set(cache_key, embedding)
    state_incr("cache_misses")

    latency = (time.perf_counter() - start) * 1000
    return EmbedResponse(
        embedding=embedding,
        cached=False,
        latency_ms=round(latency, 2)
    )


@app.post("/similarity", response_model=SimilarityResponse)
async def similarity(request: SimilarityRequest):
    """Compute cosine similarity between two texts."""
    if not USING_ERLANG:
        raise HTTPException(status_code=503, detail="Erlang not available")

    start = time.perf_counter()

    try:
        sim = execute("embeddings", "similarity", request.text1, request.text2)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    latency = (time.perf_counter() - start) * 1000
    return SimilarityResponse(
        similarity=round(sim, 4),
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


@app.get("/health")
async def health():
    """Health check."""
    return {
        "status": "healthy" if USING_ERLANG else "degraded",
        "using_erlang": USING_ERLANG
    }


@app.get("/")
async def root():
    """Service info."""
    return {
        "service": "ML Caching Demo",
        "description": "Embedding service with Erlang hooks and ETS caching",
        "endpoints": {
            "POST /embed": "Generate embedding (with caching)",
            "POST /similarity": "Compute text similarity",
            "GET /metrics": "View cache statistics",
            "GET /health": "Health check"
        },
        "using_erlang": USING_ERLANG
    }
