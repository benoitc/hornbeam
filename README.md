# Hornbeam

**Hornbeam** is an Erlang-based WSGI/ASGI server that combines Python's web and ML capabilities with Erlang's strengths:

- **Python handles**: Web apps (WSGI/ASGI), ML models, data processing
- **Erlang handles**: Scaling (millions of connections), concurrency (no GIL), distribution (cluster RPC), fault tolerance, shared state (ETS)

The name combines "horn" (unicorn, like gunicorn) with "BEAM" (Erlang VM).

## Features

- **WSGI Support**: Run standard WSGI Python applications
- **ASGI Support**: Run async ASGI Python applications (FastAPI, Starlette, etc.)
- **WebSocket**: Full WebSocket support for real-time apps
- **HTTP/2**: Via Cowboy, with multiplexing and server push
- **Shared State**: ETS-backed state accessible from Python (concurrent-safe)
- **Distributed RPC**: Call functions on remote Erlang nodes
- **Pub/Sub**: pg-based publish/subscribe messaging
- **ML Integration**: Cache ML inference results in ETS
- **Lifespan**: ASGI lifespan protocol for app startup/shutdown
- **Hot Reload**: Leverage Erlang's hot code reloading

## Quick Start

```erlang
%% Start with a WSGI application
hornbeam:start("myapp:application").

%% Start ASGI app (FastAPI, Starlette, etc.)
hornbeam:start("main:app", #{worker_class => asgi}).

%% With all options
hornbeam:start("myapp:application", #{
    bind => "0.0.0.0:8000",
    workers => 4,
    worker_class => asgi,
    lifespan => auto
}).
```

## Installation

Add hornbeam to your `rebar.config`:

```erlang
{deps, [
    {hornbeam, {git, "https://github.com/benoitc/hornbeam.git", {branch, "main"}}}
]}.
```

## Python Integration

### Shared State (ETS)

Python apps can use Erlang ETS for high-concurrency shared state:

```python
from hornbeam_erlang import state_get, state_set, state_incr

def application(environ, start_response):
    # Atomic counter (millions of concurrent increments)
    views = state_incr(f'views:{path}')

    # Get/set cached data
    data = state_get('my_key')
    if data is None:
        data = compute_expensive()
        state_set('my_key', data)

    start_response('200 OK', [('Content-Type', 'text/plain')])
    return [f'Views: {views}'.encode()]
```

### Distributed RPC

Call functions on remote Erlang nodes:

```python
from hornbeam_erlang import rpc_call, nodes

def application(environ, start_response):
    # Get connected nodes
    connected = nodes()

    # Call ML model on GPU node
    result = rpc_call(
        'gpu@ml-server',      # Remote node
        'ml_model',           # Module
        'predict',            # Function
        [data],               # Args
        timeout_ms=30000
    )

    start_response('200 OK', [('Content-Type', 'application/json')])
    return [json.dumps(result).encode()]
```

### ML Caching

Use ETS to cache ML inference results:

```python
from hornbeam_ml import cached_inference, cache_stats

def application(environ, start_response):
    # Automatically cached by input hash
    embedding = cached_inference(model.encode, text)

    # Check cache stats
    stats = cache_stats()  # {'hits': 100, 'misses': 10, 'hit_rate': 0.91}

    start_response('200 OK', [('Content-Type', 'application/json')])
    return [json.dumps({'embedding': embedding}).encode()]
```

### Pub/Sub Messaging

```python
from hornbeam_erlang import publish

def application(environ, start_response):
    # Publish to topic (all subscribers notified)
    count = publish('updates', {'type': 'new_item', 'id': 123})

    start_response('200 OK', [('Content-Type', 'application/json')])
    return [json.dumps({'subscribers_notified': count}).encode()]
```

## Examples

### Hello World (WSGI)

```python
# examples/hello_wsgi/app.py
def application(environ, start_response):
    start_response('200 OK', [('Content-Type', 'text/plain')])
    return [b'Hello from Hornbeam!']
```

```erlang
hornbeam:start("app:application", #{pythonpath => ["examples/hello_wsgi"]}).
```

### Hello World (ASGI)

```python
# examples/hello_asgi/app.py
async def application(scope, receive, send):
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [[b'content-type', b'text/plain']],
    })
    await send({
        'type': 'http.response.body',
        'body': b'Hello from Hornbeam ASGI!',
    })
```

```erlang
hornbeam:start("app:application", #{
    worker_class => asgi,
    pythonpath => ["examples/hello_asgi"]
}).
```

### WebSocket Chat

```python
# examples/websocket_chat/app.py
async def app(scope, receive, send):
    if scope['type'] == 'websocket':
        await send({'type': 'websocket.accept'})

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

```erlang
hornbeam:start("app:app", #{
    worker_class => asgi,
    pythonpath => ["examples/websocket_chat"]
}).
```

### Embedding Service with ETS Caching

See `examples/embedding_service/` for a complete ML embedding service using Erlang ETS for caching.

### Distributed ML Inference

See `examples/distributed_rpc/` for distributing ML inference across a cluster.

## Running with Gunicorn (for comparison)

All examples are designed to work with gunicorn too (with fallback functions):

```bash
# With gunicorn (single process, no Erlang features)
cd examples/hello_wsgi
gunicorn app:application

# With hornbeam (Erlang concurrency, shared state, distribution)
rebar3 shell
> hornbeam:start("app:application", #{pythonpath => ["examples/hello_wsgi"]}).
```

## Configuration

### Via hornbeam:start/2

```erlang
hornbeam:start("myapp:application", #{
    %% Server
    bind => <<"0.0.0.0:8000">>,
    ssl => false,
    certfile => undefined,
    keyfile => undefined,

    %% Protocol
    worker_class => wsgi,  % wsgi | asgi
    http_version => ['HTTP/1.1', 'HTTP/2'],

    %% Workers
    workers => 4,
    timeout => 30000,
    keepalive => 2,
    max_requests => 1000,

    %% ASGI
    lifespan => auto,  % auto | on | off

    %% WebSocket
    websocket_timeout => 60000,
    websocket_max_frame_size => 16777216,  % 16MB

    %% Python
    pythonpath => [<<".">>]
}).
```

### Via sys.config

```erlang
[
    {hornbeam, [
        {bind, "127.0.0.1:8000"},
        {workers, 4},
        {worker_class, wsgi},
        {timeout, 30000},
        {pythonpath, ["."]}
    ]}
].
```

## API Reference

### hornbeam module

| Function | Description |
|----------|-------------|
| `start(AppSpec)` | Start server with WSGI/ASGI app |
| `start(AppSpec, Options)` | Start server with options |
| `stop()` | Stop the server |
| `register_function(Name, Fun)` | Register Erlang function callable from Python |
| `register_function(Name, Module, Function)` | Register module:function |
| `unregister_function(Name)` | Unregister a function |

### Python hornbeam_erlang module

| Function | Description |
|----------|-------------|
| `state_get(key)` | Get value from ETS (None if not found) |
| `state_set(key, value)` | Set value in ETS |
| `state_incr(key, delta=1)` | Atomically increment counter, return new value |
| `state_decr(key, delta=1)` | Atomically decrement counter |
| `state_delete(key)` | Delete key from ETS |
| `state_get_multi(keys)` | Batch get multiple keys |
| `state_keys(prefix=None)` | Get all keys, optionally by prefix |
| `rpc_call(node, module, function, args, timeout_ms)` | Call function on remote node |
| `rpc_cast(node, module, function, args)` | Async call (fire and forget) |
| `nodes()` | Get list of connected Erlang nodes |
| `node()` | Get this node's name |
| `publish(topic, message)` | Publish to pub/sub topic |
| `call(name, *args)` | Call registered Erlang function |
| `cast(name, *args)` | Async call to registered function |

### Python hornbeam_ml module

| Function | Description |
|----------|-------------|
| `cached_inference(fn, input, cache_key=None, cache_prefix="ml")` | Run inference with ETS caching |
| `cache_stats()` | Get cache hit/miss statistics |

## Performance

Hornbeam achieves high throughput by leveraging Erlang's lightweight process model and avoiding Python's GIL limitations.

### Benchmark Results

Tested on Apple M4 Pro, Python 3.14, OTP 28:

| Test | Requests/sec | Latency (mean) | Failed |
|------|--------------|----------------|--------|
| Simple (100 concurrent) | **33,754** | 2.96ms | 0 |
| High concurrency (500 concurrent) | **30,312** | 16.5ms | 0 |
| Large response (64KB) | **27,355** | 1.83ms | 0 |

### Run Your Own Benchmarks

```bash
# Quick benchmark
./benchmarks/quick_bench.sh

# Full benchmark suite
python benchmarks/run_benchmark.py

# Compare with gunicorn
python benchmarks/compare_servers.py
```

See the [Benchmarking Guide](https://hornbeam.dev/docs/guides/benchmarking) for details.

## Development

```bash
# Compile
rebar3 compile

# Run tests
rebar3 ct

# Start shell
rebar3 shell
```

## License

Apache License 2.0
