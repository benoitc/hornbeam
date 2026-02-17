---
title: Erlang Integration
description: Using ETS, RPC, Pub/Sub, and callbacks from Python
order: 13
---

# Erlang Integration

Hornbeam's power comes from accessing Erlang features directly from Python. This guide covers shared state (ETS), distributed RPC, pub/sub messaging, and registered functions.

## Shared State (ETS)

ETS (Erlang Term Storage) provides high-performance concurrent key-value storage accessible from Python.

### Basic Operations

```python
from hornbeam_erlang import (
    state_get, state_set, state_delete,
    state_incr, state_decr,
    state_get_multi, state_keys
)

# Get and set values
state_set('user:123', {'name': 'Alice', 'email': 'alice@example.com'})
user = state_get('user:123')  # Returns dict or None

# Delete
state_delete('user:123')
```

### Atomic Counters

Perfect for metrics, rate limiting, and sequences:

```python
# Increment (returns new value)
views = state_incr('page_views')           # +1
views = state_incr('page_views', 10)       # +10

# Decrement
remaining = state_decr('quota', 1)

# Use for rate limiting
def check_rate_limit(user_id, limit=100):
    key = f'rate:{user_id}:{minute()}'
    count = state_incr(key)
    if count == 1:
        state_set(f'{key}:ttl', 60)  # Set TTL on first access
    return count <= limit
```

### Batch Operations

```python
# Get multiple keys at once
users = state_get_multi(['user:1', 'user:2', 'user:3'])
# Returns: {'user:1': {...}, 'user:2': {...}, 'user:3': None}

# Find keys by prefix
user_keys = state_keys('user:')
# Returns: ['user:1', 'user:2', 'user:123', ...]
```

### Use Cases

**Caching:**
```python
def get_product(product_id):
    cached = state_get(f'product:{product_id}')
    if cached:
        return cached

    product = fetch_from_database(product_id)
    state_set(f'product:{product_id}', product)
    return product
```

**Session Storage:**
```python
def get_session(session_id):
    return state_get(f'session:{session_id}')

def set_session(session_id, data):
    state_set(f'session:{session_id}', data)
```

**Real-time Metrics:**
```python
def track_request(path, status, latency):
    state_incr(f'metrics:requests:{path}')
    state_incr(f'metrics:status:{status}')
    # Update latency histogram
    bucket = latency // 100 * 100  # Round to 100ms buckets
    state_incr(f'metrics:latency:{bucket}')
```

## Distributed RPC

Call functions on remote Erlang nodes in a cluster:

```python
from hornbeam_erlang import rpc_call, rpc_cast, nodes, node

# Get cluster info
current = node()           # This node's name
connected = nodes()        # List of connected nodes

# Synchronous call
result = rpc_call(
    'worker@gpu-server',   # Remote node
    'ml_model',            # Module
    'predict',             # Function
    [input_data],          # Arguments
    timeout_ms=30000       # Timeout
)

# Async call (fire and forget)
rpc_cast('logger@log-server', 'logger', 'log', [
    'info', 'User logged in', {'user_id': 123}
])
```

### Distributed ML Inference

Spread ML workloads across GPU nodes:

```python
from hornbeam_erlang import rpc_call, nodes
import asyncio

async def distributed_embedding(texts):
    """Distribute embedding computation across GPU nodes."""
    gpu_nodes = [n for n in nodes() if 'gpu' in n]

    if not gpu_nodes:
        # Fallback to local
        return local_embed(texts)

    # Split work across nodes
    chunks = split_list(texts, len(gpu_nodes))
    results = []

    for node, chunk in zip(gpu_nodes, chunks):
        result = rpc_call(
            node,
            'embedding_service',
            'encode',
            [chunk],
            timeout_ms=60000
        )
        results.extend(result)

    return results
```

### Error Handling

```python
from hornbeam_erlang import rpc_call

try:
    result = rpc_call('worker@remote', 'mod', 'func', [args])
except TimeoutError:
    # Node didn't respond in time
    result = fallback()
except ConnectionError:
    # Node not connected
    result = fallback()
except Exception as e:
    # Remote function raised an error
    log_error(f"RPC failed: {e}")
    result = fallback()
```

## Pub/Sub Messaging

pg-based publish/subscribe for real-time messaging:

```python
from hornbeam_erlang import publish, subscribe, unsubscribe

# Subscribe current process to topic
subscribe('notifications')
subscribe('user:123:events')

# Publish message (returns subscriber count)
count = publish('notifications', {
    'type': 'alert',
    'message': 'Server restart in 5 minutes'
})

# Unsubscribe
unsubscribe('notifications')
```

### WebSocket with Pub/Sub

```python
from hornbeam_erlang import publish, subscribe, receive_pubsub

async def websocket_handler(scope, receive, send):
    await send({'type': 'websocket.accept'})

    user_id = get_user_from_scope(scope)
    subscribe(f'user:{user_id}')

    try:
        while True:
            # Check for client messages
            message = await receive()
            if message['type'] == 'websocket.disconnect':
                break

            # Check for pub/sub messages
            pubsub_msg = receive_pubsub(timeout=0)
            if pubsub_msg:
                await send({
                    'type': 'websocket.send',
                    'text': json.dumps(pubsub_msg)
                })
    finally:
        unsubscribe(f'user:{user_id}')
```

### Broadcasting Updates

```python
def update_product(product_id, data):
    # Update in ETS
    state_set(f'product:{product_id}', data)

    # Notify all subscribers
    publish(f'product:{product_id}', {
        'type': 'updated',
        'product_id': product_id,
        'data': data
    })
```

## Registered Functions

Call Erlang functions from Python:

### Register in Erlang

```erlang
%% Register a simple function
hornbeam:register_function(add, fun([A, B]) -> A + B end).

%% Register a module function
hornbeam:register_function(get_user, user_db, get).

%% Register with validation
hornbeam:register_function(validate_token, fun([Token]) ->
    case auth:verify(Token) of
        {ok, UserId} -> {ok, UserId};
        error -> {error, invalid_token}
    end
end).
```

### Call from Python

```python
from hornbeam_erlang import call, cast

# Synchronous call
result = call('add', 1, 2)  # Returns 3

# Get user from Erlang
user = call('get_user', user_id)

# Validate token
try:
    user_id = call('validate_token', token)
except Exception as e:
    return {'error': 'Invalid token'}

# Async call (fire and forget)
cast('log_event', 'user_login', {'user_id': 123})
```

### Use Cases

**Authentication:**
```erlang
%% Erlang side
hornbeam:register_function(verify_session, fun([SessionId]) ->
    case session_store:get(SessionId) of
        {ok, Session} -> {ok, Session};
        not_found -> {error, not_found}
    end
end).
```

```python
# Python side
def get_current_user(request):
    session_id = request.cookies.get('session_id')
    if not session_id:
        return None

    try:
        session = call('verify_session', session_id)
        return session.get('user')
    except:
        return None
```

**Feature Flags:**
```erlang
%% Erlang side
hornbeam:register_function(feature_enabled, fun([Feature, UserId]) ->
    feature_flags:is_enabled(Feature, UserId)
end).
```

```python
# Python side
def get_features(user_id):
    return {
        'new_ui': call('feature_enabled', 'new_ui', user_id),
        'beta': call('feature_enabled', 'beta', user_id),
    }
```

## Hooks

Execute Erlang code at key points in request lifecycle:

```erlang
%% Configure hooks
hornbeam:start("app:application", #{
    hooks => #{
        on_request => fun(Request) ->
            %% Log, authenticate, modify request
            Request
        end,
        on_response => fun(Response) ->
            %% Modify response, log metrics
            Response
        end,
        on_error => fun(Error, Request) ->
            %% Error handling, alerting
            error_logger:error_msg("Error: ~p~n", [Error]),
            {500, "Internal Error"}
        end
    }
}).
```

## Best Practices

### 1. Use ETS for Hot Data

```python
# Good: Frequently accessed, changes often
state_set('rate_limit:user:123', count)
state_set('session:abc123', session_data)

# Bad: Large, rarely accessed (use database)
state_set('user:history', huge_list)
```

### 2. Atomic Operations

```python
# Good: Atomic increment
count = state_incr('counter')

# Bad: Race condition
count = state_get('counter') or 0
state_set('counter', count + 1)
```

### 3. Key Naming Convention

```python
# Use structured keys
state_set('user:123:profile', profile)
state_set('cache:product:456', product)
state_set('metric:requests:total', count)
```

### 4. Handle Missing Keys

```python
# state_get returns None for missing keys
value = state_get('maybe_exists')
if value is None:
    value = compute_default()
    state_set('maybe_exists', value)
```

## Next Steps

- [ML Integration](./ml-integration.md) - Caching ML inference
- [Distributed ML Example](../examples/distributed-ml.md) - Cluster inference
- [Erlang API Reference](https://hexdocs.pm/hornbeam) - Erlang modules (hex.pm)
