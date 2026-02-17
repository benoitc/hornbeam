# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-02-17

### Added

- **uvloop Integration**: Install uvloop as default event loop policy per worker for improved async performance
- **ASGI Benchmarks**: Added ASGI benchmark suite and optimized request handling

### Changed

- Moved Benchmarking to bottom of Guides section in documentation

### Fixed

- Fixed syntax highlighting contrast in documentation

## [1.0.0] - 2026-02-17

### Added

- **WSGI Support**: Full PEP 3333 compliance for running Python WSGI applications
  - Complete environ dict with all required and recommended variables
  - `wsgi.file_wrapper` for efficient file serving
  - `wsgi.early_hints` for 103 Early Hints responses
  - `wsgi.errors` routing to Erlang logging

- **ASGI Support**: Full ASGI 3.0 protocol implementation
  - HTTP scope with streaming responses
  - WebSocket scope with RFC 6455 support
  - Lifespan protocol with `hornbeam_lifespan` gen_server
  - `lifespan_timeout` configuration for startup/shutdown timeout
  - Python context affinity for module state persistence
  - Informational responses (1xx)

- **HTTP Features** (via Cowboy)
  - HTTP/1.1 with keep-alive and chunked encoding
  - HTTP/2 with multiplexing
  - TLS/SSL support
  - WebSocket with binary and text frames

- **Erlang Integration**
  - Shared state via ETS (`hornbeam_state` module)
  - Distributed RPC to remote nodes (`hornbeam_dist` module)
  - Pub/Sub messaging via pg (`hornbeam_pubsub` module)
  - Registered Erlang functions callable from Python (`hornbeam_callbacks` module)

- **Hooks System**
  - `on_request` - Modify requests before handling
  - `on_response` - Modify responses before sending
  - `on_error` - Custom error handling
  - `on_worker_start` / `on_worker_exit` - Worker lifecycle hooks

- **ML Integration**
  - `hornbeam_ml` Python module for cached inference
  - ETS-backed caching with hit/miss statistics
  - Support for distributed ML across Erlang cluster

- **Python Modules**
  - `hornbeam_erlang` - State, RPC, Pub/Sub, and callback APIs
  - `hornbeam_ml` - ML caching helpers
  - `hornbeam_wsgi_runner` - WSGI request handling
  - `hornbeam_asgi_runner` - ASGI request handling
  - `hornbeam_websocket_runner` - WebSocket session handling
  - `hornbeam_lifespan_runner` - Lifespan protocol handling

- **Configuration**
  - Server binding, SSL/TLS options
  - Worker pool sizing and timeouts
  - ASGI lifespan control
  - WebSocket timeout and frame size limits
  - Python path and virtual environment support

- **Demo Examples**
  - ML Caching: OTP application with hook-based architecture
  - Distributed RPC: 3-node Erlang cluster with Docker Compose
  - Real-time Chat: WebSocket with Erlang pub/sub
  - Docker support for all demo applications

- **Documentation**
  - Getting started guide
  - WSGI, ASGI, WebSocket guides
  - Erlang integration guide
  - ML integration guide
  - Flask, FastAPI, WebSocket chat examples
  - Embedding service and distributed ML examples
  - Configuration reference
  - Benchmarking guide

- **Website**
  - https://hornbeam.dev
  - Product pages for Hornbeam and Erlang Python
  - Integrated documentation with product switcher

### Dependencies

- Erlang/OTP 27+
- Python 3.12+ (3.13+ recommended for free-threading)
- Cowboy 2.12.0
- erlang_python 1.3.2

[1.1.0]: https://github.com/benoitc/hornbeam/releases/tag/v1.1.0
[1.0.0]: https://github.com/benoitc/hornbeam/releases/tag/v1.0.0
