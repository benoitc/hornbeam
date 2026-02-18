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
- [Installation & Quick Start](/docs/getting-started) - Get up and running
- [WSGI Guide](/docs/guides/wsgi) - Run Flask, Django, and WSGI apps
- [ASGI Guide](/docs/guides/asgi) - Run FastAPI, Starlette, and async apps

### Guides
- [Channels & Presence](/docs/guides/channels) - Real-time multiplexed channels
- [WebSocket Guide](/docs/guides/websocket) - Real-time bidirectional communication
- [Erlang Integration](/docs/guides/erlang-integration) - ETS, RPC, Pub/Sub
- [ML Integration](/docs/guides/ml-integration) - Caching, distributed inference

### Examples
- [Flask Application](/docs/examples/flask-app) - Traditional WSGI app
- [FastAPI Application](/docs/examples/fastapi-app) - Modern async API
- [Channels Chat](/docs/examples/channels-chat) - Channels and presence
- [WebSocket Chat](/docs/examples/websocket-chat) - Real-time chat
- [Embedding Service](/docs/examples/embedding-service) - ML with ETS caching
- [Distributed ML](/docs/examples/distributed-ml) - Cluster inference

### Reference
- [Configuration](/docs/reference/configuration) - All options
- [Erlang API](https://hexdocs.pm/hornbeam) - Erlang modules (hex.pm)
- [Python API](/docs/reference/python-api) - Python modules

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
