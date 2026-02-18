# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.1] - 2026-02-18

### Added

- **SSL/TLS Support**: Full SSL/TLS configuration now working
  - `ssl` option to enable TLS
  - `certfile` and `keyfile` for certificate configuration
  - `cacertfile` for CA certificate chain
  - Validation ensures cert/key are provided when SSL enabled

- **WebSocket Compression**: `websocket_compress` option to enable per-message deflate

- **HTTP Lifecycle Hooks**: New `hornbeam_http_hooks` module
  - `on_request` hook for request modification/logging
  - `on_response` hook for response modification
  - `on_error` hook for custom error handling
  - Exception-safe hook execution

### Fixed

- Fixed `venv` configuration option not activating virtual environment

### Changed

- Removed `python_home` from documentation (cannot be controlled by hornbeam)

## [1.3.0] - 2026-02-18

### Added

- **ASGI/WSGI NIF Optimizations**: Direct C-level marshalling for ~2x throughput improvement
  - `py_asgi:run/5` NIF with interned scope keys and cached constants
  - `py_wsgi:run/4` NIF with interned environ keys and cached constants
  - Per-interpreter state for sub-interpreter and free-threading support
  - Response pooling for reduced memory allocation
  - ASGI: 27k → 65k req/s (~2.4x improvement)
  - WSGI: 30k → 65k req/s (~2x improvement)

- **Context Affinity Option**: `context_affinity` configuration option for apps requiring
  module-level state sharing with lifespan context

### Changed

- ASGI handler now uses `py_asgi:run/5` optimized NIF path by default
- WSGI handler now uses `py_wsgi:run/4` optimized NIF path by default
- Fallback to `py:ctx_call` when `context_affinity` is enabled

### Dependencies

- Updated `erlang_python` to 1.5.0 (adds py_asgi and py_wsgi NIF modules)

## [1.2.0] - 2026-02-18

### Added

- **Channels & Presence**: Real-time multiplexed channels with presence tracking
  - `hornbeam_channel` gen_server for channel lifecycle management
  - `hornbeam_channel_registry` for pattern-based channel routing
  - `hornbeam_presence` for CRDT-backed distributed presence
  - Python decorator API (`@channel.on_join`, `@channel.on("event")`)
  - Broadcasting (`broadcast`, `broadcast_from`)
  - Presence tracking (`Presence.track`, `Presence.list`)
  - JavaScript client with Socket, Channel, and Presence classes

- **Documentation**
  - Channels & Presence guide
  - Channels Chat example

### Changed

- **Erlang Event Loop Integration**: Replaced uvloop with erlang_loop for native Erlang scheduler integration
  - ASGI requests now use the erlang event loop policy from erlang_python
  - Better integration with Erlang's cooperative scheduling

- **ASGI Runner Optimizations**:
  - Added `__slots__` to ASGIResponse class for reduced memory allocation
  - Created `_ReceiveCallable` class to avoid closure creation per request
  - Cached lifespan state getter at module level (avoids import on every request)
  - Optimized type checks using `__class__ is` instead of `isinstance()`
  - Optimized `_run_sync_coroutine` to use try/except instead of hasattr

### Dependencies

- Updated `erlang_python` to 1.4.0 (hex package)

### Fixed

- Fixed dialyzer warnings in channel and websocket modules

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

[1.3.1]: https://github.com/benoitc/hornbeam/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/benoitc/hornbeam/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/benoitc/hornbeam/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/benoitc/hornbeam/releases/tag/v1.1.0
[1.0.0]: https://github.com/benoitc/hornbeam/releases/tag/v1.0.0
