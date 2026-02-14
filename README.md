# Hornbeam

**Hornbeam** is an Erlang-based WSGI/ASGI server that uses [erlang-python](https://github.com/benoitc/erlang-python) for Python execution. The name combines "horn" (unicorn, like gunicorn) with "BEAM" (Erlang VM). Hornbeam is also a tree species, fitting the nature theme.

## Features

- **WSGI Support**: Run standard WSGI Python applications
- **ASGI Support**: Run async ASGI Python applications (FastAPI, Starlette, etc.)
- **Cowboy/Ranch**: High-performance HTTP/1.1 and HTTP/2 support
- **Erlang Integration**: Python apps can call registered Erlang functions
- **Shared State**: Built-in shared state accessible from Python and Erlang
- **Hot Reload**: Leverage Erlang's hot code reloading

## Quick Start

```erlang
%% Start hornbeam with a WSGI application
hornbeam:start("myapp:application").

%% Or with options
hornbeam:start("myapp:application", #{
    bind => "0.0.0.0:8000",
    workers => 4
}).
```

## Installation

Add hornbeam to your `rebar.config`:

```erlang
{deps, [
    {hornbeam, {git, "https://github.com/benoitc/hornbeam.git", {branch, "main"}}}
]}.
```

## Configuration

```erlang
%% sys.config
[
    {hornbeam, [
        {bind, "127.0.0.1:8000"},
        {workers, 4},
        {worker_class, wsgi},  % wsgi | asgi
        {timeout, 30000},
        {keepalive, 2},
        {max_requests, 1000},
        {pythonpath, ["."]}
    ]}
].
```

## Erlang Integration

Python applications running on hornbeam can call registered Erlang functions:

### Register Functions from Erlang

```erlang
%% Register a cache backed by ETS
ets:new(my_cache, [named_table, public]),

hornbeam:register_function(cache_get, fun([Key]) ->
    case ets:lookup(my_cache, Key) of
        [{_, Value}] -> Value;
        [] -> none
    end
end),

hornbeam:register_function(cache_set, fun([Key, Value]) ->
    ets:insert(my_cache, {Key, Value}),
    none
end).
```

### Call from Python

```python
from erlang import cache_get, cache_set, state_incr

def application(environ, start_response):
    # Access Erlang cache
    cached = cache_get("my_key")

    # Use shared state
    state_incr('requests')

    # ...
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
hornbeam:start("hello_wsgi.app:application").
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
hornbeam:start("hello_asgi.app:application", #{worker_class => asgi}).
```

### Embedding Service with Erlang Caching

See `examples/embedding_service/` for a complete example of an ML embedding service using Erlang ETS for caching.

## API Reference

### hornbeam

| Function | Description |
|----------|-------------|
| `start(AppSpec)` | Start server with WSGI/ASGI app |
| `start(AppSpec, Options)` | Start server with options |
| `stop()` | Stop the server |
| `register_function(Name, Fun)` | Register Erlang function callable from Python |
| `register_function(Name, Module, Function)` | Register module:function |
| `unregister_function(Name)` | Unregister a function |

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bind` | string | `"127.0.0.1:8000"` | Address to bind to |
| `workers` | integer | `4` | Number of Python workers |
| `worker_class` | atom | `wsgi` | `wsgi` or `asgi` |
| `timeout` | integer | `30000` | Request timeout (ms) |
| `keepalive` | integer | `2` | Keep-alive timeout (seconds) |
| `max_requests` | integer | `1000` | Max requests per worker |
| `pythonpath` | list | `["."]` | Additional Python paths |

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
