---
title: Web Framework Integration
description: Optimized ASGI and WSGI modules for integrating Python web frameworks with erlang_python, featuring C-level marshalling for high performance.
order: 11
---

# Web Framework Integration (ASGI/WSGI)

This guide covers the optimized ASGI and WSGI modules for integrating Python web frameworks with erlang_python.

## Overview

The `py_asgi` and `py_wsgi` modules provide high-performance request handling by using optimized C-level marshalling between Erlang and Python. These modules bypass the generic `py:call()` path with specialized NIFs that:

- **Pre-intern keys** - Python string keys are interned once at startup, eliminating per-request string allocation and hashing overhead
- **Cache constants** - Common values like HTTP methods, versions, and schemes are reused across requests
- **Pool responses** - Thread-local response pooling reduces memory allocation during request processing
- **Direct NIF path** - Specialized NIF functions avoid the overhead of generic Python call marshalling

### Performance

Compared to generic `py:call()`-based handling:

| Optimization | ASGI | WSGI |
|--------------|------|------|
| Interned keys | +15-20% | +15-20% |
| Response pooling | +20-25% | N/A |
| Direct NIF | +25-30% | +25-30% |
| **Total** | ~60-80% | ~60-80% |

## ASGI Support

### Basic Usage

```erlang
%% Build ASGI scope from your HTTP server (e.g., Cowboy)
Scope = #{
    type => <<"http">>,
    http_version => <<"1.1">>,
    method => <<"GET">>,
    scheme => <<"http">>,
    path => <<"/api/users">>,
    query_string => <<"id=123">>,
    headers => [[<<"host">>, <<"localhost:8080">>]],
    server => {<<"localhost">>, 8080},
    client => {<<"127.0.0.1">>, 54321}
},

%% Execute ASGI application
case py_asgi:run(<<"myapp">>, <<"application">>, Scope, Body) of
    {ok, {Status, Headers, ResponseBody}} ->
        %% Send response
        cowboy_req:reply(Status, Headers, ResponseBody, Req);
    {error, Reason} ->
        %% Handle error
        cowboy_req:reply(500, #{}, <<"Internal Server Error">>, Req)
end.
```

### API Reference

#### `py_asgi:run/4`

```erlang
-spec run(Module, Callable, Scope, Body) -> Result when
    Module :: binary(),
    Callable :: binary(),
    Scope :: scope(),
    Body :: binary(),
    Result :: {ok, {integer(), [{binary(), binary()}], binary()}} | {error, term()}.
```

Execute an ASGI application with default options.

- `Module` - Python module containing the ASGI application (e.g., `<<"myapp">>`)
- `Callable` - Name of the ASGI callable (typically `<<"application">>` or `<<"app">>`)
- `Scope` - ASGI scope map (see Scope Fields below)
- `Body` - Request body as binary

#### `py_asgi:run/5`

```erlang
-spec run(Module, Callable, Scope, Body, Opts) -> Result when
    Module :: binary(),
    Callable :: binary(),
    Scope :: scope(),
    Body :: binary(),
    Opts :: map(),
    Result :: {ok, {integer(), [{binary(), binary()}], binary()}} | {error, term()}.
```

Execute an ASGI application with options.

Options:
- `runner` - Custom Python runner module (default: `<<"hornbeam_asgi_runner">>`)

#### `py_asgi:build_scope/1,2`

```erlang
-spec build_scope(Scope) -> {ok, reference()} | {error, term()}.
-spec build_scope(Scope, Opts) -> {ok, reference()} | {error, term()}.
```

Build an optimized Python scope dict with interned keys. The returned reference can be passed to multiple ASGI calls for further optimization when handling many requests with similar scopes.

### Scope Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | binary | Yes | Request type (`<<"http">>` or `<<"websocket">>`) |
| `asgi` | map | No | ASGI version info (default: `#{<<"version">> => <<"3.0">>}`) |
| `http_version` | binary | No | HTTP version (`<<"1.0">>`, `<<"1.1">>`, `<<"2">>`) |
| `method` | binary | No | HTTP method (`<<"GET">>`, `<<"POST">>`, etc.) |
| `scheme` | binary | No | URL scheme (`<<"http">>` or `<<"https">>`) |
| `path` | binary | Yes | Request path |
| `raw_path` | binary | No | Raw path (defaults to `path`) |
| `query_string` | binary | No | Query string without leading `?` |
| `root_path` | binary | No | Root path for mounted apps |
| `headers` | list | No | List of `[Name, Value]` header pairs |
| `server` | tuple | No | Server `{Host, Port}` tuple |
| `client` | tuple | No | Client `{Host, Port}` tuple |
| `state` | map | No | Request state dict |
| `extensions` | map | No | ASGI extensions |

## WSGI Support

### Basic Usage

```erlang
%% Build WSGI environ from your HTTP server
Environ = #{
    <<"REQUEST_METHOD">> => <<"GET">>,
    <<"SCRIPT_NAME">> => <<>>,
    <<"PATH_INFO">> => <<"/api/users">>,
    <<"QUERY_STRING">> => <<"id=123">>,
    <<"SERVER_NAME">> => <<"localhost">>,
    <<"SERVER_PORT">> => <<"8080">>,
    <<"SERVER_PROTOCOL">> => <<"HTTP/1.1">>,
    <<"wsgi.url_scheme">> => <<"http">>,
    <<"wsgi.input">> => Body
},

%% Execute WSGI application
case py_wsgi:run(<<"myapp">>, <<"application">>, Environ) of
    {ok, {Status, Headers, ResponseBody}} ->
        %% Parse status line (e.g., "200 OK")
        StatusCode = parse_status(Status),
        cowboy_req:reply(StatusCode, Headers, ResponseBody, Req);
    {error, Reason} ->
        cowboy_req:reply(500, #{}, <<"Internal Server Error">>, Req)
end.
```

### API Reference

#### `py_wsgi:run/3`

```erlang
-spec run(Module, Callable, Environ) -> Result when
    Module :: binary(),
    Callable :: binary(),
    Environ :: environ(),
    Result :: {ok, {binary(), [{binary(), binary()}], binary()}} | {error, term()}.
```

Execute a WSGI application with default options.

- `Module` - Python module containing the WSGI application
- `Callable` - Name of the WSGI callable
- `Environ` - WSGI environ map (see Environ Fields below)

Note: WSGI returns the status as a binary string (e.g., `<<"200 OK">>`), not an integer.

#### `py_wsgi:run/4`

```erlang
-spec run(Module, Callable, Environ, Opts) -> Result when
    Module :: binary(),
    Callable :: binary(),
    Environ :: environ(),
    Opts :: map(),
    Result :: {ok, {binary(), [{binary(), binary()}], binary()}} | {error, term()}.
```

Execute a WSGI application with options.

Options:
- `runner` - Custom Python runner module (default: `<<"hornbeam_wsgi_runner">>`)

### Environ Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `<<"REQUEST_METHOD">>` | binary | Yes | HTTP method |
| `<<"SCRIPT_NAME">>` | binary | Yes | Initial portion of URL path (can be empty) |
| `<<"PATH_INFO">>` | binary | Yes | Remainder of URL path |
| `<<"QUERY_STRING">>` | binary | No | Query string without leading `?` |
| `<<"CONTENT_TYPE">>` | binary | No | Content-Type header value |
| `<<"CONTENT_LENGTH">>` | binary | No | Content-Length header value |
| `<<"SERVER_NAME">>` | binary | Yes | Server hostname |
| `<<"SERVER_PORT">>` | binary | Yes | Server port as string |
| `<<"SERVER_PROTOCOL">>` | binary | Yes | Protocol version (e.g., `<<"HTTP/1.1">>`) |
| `<<"wsgi.version">>` | tuple | No | WSGI version tuple (default: `{1, 0}`) |
| `<<"wsgi.url_scheme">>` | binary | Yes | URL scheme (`<<"http">>` or `<<"https">>`) |
| `<<"wsgi.input">>` | binary | Yes | Request body |
| `<<"wsgi.errors">>` | any | No | Error stream |
| `<<"wsgi.multithread">>` | boolean | No | Default: `true` |
| `<<"wsgi.multiprocess">>` | boolean | No | Default: `true` |
| `<<"wsgi.run_once">>` | boolean | No | Default: `false` |
| `<<"HTTP_*">>` | binary | No | HTTP headers with `HTTP_` prefix |

## Custom Runner Modules

Both ASGI and WSGI support custom runner modules for advanced use cases.

### ASGI Runner

```python
# custom_asgi_runner.py
async def run_asgi(app, scope, body):
    """
    Custom ASGI runner.

    Args:
        app: The ASGI application callable
        scope: ASGI scope dict
        body: Request body bytes

    Returns:
        Tuple of (status_code, headers, body)
    """
    # Custom pre-processing
    scope['state']['custom_key'] = 'value'

    # Call the ASGI app
    response = await default_asgi_handler(app, scope, body)

    # Custom post-processing
    return response
```

```erlang
%% Use custom runner
py_asgi:run(<<"myapp">>, <<"app">>, Scope, Body, #{
    runner => <<"custom_asgi_runner">>
}).
```

### WSGI Runner

```python
# custom_wsgi_runner.py
def run_wsgi(app, environ):
    """
    Custom WSGI runner.

    Args:
        app: The WSGI application callable
        environ: WSGI environ dict

    Returns:
        Tuple of (status, headers, body)
    """
    # Custom pre-processing
    environ['custom.key'] = 'value'

    # Call the WSGI app
    response = default_wsgi_handler(app, environ)

    # Custom post-processing
    return response
```

```erlang
%% Use custom runner
py_wsgi:run(<<"myapp">>, <<"app">>, Environ, #{
    runner => <<"custom_wsgi_runner">>
}).
```

## Sub-interpreter and Free-threading Support

Both `py_asgi` and `py_wsgi` fully support Python's sub-interpreter and free-threading modes:

### Sub-interpreters (Python 3.12+)

Each request can run in an isolated sub-interpreter, providing:
- Isolated global state between requests
- No GIL contention between interpreters
- True parallelism for CPU-bound Python code

### Free-threading (Python 3.13+)

With Python 3.13's experimental free-threading build:
- No Global Interpreter Lock (GIL)
- True multi-threaded parallelism
- Best performance for concurrent requests

The modules automatically detect and use the optimal mode based on your Python installation.

## Integration Examples

### Cowboy Integration

```erlang
-module(my_asgi_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path(Req0),
    QS = cowboy_req:qs(Req0),
    Headers = cowboy_req:headers(Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    Scope = #{
        type => <<"http">>,
        method => Method,
        path => Path,
        query_string => QS,
        headers => maps:to_list(Headers),
        scheme => <<"http">>
    },

    case py_asgi:run(<<"myapp">>, <<"app">>, Scope, Body) of
        {ok, {Status, RespHeaders, RespBody}} ->
            Req = cowboy_req:reply(Status, maps:from_list(RespHeaders), RespBody, Req1),
            {ok, Req, State};
        {error, _Reason} ->
            Req = cowboy_req:reply(500, #{}, <<"Internal Server Error">>, Req1),
            {ok, Req, State}
    end.
```

### Elli Integration

```erlang
-module(my_wsgi_handler).
-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

handle(Req, _Args) ->
    Environ = #{
        <<"REQUEST_METHOD">> => elli_request:method(Req),
        <<"PATH_INFO">> => elli_request:path(Req),
        <<"QUERY_STRING">> => elli_request:query_str(Req),
        <<"SERVER_NAME">> => <<"localhost">>,
        <<"SERVER_PORT">> => <<"8080">>,
        <<"SERVER_PROTOCOL">> => <<"HTTP/1.1">>,
        <<"wsgi.url_scheme">> => <<"http">>,
        <<"wsgi.input">> => elli_request:body(Req)
    },

    case py_wsgi:run(<<"myapp">>, <<"application">>, Environ) of
        {ok, {Status, Headers, Body}} ->
            StatusCode = parse_wsgi_status(Status),
            {StatusCode, Headers, Body};
        {error, _} ->
            {500, [], <<"Internal Server Error">>}
    end.

handle_event(_, _, _) -> ok.

parse_wsgi_status(Status) ->
    [CodeBin | _] = binary:split(Status, <<" ">>),
    binary_to_integer(CodeBin).
```

## See Also

- [Getting Started](getting-started.md) - Basic usage guide
- [Asyncio](asyncio.md) - Async event loop integration
- [Threading](threading.md) - Thread support and callbacks
- [Scalability](scalability.md) - Performance tuning
