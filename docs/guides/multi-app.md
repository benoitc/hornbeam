---
title: Multi-Application Support
description: Mounting multiple WSGI/ASGI applications at different URL prefixes
order: 15
---

# Multi-Application Support

Hornbeam supports mounting multiple WSGI/ASGI applications at different URL prefixes, allowing you to combine multiple Python applications in a single server.

## Basic Usage

```erlang
hornbeam:start(#{
    mounts => [
        {"/api", "api:app", #{worker_class => asgi}},
        {"/admin", "admin:app", #{worker_class => wsgi}},
        {"/", "frontend:app", #{worker_class => wsgi}}
    ]
}).
```

Each mount is a tuple of `{Prefix, AppSpec, Options}`:

- **Prefix** - URL path prefix (must start with `/`)
- **AppSpec** - Python module:callable (e.g., `"myapp:application"`)
- **Options** - Per-mount options (worker_class, workers, timeout)

## Routing Behavior

Hornbeam uses **longest-prefix matching** to route requests:

| Request Path | Matched Mount | PATH_INFO |
|--------------|---------------|-----------|
| `/api/users` | `/api` | `/users` |
| `/api/v2/items` | `/api` | `/v2/items` |
| `/admin/dashboard` | `/admin` | `/dashboard` |
| `/about` | `/` | `/about` |

The root mount (`/`) acts as a catch-all for unmatched paths.

## WSGI Path Variables

For WSGI applications, Hornbeam sets the standard CGI variables:

| Variable | Value | Example |
|----------|-------|---------|
| `SCRIPT_NAME` | Mount prefix | `/api` |
| `PATH_INFO` | Path after prefix | `/users/123` |

```python
# api/app.py
def application(environ, start_response):
    script_name = environ.get('SCRIPT_NAME', '')  # "/api"
    path_info = environ.get('PATH_INFO', '/')      # "/users/123"
    full_path = script_name + path_info            # "/api/users/123"

    start_response('200 OK', [('Content-Type', 'text/plain')])
    return [f'Path: {full_path}'.encode()]
```

## ASGI Scope Variables

For ASGI applications, Hornbeam sets:

| Variable | Value | Example |
|----------|-------|---------|
| `root_path` | Mount prefix | `/api` |
| `path` | Path after prefix | `/users/123` |

```python
# api/app.py
async def application(scope, receive, send):
    root_path = scope.get('root_path', '')  # "/api"
    path = scope.get('path', '/')           # "/users/123"
    full_path = root_path + path            # "/api/users/123"

    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [[b'content-type', b'text/plain']],
    })
    await send({
        'type': 'http.response.body',
        'body': f'Path: {full_path}'.encode(),
    })
```

## Per-Mount Options

Each mount can have its own configuration:

```erlang
hornbeam:start(#{
    mounts => [
        %% High-performance async API with more workers
        {"/api", "api:app", #{
            worker_class => asgi,
            workers => 8,
            timeout => 60000
        }},

        %% Admin panel - fewer workers needed
        {"/admin", "admin:app", #{
            worker_class => wsgi,
            workers => 2,
            timeout => 30000
        }},

        %% Static frontend
        {"/", "frontend:app", #{
            worker_class => wsgi,
            workers => 4
        }}
    ],
    bind => "0.0.0.0:8000"
}).
```

### Available Mount Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `worker_class` | atom | `wsgi` | Protocol: `wsgi` or `asgi` |
| `workers` | integer | `4` | Number of Python workers |
| `timeout` | integer | `30000` | Request timeout in ms |

## Global Options

Global options apply to all mounts:

```erlang
hornbeam:start(#{
    mounts => [
        {"/api", "api:app", #{worker_class => asgi}},
        {"/", "frontend:app", #{worker_class => wsgi}}
    ],

    %% Global options
    bind => "0.0.0.0:8000",
    pythonpath => [".", "apps"],
    venv => "/path/to/venv",
    ssl => true,
    certfile => "/path/to/cert.pem",
    keyfile => "/path/to/key.pem",

    %% HTTP hooks apply to all mounts
    hooks => #{
        on_request => fun(Req) ->
            logger:info("~s ~s", [maps:get(method, Req), maps:get(path, Req)]),
            Req
        end
    }
}).
```

## Custom Erlang Routes

You can add Erlang handlers alongside Python mounts:

```erlang
hornbeam:start(#{
    mounts => [
        {"/api", "api:app", #{worker_class => asgi}},
        {"/", "frontend:app", #{worker_class => wsgi}}
    ],

    %% Custom Cowboy routes (matched before mounts)
    routes => [
        {"/health", health_handler, #{}},
        {"/metrics", metrics_handler, #{}}
    ]
}).
```

The custom routes take precedence over mounts, so `/health` will be handled by `health_handler` rather than the Python apps.

## Mixed WSGI/ASGI Example

A common pattern is mixing sync (WSGI) and async (ASGI) apps:

```erlang
hornbeam:start(#{
    mounts => [
        %% FastAPI for real-time API
        {"/api/v2", "api_v2:app", #{
            worker_class => asgi,
            workers => 8
        }},

        %% Legacy Flask API
        {"/api/v1", "api_v1:app", #{
            worker_class => wsgi,
            workers => 4
        }},

        %% Django admin
        {"/admin", "myproject.wsgi:application", #{
            worker_class => wsgi,
            workers => 2
        }},

        %% React frontend (served by Flask)
        {"/", "frontend:app", #{
            worker_class => wsgi
        }}
    ]
}).
```

## Validation Rules

Mount prefixes must follow these rules:

1. **Start with `/`** - `"/api"` is valid, `"api"` is not
2. **No trailing slash** (except root) - `"/api"` is valid, `"/api/"` is not
3. **No duplicates** - Each prefix must be unique

```erlang
%% Invalid - prefix doesn't start with /
hornbeam:start(#{mounts => [{"api", "app:app", #{}}]}).
%% => {error, {invalid_mount, {prefix_must_start_with_slash, "api"}}}

%% Invalid - trailing slash
hornbeam:start(#{mounts => [{"/api/", "app:app", #{}}]}).
%% => {error, {invalid_mount, {prefix_must_not_end_with_slash, "/api/"}}}

%% Invalid - duplicate prefix
hornbeam:start(#{mounts => [
    {"/api", "app1:app", #{}},
    {"/api", "app2:app", #{}}
]}).
%% => {error, duplicate_mount_prefix}
```

## URL Generation in Apps

When generating URLs in your apps, use `SCRIPT_NAME`/`root_path` to build correct absolute URLs:

### Flask

```python
from flask import Flask, url_for

app = Flask(__name__)

@app.route('/users')
def users():
    # url_for automatically includes SCRIPT_NAME
    return f'Users at: {url_for("users", _external=True)}'
```

### FastAPI

```python
from fastapi import FastAPI, Request

app = FastAPI(root_path="/api")  # Set at startup or via scope

@app.get("/users")
async def users(request: Request):
    # request.url includes root_path
    return {"url": str(request.url)}
```

### Django

```python
# settings.py
FORCE_SCRIPT_NAME = '/admin'  # If mounted at /admin

# Or dynamically from WSGI environ
USE_X_FORWARDED_HOST = True
```

## Backward Compatibility

Single-app mode continues to work:

```erlang
%% These are equivalent:
hornbeam:start("app:application", #{worker_class => wsgi}).

hornbeam:start(#{
    mounts => [{"/", "app:application", #{worker_class => wsgi}}]
}).
```

## Next Steps

- [WSGI Guide](/docs/guides/wsgi) - WSGI applications in detail
- [ASGI Guide](/docs/guides/asgi) - ASGI applications in detail
- [Custom Applications](/docs/guides/custom-apps) - Building custom Erlang handlers
- [Configuration Reference](/docs/reference/configuration) - All configuration options
