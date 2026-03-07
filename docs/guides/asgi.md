---
title: ASGI Guide
description: Running async Python applications with Hornbeam
order: 11
---

# ASGI Guide

Hornbeam provides full ASGI 3.0 support for async Python applications like FastAPI, Starlette, Quart, and custom async apps.

## Basic ASGI Application

```python
# app.py
async def application(scope, receive, send):
    if scope['type'] == 'http':
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
hornbeam:start("app:application", #{worker_class => asgi}).
```

## ASGI Scope

The scope dict contains request information:

### HTTP Scope

| Key | Type | Description |
|-----|------|-------------|
| `type` | str | `"http"` |
| `asgi` | dict | `{"version": "3.0"}` |
| `http_version` | str | `"1.1"` or `"2"` |
| `method` | str | HTTP method |
| `scheme` | str | `"http"` or `"https"` |
| `path` | str | URL path (stripped of mount prefix in [multi-app mode](/docs/guides/multi-app)) |
| `query_string` | bytes | Query string |
| `root_path` | str | ASGI root path (set to mount prefix in [multi-app mode](/docs/guides/multi-app)) |
| `headers` | list | `[[name, value], ...]` |
| `server` | tuple | `(host, port)` |
| `client` | tuple | `(host, port)` or None |

### WebSocket Scope

| Key | Type | Description |
|-----|------|-------------|
| `type` | str | `"websocket"` |
| `path` | str | URL path |
| `query_string` | bytes | Query string |
| `headers` | list | Request headers |
| `subprotocols` | list | Requested subprotocols |

## Running FastAPI

```python
# app.py
from fastapi import FastAPI
from hornbeam_erlang import state_get, state_set, state_incr

app = FastAPI()

@app.get("/")
async def root():
    views = state_incr('api_views')
    return {"views": views}

@app.get("/items/{item_id}")
async def get_item(item_id: int):
    # Check ETS cache first
    cached = state_get(f'item:{item_id}')
    if cached:
        return cached

    # Fetch and cache
    item = await fetch_item(item_id)
    state_set(f'item:{item_id}', item)
    return item

@app.post("/items/")
async def create_item(item: dict):
    item_id = state_incr('item_id_seq')
    item['id'] = item_id
    state_set(f'item:{item_id}', item)
    return item
```

```erlang
hornbeam:start("app:app", #{
    worker_class => asgi,
    lifespan => on  % Enable startup/shutdown events
}).
```

## Running Starlette

```python
# app.py
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route

async def homepage(request):
    return JSONResponse({'hello': 'world'})

async def user(request):
    user_id = request.path_params['user_id']
    return JSONResponse({'user_id': user_id})

app = Starlette(routes=[
    Route('/', homepage),
    Route('/user/{user_id}', user),
])
```

## Lifespan Protocol

Handle application startup and shutdown:

```python
# app.py
from contextlib import asynccontextmanager
from fastapi import FastAPI

ml_model = None

@asynccontextmanager
async def lifespan(app):
    # Startup: Load ML model
    global ml_model
    ml_model = load_model('model.pkl')
    print("Model loaded!")

    yield  # Application runs here

    # Shutdown: Cleanup
    ml_model = None
    print("Cleanup complete!")

app = FastAPI(lifespan=lifespan)

@app.get("/predict")
async def predict(text: str):
    return {"result": ml_model.predict(text)}
```

```erlang
hornbeam:start("app:app", #{
    worker_class => asgi,
    lifespan => on  % Required for lifespan events
}).
```

### Lifespan Options

| Value | Description |
|-------|-------------|
| `auto` | Detect if app supports lifespan (default) |
| `on` | Require lifespan, fail if unsupported |
| `off` | Disable lifespan |

## Streaming Responses

By default, Hornbeam buffers every ASGI HTTP response fully before sending it to the client. This works well for typical request/response endpoints, but blocks real-time use cases like Server-Sent Events (SSE) and LLM token streaming.

To enable true HTTP streaming, set `streaming => true` in your configuration:

```erlang
hornbeam:start("app:application", #{
    worker_class => asgi,
    streaming => true
}).
```

With `streaming => true`, Hornbeam automatically detects per-request whether to stream or buffer. After the ASGI app sends its first body chunk, Hornbeam checks the `more_body` flag:

- **`more_body: False`** — single-chunk response, uses efficient buffered reply (same as non-streaming mode)
- **`more_body: True`** — multi-chunk response, switches to chunked transfer encoding and sends each chunk to the client as it arrives

Non-streaming endpoints still work correctly through this path — they produce the same buffered response. The streaming path uses a single `py:call` that pushes chunks directly to the Erlang handler via `erlang.send()`, so overhead per chunk is minimal. However, it bypasses the worker pool's optimized NIF path, so you should only enable it on apps or mounts that actually need streaming. In multi-app mode, you can enable `streaming` on just the mounts that serve SSE or chunked responses.

### Basic Streaming Example

```python
import asyncio

async def application(scope, receive, send):
    if scope['type'] == 'http':
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [[b'content-type', b'text/plain']],
        })

        # Stream data in chunks
        for i in range(10):
            await send({
                'type': 'http.response.body',
                'body': f'Chunk {i}\n'.encode(),
                'more_body': True,
            })
            await asyncio.sleep(0.1)

        # Final chunk
        await send({
            'type': 'http.response.body',
            'body': b'Done!\n',
            'more_body': False,
        })
```

> **Note:** Without `streaming => true`, the above app still works — but the client won't see any output until all chunks have been buffered and sent as one response. With streaming enabled, each chunk is flushed to the client as soon as it's produced.

## Erlang-Native Async Primitives

Hornbeam 1.4.0 introduces native Erlang timer support for async operations, providing significant performance improvements for async Python code.

### Automatic Optimization

Hornbeam auto-detects `asyncio.sleep()` in the ASGI fast path and uses Erlang's native timer via `_erlang_sleep`. Existing code benefits without modification:

```python
from fastapi import FastAPI
import asyncio

app = FastAPI()

@app.get("/")
async def root():
    await asyncio.sleep(0.001)  # Automatically uses Erlang timer
    return {"status": "ok"}
```

### Explicit erlang_asyncio

For maximum control, use `erlang_asyncio` directly:

```python
import erlang_asyncio

async def handler():
    await erlang_asyncio.sleep(0.001)  # Uses Erlang's native timer
```

### Performance

| Operation | asyncio | erlang_asyncio | Improvement |
|-----------|---------|----------------|-------------|
| sleep(1ms) | ~100/s  | ~8,600/s | **86x** |
| Concurrent tasks | ~1,000/s | ~6,200/s | **6.2x** |

### 1.4.0 Optimizations

The ASGI runner includes several optimizations:

| Optimization | Description |
|-------------|-------------|
| **Per-app execution mode caching** | Skips fast path overhead for apps requiring event loop |
| **Erlang-native timer** | Auto-detects `asyncio.sleep()` and uses `_erlang_sleep` |
| **Event-driven WebSocket wakeups** | Uses `asyncio.Event` + `asyncio.wait` |
| **Request-local queues** | Prevents cross-request bleed under concurrent load |
| **Non-blocking streaming** | `stream_async()` yields control between chunks |

## Server-Sent Events (SSE)

SSE requires `streaming => true` so that events are flushed to the client in real time.

### Raw ASGI SSE

```python
import asyncio

async def application(scope, receive, send):
    if scope['type'] != 'http':
        return

    path = scope.get('path', '/')

    if path == '/events':
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [
                [b'content-type', b'text/event-stream'],
                [b'cache-control', b'no-cache'],
            ],
        })
        for i in range(10):
            chunk = f'data: Event {i}\n\n'.encode()
            await send({
                'type': 'http.response.body',
                'body': chunk,
                'more_body': i < 9,
            })
            if i < 9:
                await asyncio.sleep(1)
    else:
        body = b'Hello!\n'
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [[b'content-type', b'text/plain']],
        })
        await send({
            'type': 'http.response.body',
            'body': body,
        })
```

```erlang
hornbeam:start("app:application", #{
    worker_class => asgi,
    streaming => true  %% Required for SSE
}).
```

### FastAPI SSE

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
import asyncio

app = FastAPI()

async def event_generator():
    for i in range(10):
        yield f"data: Event {i}\n\n"
        await asyncio.sleep(1)

@app.get("/events")
async def sse():
    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream"
    )
```

```erlang
hornbeam:start("app:app", #{
    worker_class => asgi,
    streaming => true,  %% Required for SSE
    lifespan => on
}).
```

Test with curl:

```bash
curl -N http://localhost:8000/events
# Events appear one per second as they're produced
```

## Request Body

Read request body asynchronously:

```python
async def application(scope, receive, send):
    if scope['type'] == 'http':
        # Read body
        body = b''
        while True:
            message = await receive()
            body += message.get('body', b'')
            if not message.get('more_body', False):
                break

        # Process body
        result = process(body)

        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [[b'content-type', b'application/json']],
        })
        await send({
            'type': 'http.response.body',
            'body': json.dumps(result).encode(),
        })
```

## Early Hints (103)

Send preload hints:

```python
async def application(scope, receive, send):
    if scope['type'] == 'http':
        # Send 103 Early Hints
        await send({
            'type': 'http.response.start',
            'status': 103,
            'headers': [
                [b'link', b'</style.css>; rel=preload; as=style'],
            ],
        })

        # Then send actual response
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [[b'content-type', b'text/html']],
        })
        await send({
            'type': 'http.response.body',
            'body': b'<html>...</html>',
        })
```

## Middleware

ASGI middleware pattern:

```python
class TimingMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] == 'http':
            start = time.time()

            async def send_wrapper(message):
                if message['type'] == 'http.response.start':
                    elapsed = time.time() - start
                    headers = list(message.get('headers', []))
                    headers.append([b'x-response-time', f'{elapsed:.3f}'.encode()])
                    message = {**message, 'headers': headers}
                await send(message)

            await self.app(scope, receive, send_wrapper)
        else:
            await self.app(scope, receive, send)

# Usage
from myapp import app
application = TimingMiddleware(app)
```

## Configuration

```erlang
hornbeam:start("app:app", #{
    %% Protocol
    worker_class => asgi,
    lifespan => auto,
    streaming => true,   %% Enable HTTP streaming (SSE, chunked responses)
    root_path => "",

    %% Workers
    workers => 4,
    timeout => 30000,

    %% HTTP
    http_version => ['HTTP/1.1', 'HTTP/2']
}).
```

## Error Handling

```python
async def application(scope, receive, send):
    try:
        await handle_request(scope, receive, send)
    except ValueError as e:
        await send({
            'type': 'http.response.start',
            'status': 400,
            'headers': [[b'content-type', b'text/plain']],
        })
        await send({
            'type': 'http.response.body',
            'body': str(e).encode(),
        })
    except Exception as e:
        await send({
            'type': 'http.response.start',
            'status': 500,
            'headers': [[b'content-type', b'text/plain']],
        })
        await send({
            'type': 'http.response.body',
            'body': b'Internal Server Error',
        })
```

## Next Steps

- [Multi-App Guide](/docs/guides/multi-app) - Mount multiple apps at different URLs
- [WebSocket Guide](/docs/guides/websocket) - Real-time communication
- [Erlang Integration](/docs/guides/erlang-integration) - ETS, RPC, Pub/Sub
- [FastAPI Example](/docs/examples/fastapi-app) - Complete FastAPI application
