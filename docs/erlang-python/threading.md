---
title: Threading Support
description: Calling erlang.call() from Python threads, enabling concurrent Erlang callbacks from multithreaded Python code with automatic resource management.
order: 8
---

erlang_python supports calling `erlang.call()` from Python threads, enabling
concurrent Erlang callbacks from multithreaded Python code.

## Supported Thread Types

- `threading.Thread` - Standard Python threads
- `concurrent.futures.ThreadPoolExecutor` - Thread pool workers
- Any other spawned Python threads

## Usage

### With threading.Thread

```python
import threading
import erlang

def worker():
    result = erlang.call('my_function', arg1, arg2)
    print(f"Got: {result}")

thread = threading.Thread(target=worker)
thread.start()
thread.join()
```

### With ThreadPoolExecutor

```python
from concurrent.futures import ThreadPoolExecutor
import erlang

def call_erlang(x):
    return erlang.call('double_it', x)

with ThreadPoolExecutor(max_workers=4) as executor:
    results = list(executor.map(call_erlang, range(10)))
```

### Multiple Calls from Same Thread

A single thread can make multiple sequential `erlang.call()` invocations:

```python
import threading
import erlang

def worker():
    # Chain multiple Erlang calls
    x = erlang.call('add_one', 0)
    x = erlang.call('add_one', x)
    x = erlang.call('add_one', x)
    return x  # Returns 3

thread = threading.Thread(target=worker)
thread.start()
thread.join()
```

## Architecture

Each Python thread that calls `erlang.call()` gets:

1. **A dedicated response pipe** - For receiving results from Erlang
2. **A lightweight Erlang process** - Handles callbacks for that thread
3. **Automatic cleanup** - Resources released when the thread exits

This allows multiple Python threads to make concurrent Erlang calls without
blocking each other.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Python Process                           │
├─────────────────────────────────────────────────────────────────┤
│  Thread 1           Thread 2           Thread 3                 │
│  ┌─────────┐        ┌─────────┐        ┌─────────┐             │
│  │ Worker  │        │ Worker  │        │ Worker  │             │
│  │  Pipe   │        │  Pipe   │        │  Pipe   │             │
│  └────┬────┘        └────┬────┘        └────┬────┘             │
│       │                  │                  │                   │
└───────┼──────────────────┼──────────────────┼───────────────────┘
        │                  │                  │
        ▼                  ▼                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Erlang VM (BEAM)                             │
├─────────────────────────────────────────────────────────────────┤
│  Handler 1          Handler 2          Handler 3               │
│  (process)          (process)          (process)               │
│       │                  │                  │                   │
│       └──────────────────┼──────────────────┘                   │
│                          │                                      │
│                   ┌──────▼──────┐                               │
│                   │ Coordinator │                               │
│                   │  (process)  │                               │
│                   └─────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

## Thread Safety

- **Isolated state** - Each thread has its own worker channel, no locks needed
- **Concurrent calls** - Multiple threads can call `erlang.call()` simultaneously
- **Correct delivery** - Results are delivered to the correct thread via per-thread pipes

## Lifecycle

1. **First call** - When a Python thread first calls `erlang.call()`:
   - A thread worker is acquired from the pool (or created if none available)
   - An Erlang handler process is spawned for this worker
   - The worker is associated with the thread via `pthread_key_t`

2. **Subsequent calls** - The same worker is reused for all calls from that thread

3. **Thread exit** - When the Python thread terminates:
   - The `pthread_key_t` destructor is invoked automatically
   - The worker is released back to the pool
   - The Erlang handler process continues to exist for potential reuse

## Performance Considerations

- **Worker reuse** - Workers are pooled and reused across thread lifetimes
- **Lazy initialization** - Handlers are only spawned when first needed
- **No GIL blocking** - The GIL is released while waiting for Erlang responses
- **Lightweight processes** - Each Erlang handler is a lightweight BEAM process

## Limitations

- Threads must be Python threads (not C threads that don't hold the GIL)
- The thread coordinator must be started (happens automatically with application start)

## Registering Erlang Functions

Before Python threads can call Erlang functions, register them:

```erlang
%% In Erlang
py:register_function(double_it, fun([X]) -> X * 2 end).
py:register_function(add_one, fun([X]) -> X + 1 end).
```

Then call from Python threads:

```python
import threading
import erlang

def worker(n):
    return erlang.call('double_it', n)

threads = [threading.Thread(target=worker, args=(i,)) for i in range(10)]
for t in threads:
    t.start()
for t in threads:
    t.join()
```

## Asyncio Support

For asyncio applications (FastAPI, Starlette, aiohttp, etc.), use `erlang.async_call()`
instead of `erlang.call()`. This integrates properly with asyncio's event loop without
blocking or raising exceptions for control flow.

### Basic Usage

```python
import asyncio
import erlang

async def fetch_data():
    result = await erlang.async_call('get_user', user_id)
    return result

# Run in asyncio context
asyncio.run(fetch_data())
```

### With FastAPI/Starlette

```python
from fastapi import FastAPI
import erlang

app = FastAPI()

@app.get("/user/{user_id}")
async def get_user(user_id: int):
    # Use async_call for asyncio compatibility
    user = await erlang.async_call('get_user', user_id)
    return {"user": user}

@app.websocket("/ws")
async def websocket_endpoint(websocket):
    await websocket.accept()
    while True:
        data = await websocket.receive_text()
        # Safe to use in WebSocket handlers
        result = await erlang.async_call('process_message', data)
        await websocket.send_text(result)
```

### Concurrent Async Calls

```python
import asyncio
import erlang

async def parallel_queries():
    # Run multiple Erlang calls concurrently
    results = await asyncio.gather(
        erlang.async_call('query_a', param1),
        erlang.async_call('query_b', param2),
        erlang.async_call('query_c', param3)
    )
    return results
```

### Why Use async_call?

The standard `erlang.call()` uses a suspension mechanism that raises a
`SuspensionRequired` exception internally. While this works in most contexts,
it can cause issues with ASGI middleware that catches and handles exceptions:

- ASGI middleware (Starlette, FastAPI) catches exceptions during request handling
- The `SuspensionRequired` exception propagates through middleware layers
- asyncio logs "Task exception was never retrieved" warnings

`erlang.async_call()` avoids these issues by:
- Not raising exceptions for control flow
- Integrating with asyncio's event loop via `add_reader()`
- Releasing the dirty NIF thread while waiting (non-blocking)
- Using a Future that resolves when the Erlang callback completes

### When to Use Each

| Context | Recommended API |
|---------|-----------------|
| Synchronous Python code | `erlang.call()` |
| Threading (`threading.Thread`) | `erlang.call()` |
| ThreadPoolExecutor | `erlang.call()` |
| Asyncio (async/await) | `erlang.async_call()` |
| FastAPI/Starlette | `erlang.async_call()` |
| ASGI applications | `erlang.async_call()` |

## Error Handling

Errors from Erlang functions are raised as Python exceptions:

```python
import threading
import erlang

def worker():
    try:
        result = erlang.call('maybe_fail', 42)
    except RuntimeError as e:
        print(f"Erlang error: {e}")

thread = threading.Thread(target=worker)
thread.start()
thread.join()
```

### Async Error Handling

```python
import asyncio
import erlang

async def safe_call():
    try:
        result = await erlang.async_call('maybe_fail', 42)
        return result
    except RuntimeError as e:
        print(f"Erlang error: {e}")
        return None
```
