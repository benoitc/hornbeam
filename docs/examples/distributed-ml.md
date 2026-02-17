---
title: Distributed ML
description: Distribute ML inference across an Erlang cluster
order: 24
---

# Distributed ML Example

This example shows how to distribute ML inference across multiple Erlang nodes, leveraging the BEAM's built-in clustering.

## Architecture

```
                    ┌─────────────────┐
                    │   Web Server    │
                    │  (Hornbeam)     │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
       ┌──────▼─────┐ ┌──────▼─────┐ ┌──────▼─────┐
       │  GPU Node  │ │  GPU Node  │ │  GPU Node  │
       │  worker1@  │ │  worker2@  │ │  worker3@  │
       └────────────┘ └────────────┘ └────────────┘
```

## Web Server (Hornbeam)

```python
# app.py
from fastapi import FastAPI
from pydantic import BaseModel
from hornbeam_erlang import rpc_call, nodes, node
from hornbeam_ml import cached_inference
import asyncio
from typing import Optional

app = FastAPI()

# ============================================================
# Models
# ============================================================

class InferenceRequest(BaseModel):
    texts: list[str]
    model: str = "default"

class InferenceResponse(BaseModel):
    embeddings: list[list[float]]
    node: str
    cached: int

# ============================================================
# Distributed Inference
# ============================================================

def get_gpu_nodes():
    """Get available GPU worker nodes."""
    return [n for n in nodes() if n.startswith('gpu') or n.startswith('worker')]

def select_node(nodes_list):
    """Select node with least load (round-robin for simplicity)."""
    if not nodes_list:
        return None
    # Simple round-robin
    from hornbeam_erlang import state_incr
    idx = state_incr('node_selector') % len(nodes_list)
    return nodes_list[idx]

@app.post("/infer", response_model=InferenceResponse)
async def distributed_inference(request: InferenceRequest):
    """Run inference on a GPU node."""
    gpu_nodes = get_gpu_nodes()

    if not gpu_nodes:
        # Fallback to local inference
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer('all-MiniLM-L6-v2')
        embeddings = model.encode(request.texts)
        return InferenceResponse(
            embeddings=embeddings.tolist(),
            node=node(),
            cached=0
        )

    # Select a GPU node
    target_node = select_node(gpu_nodes)

    # Call remote node
    result = rpc_call(
        target_node,
        'ml_worker',
        'encode',
        [request.texts, request.model],
        timeout_ms=60000
    )

    return InferenceResponse(
        embeddings=result['embeddings'],
        node=target_node,
        cached=result.get('cached', 0)
    )

@app.post("/infer/parallel")
async def parallel_inference(request: InferenceRequest):
    """Distribute across all GPU nodes in parallel."""
    gpu_nodes = get_gpu_nodes()

    if not gpu_nodes:
        raise HTTPException(status_code=503, detail="No GPU nodes available")

    # Split texts across nodes
    n_nodes = len(gpu_nodes)
    chunk_size = (len(request.texts) + n_nodes - 1) // n_nodes
    chunks = [
        request.texts[i:i + chunk_size]
        for i in range(0, len(request.texts), chunk_size)
    ]

    # Call all nodes in parallel
    import concurrent.futures

    def call_node(node, texts):
        return rpc_call(
            node,
            'ml_worker',
            'encode',
            [texts, request.model],
            timeout_ms=60000
        )

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=n_nodes) as executor:
        futures = {
            executor.submit(call_node, node, chunk): node
            for node, chunk in zip(gpu_nodes, chunks)
            if chunk
        }

        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.extend(result['embeddings'])

    return {
        'embeddings': results,
        'nodes_used': len(gpu_nodes)
    }

# ============================================================
# Cluster Status
# ============================================================

@app.get("/cluster")
async def cluster_status():
    """Get cluster status."""
    gpu_nodes = get_gpu_nodes()

    status = {
        'this_node': node(),
        'gpu_nodes': [],
        'total_nodes': len(nodes())
    }

    for gpu_node in gpu_nodes:
        try:
            info = rpc_call(gpu_node, 'ml_worker', 'info', [], timeout_ms=5000)
            status['gpu_nodes'].append({
                'node': gpu_node,
                'status': 'online',
                **info
            })
        except Exception as e:
            status['gpu_nodes'].append({
                'node': gpu_node,
                'status': 'offline',
                'error': str(e)
            })

    return status
```

## GPU Worker Node

### Erlang Module

```erlang
%% ml_worker.erl
-module(ml_worker).
-export([encode/2, info/0, predict/2]).

encode(Texts, Model) ->
    %% Call Python with caching
    Result = py:call('ml_service', 'encode', [Texts, Model]),
    Result.

predict(Input, Model) ->
    py:call('ml_service', 'predict', [Input, Model]).

info() ->
    #{
        model => py:call('ml_service', 'get_model_info', []),
        memory => py:memory_stats(),
        cache => py:call('ml_service', 'cache_stats', [])
    }.
```

### Python Service

```python
# ml_service.py
from sentence_transformers import SentenceTransformer
from hornbeam_ml import cached_inference, cache_stats as get_cache_stats
from hornbeam_erlang import state_get, state_set

# Load model at import
models = {}

def get_model(name='default'):
    if name not in models:
        model_map = {
            'default': 'all-MiniLM-L6-v2',
            'large': 'all-mpnet-base-v2',
            'multilingual': 'paraphrase-multilingual-MiniLM-L12-v2'
        }
        model_name = model_map.get(name, name)
        models[name] = SentenceTransformer(model_name)
    return models[name]

def encode(texts, model_name='default'):
    """Encode texts with caching."""
    model = get_model(model_name)

    embeddings = []
    cached_count = 0

    for text in texts:
        cache_key = f'{model_name}:{hash(text)}'
        cached = state_get(f'emb:{cache_key}')

        if cached:
            embeddings.append(cached)
            cached_count += 1
        else:
            emb = model.encode(text).tolist()
            state_set(f'emb:{cache_key}', emb)
            embeddings.append(emb)

    return {
        'embeddings': embeddings,
        'cached': cached_count
    }

def predict(input_data, model_name='default'):
    """Run prediction."""
    model = get_model(model_name)
    return model.encode(input_data).tolist()

def get_model_info():
    """Get loaded model info."""
    return {
        'loaded_models': list(models.keys()),
        'default_dimensions': get_model().get_sentence_embedding_dimension()
    }

def cache_stats():
    return get_cache_stats()
```

## Starting the Cluster

### Start GPU Worker Nodes

```bash
# On gpu-server-1
erl -name worker1@gpu-server-1 -setcookie mysecret

# In the shell
application:ensure_all_started(erlang_python).
```

### Start Web Server

```bash
# On web-server
erl -name web@web-server -setcookie mysecret

# Connect to GPU nodes
net_adm:ping('worker1@gpu-server-1').
net_adm:ping('worker2@gpu-server-2').

# Start Hornbeam
hornbeam:start("app:app", #{
    worker_class => asgi,
    pythonpath => ["distributed_ml"]
}).
```

## Load Balancing Strategies

### 1. Round-Robin (Simple)

```python
def select_node_round_robin(nodes_list):
    idx = state_incr('node_rr') % len(nodes_list)
    return nodes_list[idx]
```

### 2. Least Loaded

```python
def select_node_least_loaded(nodes_list):
    loads = []
    for n in nodes_list:
        try:
            load = rpc_call(n, 'ml_worker', 'get_load', [], timeout_ms=1000)
            loads.append((n, load))
        except:
            loads.append((n, float('inf')))

    return min(loads, key=lambda x: x[1])[0]
```

### 3. Consistent Hashing (for caching)

```python
import hashlib

def select_node_consistent(nodes_list, key):
    """Select node based on key hash for cache locality."""
    hash_val = int(hashlib.md5(key.encode()).hexdigest(), 16)
    idx = hash_val % len(nodes_list)
    return sorted(nodes_list)[idx]
```

## Fault Tolerance

```python
async def resilient_inference(texts, retries=2):
    """Inference with automatic failover."""
    gpu_nodes = get_gpu_nodes()

    for attempt in range(retries + 1):
        if not gpu_nodes:
            break

        target = select_node(gpu_nodes)

        try:
            result = rpc_call(
                target,
                'ml_worker',
                'encode',
                [texts, 'default'],
                timeout_ms=30000
            )
            return result
        except Exception as e:
            print(f"Node {target} failed: {e}")
            gpu_nodes.remove(target)

    # All nodes failed, try local
    return local_inference(texts)
```

## Monitoring

```python
@app.get("/metrics")
async def metrics():
    """Cluster-wide metrics."""
    from hornbeam_erlang import state_get

    return {
        'requests': {
            'total': state_get('metrics:requests') or 0,
            'distributed': state_get('metrics:distributed') or 0,
            'local_fallback': state_get('metrics:local') or 0
        },
        'cluster': {
            'nodes': len(get_gpu_nodes()),
            'node_selector_count': state_get('node_selector') or 0
        }
    }
```

## Next Steps

- [ML Integration Guide](../guides/ml-integration.md) - Caching patterns
- [Erlang Integration Guide](../guides/erlang-integration.md) - RPC details
