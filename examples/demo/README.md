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

The ml_caching demo is a full OTP application that demonstrates:
- Loading a Python ML model from Erlang via erlang_python
- Registering Erlang hooks that route through to the Python model
- Running FastAPI via Hornbeam with hook-based architecture

```bash
cd ml_caching

# Install Python dependencies
pip install -r requirements.txt

# Build and run as OTP release
rebar3 release
_build/default/rel/ml_caching/bin/ml_caching foreground
```

Or with Docker:
```bash
# From hornbeam root directory
docker build -f examples/demo/Dockerfile.demo \
    --build-arg EXAMPLE=ml_caching \
    -t ml_caching_demo .

docker run -p 8000:8000 ml_caching_demo
```

Test:
```bash
# Health check
curl http://localhost:8000/health

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

The distributed_rpc demo shows Erlang clustering with work distributed across nodes.

**With Docker (3-node cluster):**
```bash
cd distributed_rpc
docker-compose up --build
```

Test:
```bash
# View cluster (3 nodes)
curl http://localhost:8002/cluster

# Distribute inference across nodes
curl -X POST http://localhost:8002/infer \
     -H "Content-Type: application/json" \
     -d '{"prompts": ["Hello", "World", "Test"]}'
```

**Manual setup:**
```bash
# Terminal 1 - Main node
rebar3 shell --sname main
hornbeam:start("app:app", #{
    worker_class => asgi,
    pythonpath => ["examples/demo/distributed_rpc"]
}).

# Terminal 2 - Worker node
rebar3 shell --sname worker
net_adm:ping('main@yourhostname').
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
- **Erlang**: OTP app loads ML model via erlang_python, registers hooks
- **Python**: FastAPI calls `hornbeam.hooks.execute("embeddings", ...)` which routes to Erlang
- **Architecture**: Model initialization happens once in Erlang's supervision tree
- **Benefit**: ~0.1ms cached vs ~45ms inference, model survives worker restarts

### Distributed RPC
- **Python**: Fan-out work to cluster nodes
- **Erlang**: Node discovery, load balancing, failover
- **Benefit**: No Redis, no RabbitMQ - just Erlang distribution

### Real-time Chat
- **Python**: FastAPI WebSocket handler
- **Erlang**: pg process groups for pub/sub
- **Benefit**: Messages reach all nodes automatically, millions of connections
