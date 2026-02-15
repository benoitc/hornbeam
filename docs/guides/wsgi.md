---
title: WSGI Guide
description: Running WSGI applications with Hornbeam
order: 10
---

# WSGI Guide

Hornbeam provides full WSGI (PEP 3333) support, allowing you to run Flask, Django, Bottle, and any standard WSGI application.

## Basic WSGI Application

```python
# app.py
def application(environ, start_response):
    path = environ.get('PATH_INFO', '/')

    start_response('200 OK', [
        ('Content-Type', 'text/plain'),
    ])
    return [f'You requested: {path}'.encode()]
```

```erlang
hornbeam:start("app:application").
```

## WSGI Environ

Hornbeam provides all standard WSGI environ variables:

| Variable | Description |
|----------|-------------|
| `REQUEST_METHOD` | HTTP method (GET, POST, etc.) |
| `SCRIPT_NAME` | URL path prefix |
| `PATH_INFO` | URL path |
| `QUERY_STRING` | Query string after `?` |
| `CONTENT_TYPE` | Request content type |
| `CONTENT_LENGTH` | Request body length |
| `SERVER_NAME` | Server hostname |
| `SERVER_PORT` | Server port |
| `SERVER_PROTOCOL` | HTTP/1.1 or HTTP/2 |
| `HTTP_*` | HTTP headers |

### WSGI Extensions

| Variable | Description |
|----------|-------------|
| `wsgi.input` | Request body stream |
| `wsgi.errors` | Error output stream |
| `wsgi.url_scheme` | `http` or `https` |
| `wsgi.file_wrapper` | Efficient file serving |
| `wsgi.early_hints` | Send 103 Early Hints |

## Running Flask

```python
# app.py
from flask import Flask, jsonify
from hornbeam_erlang import state_get, state_set, state_incr

app = Flask(__name__)

@app.route('/')
def index():
    # Use ETS for atomic page view counter
    views = state_incr('page_views')
    return f'Page views: {views}'

@app.route('/api/data')
def get_data():
    # Cache expensive operations in ETS
    cached = state_get('api_cache')
    if cached is None:
        cached = expensive_computation()
        state_set('api_cache', cached, ttl=300)  # 5 min TTL
    return jsonify(cached)

# WSGI application callable
application = app
```

```erlang
hornbeam:start("app:application", #{
    workers => 8,
    timeout => 30000
}).
```

## Running Django

### 1. Create Django Project

```bash
django-admin startproject myproject
cd myproject
python manage.py migrate
```

### 2. Configure Settings

```python
# myproject/settings.py
ALLOWED_HOSTS = ['*']  # Configure appropriately for production
```

### 3. Start with Hornbeam

```erlang
hornbeam:start("myproject.wsgi:application", #{
    pythonpath => [".", "myproject"],
    workers => 4
}).
```

## Running Bottle

```python
# app.py
from bottle import Bottle, response

app = Bottle()

@app.route('/')
def index():
    return 'Hello from Bottle!'

@app.route('/json')
def json_endpoint():
    response.content_type = 'application/json'
    return '{"status": "ok"}'

# WSGI application
application = app
```

## File Uploads

Handle file uploads efficiently:

```python
def application(environ, start_response):
    if environ['REQUEST_METHOD'] == 'POST':
        content_length = int(environ.get('CONTENT_LENGTH', 0))
        body = environ['wsgi.input'].read(content_length)

        # Process uploaded file
        # ...

        start_response('200 OK', [('Content-Type', 'text/plain')])
        return [b'Upload received']

    start_response('405 Method Not Allowed', [])
    return [b'POST only']
```

## File Serving

Use `wsgi.file_wrapper` for efficient static file serving:

```python
import os

def application(environ, start_response):
    path = environ.get('PATH_INFO', '/')[1:]  # Remove leading /
    filepath = os.path.join('static', path)

    if os.path.isfile(filepath):
        file_wrapper = environ.get('wsgi.file_wrapper')

        start_response('200 OK', [
            ('Content-Type', 'application/octet-stream'),
            ('Content-Length', str(os.path.getsize(filepath))),
        ])

        f = open(filepath, 'rb')
        if file_wrapper:
            return file_wrapper(f)
        else:
            return iter(lambda: f.read(8192), b'')

    start_response('404 Not Found', [])
    return [b'Not found']
```

## Early Hints (103)

Send preload hints before the response:

```python
def application(environ, start_response):
    # Send early hints for resource preloading
    early_hints = environ.get('wsgi.early_hints')
    if early_hints:
        early_hints([
            ('Link', '</style.css>; rel=preload; as=style'),
            ('Link', '</app.js>; rel=preload; as=script'),
        ])

    # Continue with normal response
    start_response('200 OK', [('Content-Type', 'text/html')])
    return [b'<html>...</html>']
```

## Error Handling

```python
def application(environ, start_response):
    try:
        # Your application logic
        result = process_request(environ)
        start_response('200 OK', [('Content-Type', 'text/plain')])
        return [result]
    except ValueError as e:
        start_response('400 Bad Request', [('Content-Type', 'text/plain')])
        return [str(e).encode()]
    except Exception as e:
        # Log to wsgi.errors
        environ['wsgi.errors'].write(f'Error: {e}\n')
        start_response('500 Internal Server Error', [('Content-Type', 'text/plain')])
        return [b'Internal error']
```

## Middleware

Standard WSGI middleware works with Hornbeam:

```python
class LoggingMiddleware:
    def __init__(self, app):
        self.app = app

    def __call__(self, environ, start_response):
        path = environ.get('PATH_INFO', '/')
        method = environ.get('REQUEST_METHOD')
        print(f'{method} {path}')
        return self.app(environ, start_response)

# Wrap your application
from myapp import app
application = LoggingMiddleware(app)
```

## Configuration Options

```erlang
hornbeam:start("app:application", #{
    %% Protocol
    worker_class => wsgi,

    %% Workers
    workers => 4,              % Number of Python workers
    timeout => 30000,          % Request timeout (ms)
    max_requests => 1000,      % Recycle workers after N requests

    %% HTTP
    keepalive => 2,            % Keep-alive timeout (seconds)

    %% Python
    pythonpath => [".", "src"]
}).
```

## Performance Tips

1. **Use ETS for caching** - Faster than Redis for local state
2. **Preload models** - Load ML models at startup with `preload_app => true`
3. **Batch operations** - Use `state_get_multi` for multiple keys
4. **Monitor workers** - Check pool stats with `hornbeam:pool_stats()`

## Next Steps

- [ASGI Guide](./asgi) - For async applications
- [Erlang Integration](./erlang-integration) - ETS, RPC, Pub/Sub
- [Flask Example](../examples/flask-app) - Complete Flask application
