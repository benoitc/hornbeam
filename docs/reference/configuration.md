---
title: Configuration Reference
description: All Hornbeam configuration options
order: 30
---

# Configuration Reference

This document covers all Hornbeam configuration options.

## Quick Start

```erlang
hornbeam:start("myapp:application", #{
    bind => "0.0.0.0:8000",
    workers => 4,
    worker_class => asgi
}).
```

## Server Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bind` | binary/string | `"127.0.0.1:8000"` | Address and port to bind to |
| `ssl` | boolean | `false` | Enable SSL/TLS |
| `certfile` | binary | `undefined` | Path to SSL certificate |
| `keyfile` | binary | `undefined` | Path to SSL private key |
| `cacertfile` | binary | `undefined` | Path to CA certificate |

### SSL Example

```erlang
hornbeam:start("app:application", #{
    bind => "0.0.0.0:443",
    ssl => true,
    certfile => "/path/to/cert.pem",
    keyfile => "/path/to/key.pem"
}).
```

## Protocol Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `worker_class` | atom | `wsgi` | Protocol: `wsgi` or `asgi` |

## Worker Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `workers` | integer | `4` | Number of Python workers |
| `timeout` | integer | `30000` | Request timeout in milliseconds |
| `keepalive` | integer | `2` | HTTP keep-alive timeout in seconds |
| `max_requests` | integer | `1000` | Recycle worker after N requests |
| `preload_app` | boolean | `false` | Load app before forking workers |

### Worker Sizing

```erlang
%% CPU-bound (ML inference)
hornbeam:start("app:app", #{
    workers => erlang:system_info(schedulers)  % One per CPU
}).

%% I/O-bound (web app with DB calls)
hornbeam:start("app:app", #{
    workers => erlang:system_info(schedulers) * 2
}).
```

## ASGI Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `lifespan` | atom | `auto` | Lifespan handling: `auto`, `on`, `off` |
| `root_path` | binary | `""` | ASGI root_path for mounted apps |

### Lifespan Values

- `auto` - Detect if app supports lifespan, use if available
- `on` - Require lifespan, fail if app doesn't support it
- `off` - Disable lifespan even if app supports it

## WebSocket Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `websocket_timeout` | integer | `60000` | WebSocket idle timeout (ms) |
| `websocket_max_frame_size` | integer | `16777216` | Max frame size (16MB) |
| `websocket_compress` | boolean | `false` | Enable WebSocket compression |

## Request Limits

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_request_line_size` | integer | `4094` | Max HTTP request line length |
| `max_header_size` | integer | `8190` | Max HTTP header value length |
| `max_headers` | integer | `100` | Max number of HTTP headers |

## Python Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pythonpath` | list | `[".", "examples"]` | Python module search paths |
| `venv` | binary | `undefined` | Virtual environment path |

### Virtual Environment

```erlang
hornbeam:start("app:application", #{
    venv => "/path/to/myproject/venv",
    pythonpath => ["/path/to/myproject"]
}).
```

## Hooks

Hooks allow you to execute Erlang code at key points in the request lifecycle.

| Hook | Arguments | Return | Description |
|------|-----------|--------|-------------|
| `on_request` | `Request` | `Request` | Called before handling request |
| `on_response` | `Response` | `Response` | Called before sending response |
| `on_error` | `Error, Request` | `{Code, Body}` | Called on error |

### Hook Examples

```erlang
hornbeam:start("app:application", #{
    hooks => #{
        %% Request hook: logging, authentication, rate limiting
        on_request => fun(Request) ->
            #{method := Method, path := Path} = Request,
            logger:info("~s ~s", [Method, Path]),

            %% Add custom header
            Headers = maps:get(headers, Request, #{}),
            Request#{headers => Headers#{<<"x-request-id">> => generate_id()}}
        end,

        %% Response hook: add headers, log response
        on_response => fun(Response) ->
            #{status := Status} = Response,
            metrics:incr(<<"response_", (integer_to_binary(Status))/binary>>),

            %% Add server header
            Headers = maps:get(headers, Response, #{}),
            Response#{headers => Headers#{<<"x-powered-by">> => <<"Hornbeam">>}}
        end,

        %% Error hook: custom error handling
        on_error => fun(Error, Request) ->
            #{path := Path} = Request,
            logger:error("Error on ~s: ~p", [Path, Error]),

            case Error of
                {timeout, _} ->
                    {504, <<"Gateway Timeout">>};
                {python_error, Reason} ->
                    {500, iolist_to_binary(io_lib:format("~p", [Reason]))};
                _ ->
                    {500, <<"Internal Server Error">>}
            end
        end
    }
}).
```

### Authentication Hook

```erlang
hornbeam:start("app:application", #{
    hooks => #{
        on_request => fun(Request) ->
            #{headers := Headers, path := Path} = Request,

            %% Skip auth for public paths
            case Path of
                <<"/health">> -> Request;
                <<"/public/", _/binary>> -> Request;
                _ ->
                    case maps:get(<<"authorization">>, Headers, undefined) of
                        undefined ->
                            throw({unauthorized, <<"Missing authorization header">>});
                        Token ->
                            case auth:verify_token(Token) of
                                {ok, UserId} ->
                                    Request#{user_id => UserId};
                                {error, _} ->
                                    throw({unauthorized, <<"Invalid token">>})
                            end
                    end
            end
        end,

        on_error => fun(Error, _Request) ->
            case Error of
                {unauthorized, Message} ->
                    {401, Message};
                _ ->
                    {500, <<"Internal Server Error">>}
            end
        end
    }
}).
```

### Rate Limiting Hook

```erlang
hornbeam:start("app:application", #{
    hooks => #{
        on_request => fun(Request) ->
            #{headers := Headers} = Request,
            ClientIP = maps:get(<<"x-forwarded-for">>, Headers,
                                maps:get(<<"x-real-ip">>, Headers, <<"unknown">>)),

            %% Rate limit key
            Minute = calendar:datetime_to_gregorian_seconds(calendar:universal_time()) div 60,
            Key = {rate_limit, ClientIP, Minute},

            %% Check and increment
            Count = ets:update_counter(rate_limits, Key, 1, {Key, 0}),

            if
                Count > 100 ->
                    throw({rate_limited, <<"Too many requests">>});
                true ->
                    Request
            end
        end,

        on_error => fun(Error, _Request) ->
            case Error of
                {rate_limited, Message} ->
                    {429, Message};
                _ ->
                    {500, <<"Internal Server Error">>}
            end
        end
    }
}).
```

### Metrics Hook

```erlang
hornbeam:start("app:application", #{
    hooks => #{
        on_request => fun(Request) ->
            %% Start timing
            Request#{start_time => erlang:monotonic_time(microsecond)}
        end,

        on_response => fun(Response) ->
            #{start_time := StartTime, status := Status, path := Path} = Response,
            Duration = erlang:monotonic_time(microsecond) - StartTime,

            %% Record metrics
            prometheus_histogram:observe(
                http_request_duration_microseconds,
                [Path, Status],
                Duration
            ),

            Response
        end
    }
}).
```

## sys.config

Configure via sys.config for releases:

```erlang
%% config/sys.config
[
    {hornbeam, [
        {bind, "0.0.0.0:8000"},
        {workers, 8},
        {worker_class, asgi},
        {timeout, 30000},
        {lifespan, on},
        {pythonpath, [".", "src"]},
        {websocket_timeout, 120000}
    ]}
].
```

Then start without options:

```erlang
hornbeam:start("app:application").
```

## Environment Variables

```bash
# Set via environment
export HORNBEAM_BIND="0.0.0.0:8000"
export HORNBEAM_WORKERS=8
export HORNBEAM_TIMEOUT=30000
```

```erlang
%% Read from environment
hornbeam:start("app:application", #{
    bind => os:getenv("HORNBEAM_BIND", "127.0.0.1:8000"),
    workers => list_to_integer(os:getenv("HORNBEAM_WORKERS", "4"))
}).
```

## Next Steps

- [Erlang API Reference](https://hexdocs.pm/hornbeam) - All Erlang modules (hex.pm)
- [Python API Reference](./python-api.md) - All Python modules
