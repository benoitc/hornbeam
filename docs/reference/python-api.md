---
title: Python API Reference
description: Complete Python module reference for Hornbeam
order: 21
---

# Python API Reference

This document covers the Python modules provided by Hornbeam for integration with Erlang.

## hornbeam_erlang

Main integration module for accessing Erlang features from Python.

### Shared State (ETS)

#### state_get

```python
def state_get(key: Any) -> Any | None
```

Get a value from ETS shared state.

**Parameters:**
- `key` - Any Erlang-compatible key (string, int, tuple, etc.)

**Returns:** Value or `None` if not found

**Example:**
```python
from hornbeam_erlang import state_get

user = state_get('user:123')
if user:
    print(f"Found user: {user['name']}")
```

#### state_set

```python
def state_set(key: Any, value: Any) -> None
```

Set a value in ETS shared state.

**Example:**
```python
from hornbeam_erlang import state_set

state_set('user:123', {'name': 'Alice', 'email': 'alice@example.com'})
```

#### state_delete

```python
def state_delete(key: Any) -> None
```

Delete a key from ETS.

**Example:**
```python
from hornbeam_erlang import state_delete

state_delete('user:123')
```

#### state_incr

```python
def state_incr(key: Any, delta: int = 1) -> int
```

Atomically increment a counter. Returns the new value.

**Parameters:**
- `key` - Counter key
- `delta` - Amount to increment (default: 1)

**Example:**
```python
from hornbeam_erlang import state_incr

# Track page views
views = state_incr('views:/home')

# Increment by 10
state_incr('score:user:123', 10)
```

#### state_decr

```python
def state_decr(key: Any, delta: int = 1) -> int
```

Atomically decrement a counter. Returns the new value.

**Example:**
```python
from hornbeam_erlang import state_decr

remaining = state_decr('quota:user:123')
if remaining < 0:
    raise QuotaExceeded()
```

#### state_get_multi

```python
def state_get_multi(keys: list) -> dict
```

Get multiple keys at once.

**Returns:** Dict mapping keys to values (missing keys have `None` values)

**Example:**
```python
from hornbeam_erlang import state_get_multi

users = state_get_multi(['user:1', 'user:2', 'user:3'])
# {'user:1': {...}, 'user:2': {...}, 'user:3': None}
```

#### state_keys

```python
def state_keys(prefix: str | None = None) -> list
```

Get all keys, optionally filtered by prefix.

**Example:**
```python
from hornbeam_erlang import state_keys

# Get all user keys
user_keys = state_keys('user:')
# ['user:1', 'user:2', 'user:123']
```

### Shortcuts

For convenience, shorter aliases are available:

```python
from hornbeam_erlang import get, set, delete, incr, decr

# Same as state_get, state_set, etc.
value = get('key')
set('key', value)
delete('key')
count = incr('counter')
```

---

### Distributed RPC

#### rpc_call

```python
def rpc_call(node: str, module: str, function: str, args: list, timeout_ms: int = 5000) -> Any
```

Call a function on a remote Erlang node synchronously.

**Parameters:**
- `node` - Remote node name (e.g., `'worker@gpu-server'`)
- `module` - Erlang module name
- `function` - Function name
- `args` - List of arguments
- `timeout_ms` - Timeout in milliseconds (default: 5000)

**Returns:** Result from remote function

**Raises:** `RuntimeError` on timeout or connection failure

**Example:**
```python
from hornbeam_erlang import rpc_call

# Call ML model on GPU node
result = rpc_call(
    'worker@gpu-server',
    'ml_model',
    'predict',
    [input_data],
    timeout_ms=30000
)
```

#### rpc_cast

```python
def rpc_cast(node: str, module: str, function: str, args: list) -> None
```

Asynchronous call to remote node (fire and forget).

**Example:**
```python
from hornbeam_erlang import rpc_cast

# Log to remote server (don't wait for response)
rpc_cast('logger@log-server', 'logger', 'log', ['info', 'User logged in'])
```

#### nodes

```python
def nodes() -> list[str]
```

Get list of connected Erlang nodes.

**Example:**
```python
from hornbeam_erlang import nodes

connected = nodes()
# ['worker1@server', 'worker2@server', 'gpu@ml-server']
```

#### node

```python
def node() -> str
```

Get this node's name.

**Example:**
```python
from hornbeam_erlang import node

current = node()
# 'hornbeam@localhost'
```

---

### Pub/Sub Messaging

#### publish

```python
def publish(topic: str, message: Any) -> int
```

Publish a message to all subscribers of a topic.

**Parameters:**
- `topic` - Topic name
- `message` - Any Erlang-compatible value

**Returns:** Number of subscribers notified

**Example:**
```python
from hornbeam_erlang import publish

# Notify all subscribers
count = publish('notifications', {
    'type': 'alert',
    'message': 'Server restart in 5 minutes'
})
print(f"Notified {count} subscribers")
```

---

### Registered Function Calls

#### call

```python
def call(name: str, *args) -> Any
```

Call a registered Erlang function synchronously.

**Parameters:**
- `name` - Function name (registered via `hornbeam:register_function/2`)
- `*args` - Arguments to pass

**Returns:** Result from Erlang function

**Example:**
```python
from hornbeam_erlang import call

# Call registered function
result = call('add', 1, 2)  # Returns 3

# Validate token
user_id = call('validate_token', token)
```

#### cast

```python
def cast(name: str, *args) -> None
```

Asynchronous call to registered Erlang function (fire and forget).

**Example:**
```python
from hornbeam_erlang import cast

# Log event without waiting
cast('log_event', 'user_login', {'user_id': 123})
```

---

### Hooks

#### register_hook

```python
def register_hook(app_path: str, handler: Any) -> None
```

Register a Python handler for hook execution.

**Parameters:**
- `app_path` - Unique identifier for the hook
- `handler` - Callable, class, or instance

**Handler Types:**

1. **Function:** Called directly with `(action, *args, **kwargs)`
2. **Class:** Instantiated, then method matching action name is called
3. **Instance:** Method matching action name is called

**Example:**
```python
from hornbeam_erlang import register_hook

# Function handler
def my_handler(action, *args, **kwargs):
    if action == 'encode':
        return model.encode(args[0])
    elif action == 'similarity':
        return cosine_sim(args[0], args[1])

register_hook('embeddings', my_handler)

# Class handler
class EmbeddingService:
    def __init__(self):
        self.model = load_model()

    def encode(self, text):
        return self.model.encode(text)

    def similarity(self, a, b):
        return cosine_sim(a, b)

register_hook('embeddings', EmbeddingService)
```

Alias: `hook = register_hook`

#### unregister_hook

```python
def unregister_hook(app_path: str) -> None
```

Unregister a previously registered handler.

Alias: `unhook = unregister_hook`

---

### Hook Execution

#### execute

```python
def execute(app_path: str, action: str, *args, **kwargs) -> Any
```

Execute an action on a registered hook (Python or Erlang).

**Parameters:**
- `app_path` - Hook identifier
- `action` - Action/method name
- `*args` - Positional arguments
- `**kwargs` - Keyword arguments

**Returns:** Result from handler

**Raises:** `RuntimeError` if hook not found or execution fails

**Example:**
```python
from hornbeam_erlang import execute

# Call embedding service
embedding = execute('embeddings', 'encode', text)
similarity = execute('embeddings', 'similarity', text1, text2)
```

#### execute_async

```python
def execute_async(app_path: str, action: str, *args, **kwargs) -> str
```

Execute an action asynchronously.

**Returns:** Task ID (binary string) for tracking

**Example:**
```python
from hornbeam_erlang import execute_async, await_result

# Start async task
task_id = execute_async('ml', 'train', dataset)

# Do other work...

# Wait for result
result = await_result(task_id, timeout_ms=60000)
```

#### await_result

```python
def await_result(task_id: str, timeout_ms: int = 30000) -> Any
```

Wait for an async task result.

**Parameters:**
- `task_id` - Task ID from `execute_async`
- `timeout_ms` - Timeout in milliseconds

**Returns:** Task result

**Raises:** `RuntimeError` if task failed or timed out

---

### Streaming

#### stream

```python
def stream(app_path: str, action: str, *args, **kwargs) -> Generator[Any, None, None]
```

Stream results from a hook action.

**Returns:** Generator yielding chunks

**Example:**
```python
from hornbeam_erlang import stream

# Stream LLM response
for chunk in stream('llm', 'generate', prompt):
    print(chunk, end='', flush=True)
```

#### stream_async

```python
async def stream_async(app_path: str, action: str, *args, **kwargs) -> AsyncGenerator[Any, None]
```

Async generator version of stream.

**Example:**
```python
from hornbeam_erlang import stream_async

async def generate():
    async for chunk in stream_async('llm', 'generate', prompt):
        yield chunk
```

---

## hornbeam_ml

ML-specific utilities with ETS-backed caching.

### cached_inference

```python
def cached_inference(
    fn: Callable[[Any], T],
    input_data: Any,
    cache_key: str | None = None,
    cache_prefix: str = "ml"
) -> T
```

Run inference with automatic ETS caching.

**Parameters:**
- `fn` - Inference function (e.g., `model.encode`)
- `input_data` - Input to the function
- `cache_key` - Optional explicit cache key (auto-generated from input if not provided)
- `cache_prefix` - Prefix for cache keys (default: "ml")

**Returns:** Inference result (from cache if available)

**Example:**
```python
from hornbeam_ml import cached_inference

# Embeddings are cached by input hash
embedding = cached_inference(model.encode, text)

# Same text returns cached result instantly
embedding2 = cached_inference(model.encode, text)  # Cache hit!

# Custom cache key
embedding = cached_inference(
    model.encode,
    text,
    cache_key=f"embed:v2:{doc_id}"
)
```

**How it works:**
1. Generates hash from `input_data` (handles numpy arrays)
2. Checks ETS for cached result
3. If miss, calls `fn(input_data)` and caches result
4. Returns result

### cache_stats

```python
def cache_stats() -> dict
```

Get cache hit/miss statistics.

**Returns:** Dict with `hits`, `misses`, and `hit_rate`

**Example:**
```python
from hornbeam_ml import cache_stats

stats = cache_stats()
# {'hits': 150, 'misses': 23, 'hit_rate': 0.867}
print(f"Cache hit rate: {stats['hit_rate']:.1%}")
```

---

## Import Summary

```python
# Full imports
from hornbeam_erlang import (
    # State
    state_get, state_set, state_delete,
    state_incr, state_decr,
    state_get_multi, state_keys,
    # Shortcuts
    get, set, delete, incr, decr,
    # RPC
    rpc_call, rpc_cast, nodes, node,
    # Pub/Sub
    publish,
    # Functions
    call, cast,
    # Hooks
    register_hook, unregister_hook, hook, unhook,
    execute, execute_async, await_result,
    stream, stream_async,
)

from hornbeam_ml import cached_inference, cache_stats
```

---

## See Also

- [Erlang API Reference](https://hexdocs.pm/hornbeam) - Erlang modules (hex.pm)
- [Hooks Guide](../guides/hooks) - Using hooks for bidirectional calls
- [ML Integration Guide](../guides/ml-integration) - ML caching patterns
