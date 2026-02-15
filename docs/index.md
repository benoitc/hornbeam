---
title: Hornbeam Documentation
description: WSGI/ASGI HTTP server powered by the BEAM
order: 0
---

# Hornbeam Documentation

Hornbeam is an HTTP server and application server that combines Python's web and AI capabilities with Erlang's infrastructure:

- **Python handles**: Web apps (WSGI/ASGI), ML models, data processing
- **Erlang handles**: Scaling, concurrency, distribution, fault tolerance, shared state

## Quick Links

### Getting Started
- [Installation & Quick Start](./getting-started) - Get up and running
- [WSGI Guide](./guides/wsgi) - Run Flask, Django, and WSGI apps
- [ASGI Guide](./guides/asgi) - Run FastAPI, Starlette, and async apps

### Guides
- [WebSocket Guide](./guides/websocket) - Real-time bidirectional communication
- [Erlang Integration](./guides/erlang-integration) - ETS, RPC, Pub/Sub
- [ML Integration](./guides/ml-integration) - Caching, distributed inference

### Examples
- [Flask Application](./examples/flask-app) - Traditional WSGI app
- [FastAPI Application](./examples/fastapi-app) - Modern async API
- [WebSocket Chat](./examples/websocket-chat) - Real-time chat
- [Embedding Service](./examples/embedding-service) - ML with ETS caching
- [Distributed ML](./examples/distributed-ml) - Cluster inference

### Reference
- [Configuration](./reference/configuration) - All options
- [Erlang API](./reference/erlang-api) - Erlang modules
- [Python API](./reference/python-api) - Python modules

## Why Hornbeam?

| Challenge | Traditional Python | Hornbeam |
|-----------|-------------------|----------|
| Concurrent connections | ~1000s (GIL) | Millions (BEAM) |
| Distributed computing | Redis/RabbitMQ | Built-in Erlang RPC |
| Shared state | External database | ETS (in-memory) |
| Hot reload | Restart server | Live code swap |
| Fault tolerance | Process crashes = down | Supervisor restarts |

## Erlang Python Integration

Hornbeam is built on [Erlang Python](https://hexdocs.pm/erlang_python), which provides:

- Bidirectional Erlang ↔ Python calls
- Sub-interpreters for true parallelism
- Free-threaded Python (3.13+) support
- Automatic type conversion
- Streaming from generators

See the [Erlang Python documentation](https://hexdocs.pm/erlang_python) for low-level Python integration details.
