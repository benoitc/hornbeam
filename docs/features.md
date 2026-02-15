# Hornbeam Features

This document describes the features implemented in hornbeam.

## Core Features

### WSGI Protocol (PEP 3333)

Full WSGI compliance with gunicorn-compatible features:

| Feature | Status | Description |
|---------|--------|-------------|
| Full environ dict | ✅ | All required and recommended WSGI variables |
| FileWrapper | ✅ | `wsgi.file_wrapper` for efficient file serving |
| Early hints | ✅ | `wsgi.early_hints` for 103 responses |
| Error stream | ✅ | `wsgi.errors` routing to logging |
| Proxy protocol | ✅ | Client IP from X-Forwarded-For headers |
| `start_response` | ✅ | Proper exc_info handling |

### ASGI Protocol (v3.0)

Full ASGI 3.0 support:

| Feature | Status | Description |
|---------|--------|-------------|
| HTTP scope | ✅ | Full HTTP request scope |
| WebSocket scope | ✅ | WebSocket connection handling |
| Lifespan | ✅ | Startup/shutdown events |
| Streaming | ✅ | `more_body` for chunked responses |
| Informational | ✅ | 1xx responses (103 Early Hints) |

### HTTP Features (via Cowboy)

| Feature | Status | Description |
|---------|--------|-------------|
| HTTP/1.1 | ✅ | Keep-alive, chunked encoding |
| HTTP/2 | ✅ | Multiplexing via Cowboy |
| WebSocket | ✅ | RFC 6455, binary/text frames |
| TLS/SSL | ✅ | Via Cowboy |

## Erlang Integration

### Shared State (ETS)

ETS-backed shared state accessible from Python:

```python
from hornbeam_erlang import state_get, state_set, state_incr

# Get/set values
value = state_get('key')
state_set('key', value)

# Atomic counter operations
count = state_incr('counter')
count = state_incr('counter', 10)  # Increment by 10
```

**Erlang module:** `hornbeam_state`

| Function | Description |
|----------|-------------|
| `state_get(key)` | Get value, returns `None` if not found |
| `state_set(key, value)` | Set value |
| `state_delete(key)` | Delete key |
| `state_incr(key, delta)` | Atomic increment, returns new value |
| `state_decr(key, delta)` | Atomic decrement |
| `state_get_multi(keys)` | Batch get multiple keys |
| `state_keys(prefix)` | Get all keys matching prefix |

### Distributed Erlang (RPC)

Call functions on remote Erlang nodes:

```python
from hornbeam_erlang import rpc_call, rpc_cast, nodes, node

# Synchronous RPC
result = rpc_call('worker@host2', 'module', 'function', [args], timeout_ms=5000)

# Async RPC (fire and forget)
rpc_cast('worker@host2', 'module', 'function', [args])

# Get connected nodes
connected = nodes()
local = node()
```

**Erlang module:** `hornbeam_dist`

### Pub/Sub Messaging

pg-based publish/subscribe:

```python
from hornbeam_erlang import publish

# Publish to topic
subscriber_count = publish('topic', message)
```

**Erlang module:** `hornbeam_pubsub`

### Registered Functions

Call Erlang functions from Python:

```erlang
%% Erlang: Register function
hornbeam:register_function(my_func, fun([Arg1, Arg2]) ->
    %% Process args
    Result
end).
```

```python
# Python: Call registered function
from hornbeam_erlang import call, cast

result = call('my_func', arg1, arg2)  # Synchronous
cast('my_func', arg1, arg2)  # Async (fire and forget)
```

**Erlang module:** `hornbeam_callbacks`

## ML Integration

### Cached Inference

ETS-backed caching for ML inference:

```python
from hornbeam_ml import cached_inference, cache_stats

# Cache by input hash
embedding = cached_inference(model.encode, "text")

# Get cache statistics
stats = cache_stats()  # {'hits': 100, 'misses': 10, 'hit_rate': 0.91}
```

**Python module:** `hornbeam_ml`

| Function | Description |
|----------|-------------|
| `cached_inference(fn, input, cache_key, prefix)` | Run with ETS caching |
| `cache_stats()` | Get hit/miss statistics |

## ASGI Lifespan

Support for ASGI lifespan protocol:

```python
async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        while True:
            message = await receive()
            if message['type'] == 'lifespan.startup':
                # Initialize (load models, connect DB, etc.)
                await send({'type': 'lifespan.startup.complete'})
            elif message['type'] == 'lifespan.shutdown':
                # Cleanup
                await send({'type': 'lifespan.shutdown.complete'})
                return
```

**Erlang module:** `hornbeam_lifespan`

Configuration:
- `lifespan => auto` - Detect if app supports lifespan (default)
- `lifespan => on` - Require lifespan, fail if not supported
- `lifespan => off` - Disable lifespan

## WebSocket Support

Full ASGI WebSocket support:

```python
async def app(scope, receive, send):
    if scope['type'] == 'websocket':
        # Wait for connection
        message = await receive()
        if message['type'] == 'websocket.connect':
            await send({'type': 'websocket.accept'})

        # Message loop
        while True:
            message = await receive()
            if message['type'] == 'websocket.disconnect':
                break
            if message['type'] == 'websocket.receive':
                # Echo back
                await send({
                    'type': 'websocket.send',
                    'text': message.get('text', '')
                })
```

**Erlang module:** `hornbeam_websocket`

## Configuration Options

### Server

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bind` | binary | `"127.0.0.1:8000"` | Address to bind to |
| `ssl` | boolean | `false` | Enable SSL/TLS |
| `certfile` | binary | `undefined` | SSL certificate path |
| `keyfile` | binary | `undefined` | SSL private key path |

### Protocol

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `worker_class` | atom | `wsgi` | `wsgi` or `asgi` |
| `http_version` | list | `['HTTP/1.1', 'HTTP/2']` | Supported versions |

### Workers

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `workers` | integer | `4` | Number of Python workers |
| `timeout` | integer | `30000` | Request timeout (ms) |
| `keepalive` | integer | `2` | Keep-alive timeout (s) |
| `max_requests` | integer | `1000` | Max requests per worker |
| `preload_app` | boolean | `false` | Preload before forking |

### ASGI

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `root_path` | binary | `""` | ASGI root_path |
| `lifespan` | atom | `auto` | `auto`, `on`, `off` |

### WebSocket

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `websocket_timeout` | integer | `60000` | Idle timeout (ms) |
| `websocket_max_frame_size` | integer | `16777216` | Max frame size (16MB) |

### Python

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pythonpath` | list | `[".", "examples"]` | Python paths |

## Module Summary

### Erlang Modules

| Module | Description |
|--------|-------------|
| `hornbeam` | Main API |
| `hornbeam_config` | Configuration management |
| `hornbeam_handler` | Cowboy HTTP handler |
| `hornbeam_wsgi` | WSGI protocol |
| `hornbeam_asgi` | ASGI protocol |
| `hornbeam_websocket` | WebSocket handler |
| `hornbeam_lifespan` | ASGI lifespan |
| `hornbeam_state` | Shared state (ETS) |
| `hornbeam_dist` | Distributed RPC |
| `hornbeam_pubsub` | Pub/Sub messaging |
| `hornbeam_callbacks` | Registered functions |
| `hornbeam_tasks` | Async task management |

### Python Modules

| Module | Description |
|--------|-------------|
| `hornbeam_wsgi_runner` | WSGI request runner |
| `hornbeam_asgi_runner` | ASGI request runner |
| `hornbeam_websocket_runner` | WebSocket session runner |
| `hornbeam_lifespan_runner` | Lifespan protocol runner |
| `hornbeam_erlang` | Erlang integration API |
| `hornbeam_ml` | ML caching helpers |
