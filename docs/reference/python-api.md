---
title: Python API Reference
description: Hornbeam Python module reference
order: 32
---

# Python API Reference

This document covers all Hornbeam Python modules and functions.

## hornbeam_erlang

Core module for Erlang integration.

### Shared State (ETS)

#### state_get(key)

Get value from shared state.

```python
from hornbeam_erlang import state_get

value = state_get('user:123')  # Returns dict, list, str, int, or None
```

**Parameters:**
- `key` (str): The key to retrieve

**Returns:** Value or `None` if not found

#### state_set(key, value)

Set value in shared state.

```python
from hornbeam_erlang import state_set

state_set('user:123', {'name': 'Alice', 'email': 'alice@example.com'})
state_set('counter', 0)
state_set('flags', ['active', 'premium'])
```

**Parameters:**
- `key` (str): The key to set
- `value`: Any JSON-serializable value

**Returns:** `None`

#### state_delete(key)

Delete key from shared state.

```python
from hornbeam_erlang import state_delete

state_delete('user:123')
```

**Parameters:**
- `key` (str): The key to delete

**Returns:** `None`

#### state_incr(key, delta=1)

Atomically increment counter.

```python
from hornbeam_erlang import state_incr

views = state_incr('page_views')           # +1, returns new value
views = state_incr('page_views', 10)       # +10
views = state_incr('page_views', -5)       # -5
```

**Parameters:**
- `key` (str): The counter key
- `delta` (int, optional): Amount to increment (default: 1)

**Returns:** New counter value (int)

#### state_decr(key, delta=1)

Atomically decrement counter.

```python
from hornbeam_erlang import state_decr

remaining = state_decr('quota')            # -1
remaining = state_decr('quota', 10)        # -10
```

**Parameters:**
- `key` (str): The counter key
- `delta` (int, optional): Amount to decrement (default: 1)

**Returns:** New counter value (int)

#### state_get_multi(keys)

Get multiple keys at once.

```python
from hornbeam_erlang import state_get_multi

values = state_get_multi(['user:1', 'user:2', 'user:3'])
# Returns: {'user:1': {...}, 'user:2': {...}, 'user:3': None}
```

**Parameters:**
- `keys` (list[str]): List of keys to retrieve

**Returns:** Dict mapping keys to values (missing keys map to `None`)

#### state_keys(prefix=None)

Get all keys, optionally filtered by prefix.

```python
from hornbeam_erlang import state_keys

all_keys = state_keys()
user_keys = state_keys('user:')
```

**Parameters:**
- `prefix` (str, optional): Filter keys by prefix

**Returns:** List of keys

### Distributed RPC

#### rpc_call(node, module, function, args, timeout_ms=30000)

Call function on remote Erlang node.

```python
from hornbeam_erlang import rpc_call

result = rpc_call(
    'worker@gpu-server',    # Node name
    'ml_model',             # Module
    'predict',              # Function
    [input_data],           # Arguments (list)
    timeout_ms=60000        # Timeout in milliseconds
)
```

**Parameters:**
- `node` (str): Remote node name
- `module` (str): Erlang module name
- `function` (str): Function name
- `args` (list): Function arguments
- `timeout_ms` (int, optional): Timeout (default: 30000)

**Returns:** Function result

**Raises:**
- `TimeoutError`: If call times out
- `ConnectionError`: If node not connected
- `Exception`: If remote function raises

#### rpc_cast(node, module, function, args)

Async call to remote node (fire and forget).

```python
from hornbeam_erlang import rpc_cast

rpc_cast('logger@server', 'logger', 'log', ['info', 'User logged in'])
```

**Parameters:**
- `node` (str): Remote node name
- `module` (str): Erlang module name
- `function` (str): Function name
- `args` (list): Function arguments

**Returns:** `None`

#### nodes()

Get list of connected nodes.

```python
from hornbeam_erlang import nodes

connected = nodes()
# ['worker1@host', 'worker2@host']
```

**Returns:** List of node names (str)

#### node()

Get current node name.

```python
from hornbeam_erlang import node

current = node()
# 'web@localhost'
```

**Returns:** Node name (str)

### Pub/Sub

#### publish(topic, message)

Publish message to topic.

```python
from hornbeam_erlang import publish

count = publish('notifications', {'type': 'alert', 'text': 'Server restart'})
# Returns number of subscribers notified
```

**Parameters:**
- `topic` (str): Topic name
- `message`: Any JSON-serializable message

**Returns:** Number of subscribers notified (int)

#### subscribe(topic)

Subscribe current context to topic.

```python
from hornbeam_erlang import subscribe

subscribe('updates')
```

**Parameters:**
- `topic` (str): Topic name

**Returns:** `None`

#### unsubscribe(topic)

Unsubscribe from topic.

```python
from hornbeam_erlang import unsubscribe

unsubscribe('updates')
```

**Parameters:**
- `topic` (str): Topic name

**Returns:** `None`

### Registered Functions

#### call(name, *args)

Call registered Erlang function.

```python
from hornbeam_erlang import call

# Call function registered in Erlang
result = call('add', 1, 2)  # Returns 3
user = call('get_user', user_id)
```

**Parameters:**
- `name` (str): Registered function name
- `*args`: Function arguments

**Returns:** Function result

**Raises:** `Exception` if function not found or raises

#### cast(name, *args)

Async call to registered function (fire and forget).

```python
from hornbeam_erlang import cast

cast('log_event', 'user_login', {'user_id': 123})
```

**Parameters:**
- `name` (str): Registered function name
- `*args`: Function arguments

**Returns:** `None`

## hornbeam_ml

ML integration module.

### cached_inference(fn, input, cache_key=None, cache_prefix="ml")

Run inference with ETS caching.

```python
from hornbeam_ml import cached_inference
from sentence_transformers import SentenceTransformer

model = SentenceTransformer('all-MiniLM-L6-v2')

# Automatically cached by input hash
embedding = cached_inference(model.encode, "Hello world")

# Custom cache key
embedding = cached_inference(
    model.encode,
    "Hello world",
    cache_key="custom_key",
    cache_prefix="embeddings"
)
```

**Parameters:**
- `fn` (callable): Function to call
- `input`: Input to the function (also used for cache key if not specified)
- `cache_key` (str, optional): Custom cache key
- `cache_prefix` (str, optional): Cache key prefix (default: "ml")

**Returns:** Cached or computed result

### cache_stats()

Get cache statistics.

```python
from hornbeam_ml import cache_stats

stats = cache_stats()
# {'hits': 1000, 'misses': 100, 'hit_rate': 0.91}
```

**Returns:** Dict with `hits`, `misses`, `hit_rate`

### cache_clear(prefix=None)

Clear ML cache.

```python
from hornbeam_ml import cache_clear

cache_clear()           # Clear all
cache_clear('embeddings')  # Clear by prefix
```

**Parameters:**
- `prefix` (str, optional): Only clear keys with this prefix

**Returns:** Number of keys cleared (int)

## Type Conversions

### Python → Erlang

| Python | Erlang |
|--------|--------|
| `int` | integer |
| `float` | float |
| `str` | binary |
| `bytes` | binary |
| `True` | `true` |
| `False` | `false` |
| `None` | `undefined` |
| `list` | list |
| `tuple` | tuple |
| `dict` | map |

### Erlang → Python

| Erlang | Python |
|--------|--------|
| integer | `int` |
| float | `float` |
| binary | `str` |
| `true` | `True` |
| `false` | `False` |
| `undefined` | `None` |
| `nil` | `None` |
| list | `list` |
| tuple | `tuple` |
| map | `dict` |
| atom | `str` |

## Error Handling

```python
from hornbeam_erlang import state_get, rpc_call

# State operations return None for missing keys
value = state_get('maybe_missing')
if value is None:
    value = compute_default()

# RPC can raise exceptions
try:
    result = rpc_call('node@host', 'mod', 'func', [])
except TimeoutError:
    result = fallback()
except ConnectionError:
    result = fallback()
except Exception as e:
    log_error(f"RPC failed: {e}")
    result = fallback()

# Registered function calls can raise
try:
    result = call('my_function', arg1, arg2)
except Exception as e:
    handle_error(e)
```

## Fallback Mode

For code that works both with and without Hornbeam:

```python
try:
    from hornbeam_erlang import state_get, state_set, state_incr
    HORNBEAM_AVAILABLE = True
except ImportError:
    HORNBEAM_AVAILABLE = False

    # Fallback implementations
    _cache = {}

    def state_get(key):
        return _cache.get(key)

    def state_set(key, value):
        _cache[key] = value

    def state_incr(key, delta=1):
        _cache[key] = _cache.get(key, 0) + delta
        return _cache[key]
```

## Next Steps

- [Erlang API Reference](./erlang-api) - Erlang modules
- [Erlang Integration Guide](../guides/erlang-integration) - Usage patterns
