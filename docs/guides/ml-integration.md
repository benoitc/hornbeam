---
title: ML Integration
description: Caching, distributed inference, and AI patterns
order: 14
---

# ML Integration

Hornbeam makes Python ML/AI workloads production-ready with ETS caching, distributed inference, and Erlang's fault tolerance.

## Cached Inference

Use ETS to cache ML inference results:

```python
from hornbeam_ml import cached_inference, cache_stats

# Load model at startup
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('all-MiniLM-L6-v2')

def get_embedding(text):
    # Automatically cached by input hash
    return cached_inference(model.encode, text)

# Check cache performance
stats = cache_stats()
# {'hits': 1000, 'misses': 100, 'hit_rate': 0.91}
```

### Custom Cache Keys

```python
from hornbeam_ml import cached_inference

def get_embedding(text, model_name='default'):
    # Custom cache key includes model name
    return cached_inference(
        model.encode,
        text,
        cache_key=f'{model_name}:{hash(text)}',
        cache_prefix='embedding'
    )
```

### Cache with TTL

```python
from hornbeam_erlang import state_get, state_set
import hashlib
import time

def cached_with_ttl(fn, input, ttl_seconds=3600):
    """Cache result with time-to-live."""
    key = f'cache:{hashlib.md5(str(input).encode()).hexdigest()}'

    cached = state_get(key)
    if cached:
        if time.time() - cached['timestamp'] < ttl_seconds:
            return cached['result']

    result = fn(input)
    state_set(key, {
        'result': result,
        'timestamp': time.time()
    })
    return result
```

## Embedding Service

Complete embedding service with caching:

```python
# embedding_service.py
from fastapi import FastAPI
from pydantic import BaseModel
from hornbeam_ml import cached_inference, cache_stats
from hornbeam_erlang import state_incr
from sentence_transformers import SentenceTransformer
import numpy as np

app = FastAPI()
model = None

@app.on_event("startup")
async def load_model():
    global model
    model = SentenceTransformer('all-MiniLM-L6-v2')

class EmbedRequest(BaseModel):
    texts: list[str]

class EmbedResponse(BaseModel):
    embeddings: list[list[float]]
    cache_hits: int
    cache_misses: int

@app.post("/embed", response_model=EmbedResponse)
async def embed(request: EmbedRequest):
    state_incr('metrics:embed_requests')

    embeddings = []
    for text in request.texts:
        emb = cached_inference(model.encode, text)
        embeddings.append(emb.tolist())

    stats = cache_stats()
    return EmbedResponse(
        embeddings=embeddings,
        cache_hits=stats['hits'],
        cache_misses=stats['misses']
    )

@app.get("/stats")
async def get_stats():
    return cache_stats()
```

```erlang
hornbeam:start("embedding_service:app", #{
    worker_class => asgi,
    lifespan => on,
    workers => 4
}).
```

## Semantic Search

Build semantic search with ETS-cached embeddings:

```python
from hornbeam_erlang import state_get, state_set, state_keys
from hornbeam_ml import cached_inference
import numpy as np

def index_document(doc_id, text):
    """Index a document for semantic search."""
    embedding = cached_inference(model.encode, text)
    state_set(f'doc:{doc_id}', {
        'text': text,
        'embedding': embedding.tolist()
    })

def search(query, top_k=10):
    """Search documents by semantic similarity."""
    query_emb = cached_inference(model.encode, query)
    query_emb = np.array(query_emb)

    # Get all documents
    doc_keys = state_keys('doc:')
    results = []

    for key in doc_keys:
        doc = state_get(key)
        if doc:
            doc_emb = np.array(doc['embedding'])
            similarity = cosine_similarity(query_emb, doc_emb)
            results.append({
                'id': key.replace('doc:', ''),
                'text': doc['text'],
                'score': float(similarity)
            })

    # Sort by similarity
    results.sort(key=lambda x: x['score'], reverse=True)
    return results[:top_k]

def cosine_similarity(a, b):
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))
```

## Distributed Inference

Spread ML workloads across a cluster:

```python
from hornbeam_erlang import rpc_call, nodes
import asyncio

class DistributedInference:
    def __init__(self, node_filter='gpu'):
        self.node_filter = node_filter

    def get_worker_nodes(self):
        """Get available GPU nodes."""
        return [n for n in nodes() if self.node_filter in n]

    async def predict_batch(self, inputs):
        """Distribute predictions across nodes."""
        worker_nodes = self.get_worker_nodes()

        if not worker_nodes:
            # No GPU nodes, run locally
            return self.local_predict(inputs)

        # Split inputs across workers
        chunks = self.split_inputs(inputs, len(worker_nodes))
        results = []

        for node, chunk in zip(worker_nodes, chunks):
            try:
                result = rpc_call(
                    node,
                    'ml_worker',
                    'predict',
                    [chunk],
                    timeout_ms=60000
                )
                results.extend(result)
            except Exception as e:
                # Fallback to local on failure
                results.extend(self.local_predict(chunk))

        return results

    def split_inputs(self, inputs, n):
        """Split list into n roughly equal chunks."""
        k, m = divmod(len(inputs), n)
        return [inputs[i*k+min(i,m):(i+1)*k+min(i+1,m)] for i in range(n)]

    def local_predict(self, inputs):
        return model.predict(inputs)
```

### GPU Node Setup

On each GPU node:

```erlang
%% gpu_node.erl
-module(ml_worker).
-export([predict/1, encode/1]).

predict(Inputs) ->
    py:call('model', 'predict', [Inputs]).

encode(Texts) ->
    py:call('model', 'encode', [Texts]).
```

## LLM Integration

Integrate with LLM APIs:

```python
from hornbeam_erlang import state_get, state_set
import hashlib
import openai

def cached_llm_call(prompt, model="gpt-4", temperature=0):
    """Cache LLM responses for identical prompts."""
    # Only cache deterministic (temp=0) responses
    if temperature == 0:
        cache_key = f'llm:{model}:{hashlib.md5(prompt.encode()).hexdigest()}'
        cached = state_get(cache_key)
        if cached:
            return cached

    response = openai.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        temperature=temperature
    )

    result = response.choices[0].message.content

    if temperature == 0:
        state_set(cache_key, result)

    return result
```

### Streaming LLM Responses

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
import openai

app = FastAPI()

async def stream_llm(prompt):
    stream = openai.chat.completions.create(
        model="gpt-4",
        messages=[{"role": "user", "content": prompt}],
        stream=True
    )

    for chunk in stream:
        if chunk.choices[0].delta.content:
            yield f"data: {chunk.choices[0].delta.content}\n\n"

    yield "data: [DONE]\n\n"

@app.post("/chat/stream")
async def chat_stream(prompt: str):
    return StreamingResponse(
        stream_llm(prompt),
        media_type="text/event-stream"
    )
```

## RAG (Retrieval-Augmented Generation)

Combine semantic search with LLM:

```python
from hornbeam_ml import cached_inference
from hornbeam_erlang import state_get, state_keys
import openai

def rag_query(question, top_k=5):
    """Answer question using retrieved context."""

    # 1. Retrieve relevant documents
    docs = search(question, top_k=top_k)

    # 2. Build context
    context = "\n\n".join([
        f"Document {i+1}:\n{doc['text']}"
        for i, doc in enumerate(docs)
    ])

    # 3. Generate answer with LLM
    prompt = f"""Answer the question based on the following context.

Context:
{context}

Question: {question}

Answer:"""

    response = openai.chat.completions.create(
        model="gpt-4",
        messages=[{"role": "user", "content": prompt}]
    )

    return {
        'answer': response.choices[0].message.content,
        'sources': [doc['id'] for doc in docs]
    }
```

## Model Loading with Lifespan

Load models at startup, not per-request:

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI

models = {}

@asynccontextmanager
async def lifespan(app):
    # Startup: Load all models
    models['embedding'] = SentenceTransformer('all-MiniLM-L6-v2')
    models['classifier'] = load_classifier('model.pkl')
    print("Models loaded!")

    yield

    # Shutdown: Cleanup
    models.clear()

app = FastAPI(lifespan=lifespan)

@app.post("/embed")
async def embed(text: str):
    return models['embedding'].encode(text).tolist()
```

## Batch Processing

Efficient batch processing with BEAM parallelism:

```python
from hornbeam_erlang import rpc_call
import concurrent.futures

def process_batch(items, batch_size=100):
    """Process items in parallel batches."""
    results = []

    # Split into batches
    batches = [items[i:i+batch_size] for i in range(0, len(items), batch_size)]

    # Process batches in parallel using Erlang processes
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = [
            executor.submit(process_single_batch, batch)
            for batch in batches
        ]

        for future in concurrent.futures.as_completed(futures):
            results.extend(future.result())

    return results

def process_single_batch(batch):
    # This runs in a separate BEAM process
    embeddings = model.encode(batch)
    return embeddings.tolist()
```

## Monitoring ML Performance

```python
from hornbeam_erlang import state_incr, state_get
import time

class MLMetrics:
    @staticmethod
    def track_inference(model_name, latency_ms):
        state_incr(f'ml:{model_name}:calls')
        state_incr(f'ml:{model_name}:latency_total', int(latency_ms))

        # Track latency buckets
        bucket = (latency_ms // 100) * 100
        state_incr(f'ml:{model_name}:latency:{bucket}')

    @staticmethod
    def get_stats(model_name):
        calls = state_get(f'ml:{model_name}:calls') or 0
        latency_total = state_get(f'ml:{model_name}:latency_total') or 0

        return {
            'calls': calls,
            'avg_latency_ms': latency_total / calls if calls > 0 else 0
        }

# Usage
def timed_inference(model, input):
    start = time.time()
    result = model.predict(input)
    latency = (time.time() - start) * 1000
    MLMetrics.track_inference('classifier', latency)
    return result
```

## Next Steps

- [Embedding Service Example](../examples/embedding-service) - Complete service
- [Distributed ML Example](../examples/distributed-ml) - Cluster setup
- [Erlang Python AI Guide](https://hexdocs.pm/erlang_python/ai-integration.html) - Low-level AI integration
