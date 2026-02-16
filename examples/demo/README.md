# Hornbeam Demo Examples

These examples demonstrate the key features shown on the [Hornbeam homepage](https://hornbeam.dev):

1. **ML Caching** - FastAPI with Erlang ETS caching for embeddings
2. **Distributed RPC** - Fan-out work across Erlang cluster nodes
3. **Real-time Chat** - WebSocket with Erlang pub/sub

## Quick Start with Docker

```bash
# Build and run all examples
docker-compose up --build

# Or run individual examples
docker-compose up ml-caching       # http://localhost:9001
docker-compose up distributed-rpc  # http://localhost:9002
docker-compose up realtime-chat    # http://localhost:9003
```

## Running Locally with Hornbeam

### Prerequisites

- Erlang/OTP 26+
- Python 3.11+
- rebar3

### ML Caching Example

```bash
# Install Python dependencies
pip install -r ml_caching/requirements.txt

# Start Hornbeam
cd /path/to/hornbeam
rebar3 shell

# In the Erlang shell:
hornbeam:start("app:app", #{
    worker_class => asgi,
    pythonpath => ["examples/demo/ml_caching"]
}).
```

Test:
```bash
# First request - computes embedding
curl -X POST http://localhost:8000/embed \
     -H "Content-Type: application/json" \
     -d '{"text": "Hello world"}'

# Second request - returns cached (much faster)
curl -X POST http://localhost:8000/embed \
     -H "Content-Type: application/json" \
     -d '{"text": "Hello world"}'

# View cache metrics
curl http://localhost:8000/metrics
```

### Distributed RPC Example

```bash
# Terminal 1 - Main node
cd /path/to/hornbeam
rebar3 shell --sname main

hornbeam:start("app:app", #{
    worker_class => asgi,
    pythonpath => ["examples/demo/distributed_rpc"]
}).

# Terminal 2 - Worker node
rebar3 shell --sname worker
net_adm:ping('main@yourhostname').
```

Test:
```bash
# View cluster status
curl http://localhost:8000/cluster

# Distribute inference
curl -X POST http://localhost:8000/infer \
     -H "Content-Type: application/json" \
     -d '{"prompts": ["Hello", "World", "Test"]}'
```

### Real-time Chat Example

```bash
# Start Hornbeam
rebar3 shell

hornbeam:start("app:app", #{
    worker_class => asgi,
    pythonpath => ["examples/demo/realtime_chat"]
}).
```

Test:
- Open http://localhost:8000 in multiple browser tabs
- Messages broadcast to all connected clients
- For cluster setup, start multiple nodes and connect them

## What These Examples Demonstrate

### ML Caching
- **Python**: FastAPI endpoint that generates embeddings
- **Erlang**: ETS caching with TTL, cache survives Python crashes
- **Benefit**: ~0.1ms cached vs ~45ms inference

### Distributed RPC
- **Python**: Fan-out work to cluster nodes
- **Erlang**: Node discovery, load balancing, failover
- **Benefit**: No Redis, no RabbitMQ - just Erlang distribution

### Real-time Chat
- **Python**: FastAPI WebSocket handler
- **Erlang**: pg process groups for pub/sub
- **Benefit**: Messages reach all nodes automatically, millions of connections
