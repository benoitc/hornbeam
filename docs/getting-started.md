---
title: Getting Started
description: Install and run your first Hornbeam application
order: 1
---

# Getting Started

This guide will help you install Hornbeam and run your first Python web application on the BEAM.

## Requirements

- Erlang/OTP 27+
- Python 3.12+ (3.13+ recommended for free-threading)
- C compiler (gcc or clang)

## Installation

Add Hornbeam to your `rebar.config`:

```erlang
{deps, [
    {hornbeam, {git, "https://github.com/benoitc/hornbeam.git", {branch, "main"}}}
]}.
```

Compile:

```bash
rebar3 compile
```

## Quick Start

### 1. Create a Python Application

Create a simple WSGI application:

```python
# myapp.py
def application(environ, start_response):
    start_response('200 OK', [('Content-Type', 'text/plain')])
    return [b'Hello from Hornbeam!']
```

### 2. Start Hornbeam

```erlang
%% Start the shell
rebar3 shell

%% Start hornbeam with your app
hornbeam:start("myapp:application").
```

### 3. Test It

```bash
curl http://localhost:8000
# Hello from Hornbeam!
```

## Running ASGI Applications

For async applications (FastAPI, Starlette):

```python
# myapp.py
async def application(scope, receive, send):
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [[b'content-type', b'text/plain']],
    })
    await send({
        'type': 'http.response.body',
        'body': b'Hello from ASGI!',
    })
```

```erlang
hornbeam:start("myapp:application", #{worker_class => asgi}).
```

## Running Existing Frameworks

### Flask

```python
# app.py
from flask import Flask
app = Flask(__name__)

@app.route('/')
def hello():
    return 'Hello from Flask on Hornbeam!'

# WSGI application
application = app
```

```erlang
hornbeam:start("app:application").
```

### FastAPI

```python
# app.py
from fastapi import FastAPI
app = FastAPI()

@app.get("/")
async def root():
    return {"message": "Hello from FastAPI on Hornbeam!"}
```

```erlang
hornbeam:start("app:app", #{worker_class => asgi}).
```

### Django

```python
# myproject/wsgi.py (Django generates this)
from django.core.wsgi import get_wsgi_application
application = get_wsgi_application()
```

```erlang
hornbeam:start("myproject.wsgi:application", #{
    pythonpath => [".", "myproject"]
}).
```

## Configuration

Basic configuration options:

```erlang
hornbeam:start("myapp:application", #{
    %% Server binding
    bind => "0.0.0.0:8000",

    %% Protocol: wsgi or asgi
    worker_class => wsgi,

    %% Number of Python workers
    workers => 4,

    %% Request timeout (ms)
    timeout => 30000,

    %% Python module search paths
    pythonpath => [".", "src"]
}).
```

See [Configuration Reference](./reference/configuration.md) for all options.

## Using Erlang Features

The real power of Hornbeam is accessing Erlang from Python:

### Shared State (ETS)

```python
from hornbeam_erlang import state_get, state_set, state_incr

def application(environ, start_response):
    # Atomic counter - safe with millions of concurrent requests
    views = state_incr('page_views')

    # Cache expensive computations
    data = state_get('cached_data')
    if data is None:
        data = expensive_computation()
        state_set('cached_data', data)

    start_response('200 OK', [('Content-Type', 'text/plain')])
    return [f'Views: {views}'.encode()]
```

### Distributed RPC

```python
from hornbeam_erlang import rpc_call, nodes

def application(environ, start_response):
    # Call function on remote node
    result = rpc_call('ml@gpu-server', 'model', 'predict', [data])

    start_response('200 OK', [('Content-Type', 'application/json')])
    return [json.dumps(result).encode()]
```

See the [Erlang Integration Guide](./guides/erlang-integration.md) for more.

## Next Steps

- [WSGI Guide](./guides/wsgi.md) - Full WSGI protocol details
- [ASGI Guide](./guides/asgi.md) - Async apps and WebSocket
- [Erlang Integration](./guides/erlang-integration.md) - ETS, RPC, Pub/Sub
- [Examples](./examples/flask-app.md) - Complete working examples
