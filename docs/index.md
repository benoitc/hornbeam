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
- [Installation & Quick Start](./getting-started.md) - Get up and running
- [WSGI Guide](./guides/wsgi.md) - Run Flask, Django, and WSGI apps
- [ASGI Guide](./guides/asgi.md) - Run FastAPI, Starlette, and async apps

### Guides
- [WebSocket Guide](./guides/websocket.md) - Real-time bidirectional communication
- [Erlang Integration](./guides/erlang-integration.md) - ETS, RPC, Pub/Sub
- [ML Integration](./guides/ml-integration.md) - Caching, distributed inference

### Examples
- [Flask Application](./examples/flask-app.md) - Traditional WSGI app
- [FastAPI Application](./examples/fastapi-app.md) - Modern async API
- [WebSocket Chat](./examples/websocket-chat.md) - Real-time chat
- [Embedding Service](./examples/embedding-service.md) - ML with ETS caching
- [Distributed ML](./examples/distributed-ml.md) - Cluster inference

### Reference
- [Configuration](./reference/configuration.md) - All options
- [Erlang API](https://hexdocs.pm/hornbeam) - Erlang modules (hex.pm)
- [Python API](./reference/python-api.md) - Python modules

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
