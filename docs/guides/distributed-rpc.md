---
title: Distributed RPC
description: Call functions across Erlang cluster nodes
order: 16
---

# Distributed RPC

Hornbeam leverages Erlang's built-in distribution to call functions across cluster nodes. This enables:

- **Distributed ML inference:** Send computations to GPU nodes
- **Load distribution:** Spread work across workers
- **Service isolation:** Keep heavy processing on dedicated nodes
- **Fault tolerance:** Failover to backup nodes

## Cluster Setup

### Node Configuration

Each Erlang node needs a name and cookie:

```bash
# Start nodes with names
erl -name web@192.168.1.10 -setcookie mysecret
erl -name gpu@192.168.1.20 -setcookie mysecret
erl -name db@192.168.1.30 -setcookie mysecret
```

Or via `vm.args`:

```
## vm.args
-name hornbeam@192.168.1.10
-setcookie mysecret
+K true
+A 128
```

### Connecting Nodes

Nodes connect automatically when you first communicate:

```erlang
%% From web node, connect to gpu node
net_adm:ping('gpu@192.168.1.20').
%% pong = connected, pang = failed
```

Or use Hornbeam's API:

```python
from hornbeam_erlang import nodes, node
from hornbeam_dist import connect, ping

# Check current node
print(f"This node: {node()}")

# Connect to GPU node
connect('gpu@192.168.1.20')

# Check connection
print(ping('gpu@192.168.1.20'))  # 'pong' or 'pang'

# List all connected nodes
print(nodes())
```

## Basic RPC

### Synchronous Calls

```python
from hornbeam_erlang import rpc_call

# Call function on remote node
result = rpc_call(
    'worker@gpu-server',    # Node
    'ml_model',             # Module
    'predict',              # Function
    [input_data],           # Args (as list)
    timeout_ms=30000        # Timeout
)
```

### Asynchronous Calls

Fire and forget - don't wait for result:

```python
from hornbeam_erlang import rpc_cast

# Log to remote server (non-blocking)
rpc_cast(
    'logger@log-server',
    'event_logger',
    'log',
    ['info', 'User logged in', {'user_id': 123}]
)
```

## Distributed ML Patterns

### GPU Node for Inference

```python
# Python app on web node
from hornbeam_erlang import rpc_call, nodes

def get_embedding(text):
    """Get embedding from GPU node."""
    gpu_nodes = [n for n in nodes() if 'gpu' in n]

    if not gpu_nodes:
        raise RuntimeError("No GPU nodes available")

    return rpc_call(
        gpu_nodes[0],
        'embedding_service',
        'encode',
        [text],
        timeout_ms=10000
    )
```

```erlang
%% embedding_service.erl on GPU node
-module(embedding_service).
-export([encode/1, batch_encode/1]).

encode(Text) ->
    %% Call Python model via py module
    py:call(embedding_model, encode, [Text]).

batch_encode(Texts) ->
    py:call(embedding_model, batch_encode, [Texts]).
```

### Load Balancing

Distribute requests across workers:

```python
from hornbeam_erlang import rpc_call, nodes
import random

def balanced_inference(data):
    """Round-robin across worker nodes."""
    workers = [n for n in nodes() if 'worker' in n]

    if not workers:
        return local_inference(data)

    # Random selection (simple load balancing)
    node = random.choice(workers)

    try:
        return rpc_call(node, 'inference', 'run', [data], 30000)
    except Exception:
        # Failover to another node
        workers.remove(node)
        if workers:
            return rpc_call(workers[0], 'inference', 'run', [data], 30000)
        return local_inference(data)
```

### Parallel Distributed Processing

```python
from hornbeam_erlang import rpc_call, nodes
from concurrent.futures import ThreadPoolExecutor, as_completed

def parallel_inference(items):
    """Process items in parallel across nodes."""
    workers = [n for n in nodes() if 'worker' in n]

    if not workers:
        # Local processing
        return [process(item) for item in items]

    # Distribute items across workers
    chunks = split_list(items, len(workers))
    results = []

    with ThreadPoolExecutor(max_workers=len(workers)) as executor:
        futures = {}
        for node, chunk in zip(workers, chunks):
            future = executor.submit(
                rpc_call,
                node,
                'batch_processor',
                'process_batch',
                [chunk],
                60000
            )
            futures[future] = node

        for future in as_completed(futures):
            try:
                result = future.result()
                results.extend(result)
            except Exception as e:
                print(f"Node {futures[future]} failed: {e}")

    return results
```

## Erlang-Side Patterns

### Service Discovery

```erlang
%% Find nodes by role
-module(cluster).
-export([gpu_nodes/0, worker_nodes/0, find_node/1]).

gpu_nodes() ->
    [N || N <- nodes(), is_gpu_node(N)].

worker_nodes() ->
    [N || N <- nodes(), is_worker_node(N)].

is_gpu_node(Node) ->
    case atom_to_list(Node) of
        "gpu" ++ _ -> true;
        _ -> false
    end.

is_worker_node(Node) ->
    case atom_to_list(Node) of
        "worker" ++ _ -> true;
        _ -> false
    end.

find_node(Role) when is_atom(Role) ->
    Pattern = atom_to_list(Role),
    Nodes = [N || N <- nodes(),
             lists:prefix(Pattern, atom_to_list(N))],
    case Nodes of
        [] -> {error, no_nodes};
        [H|_] -> {ok, H}
    end.
```

### Distributed Task Queue

```erlang
%% task_queue.erl
-module(task_queue).
-export([submit/2, get_result/1]).

submit(Task, Opts) ->
    Workers = cluster:worker_nodes(),
    Worker = select_worker(Workers, Opts),
    TaskId = make_task_id(),

    %% Send to worker
    rpc:cast(Worker, task_worker, execute, [TaskId, Task]),

    %% Store pending task
    hornbeam_state:set(<<"task:", TaskId/binary>>, #{
        status => pending,
        worker => Worker,
        submitted => erlang:system_time(second)
    }),

    {ok, TaskId}.

get_result(TaskId) ->
    case hornbeam_state:get(<<"task:", TaskId/binary>>) of
        #{status := completed, result := Result} ->
            {ok, Result};
        #{status := pending} ->
            {error, pending};
        #{status := failed, error := Error} ->
            {error, Error};
        undefined ->
            {error, not_found}
    end.

select_worker(Workers, #{prefer_gpu := true}) ->
    case [W || W <- Workers, cluster:is_gpu_node(W)] of
        [] -> hd(Workers);
        GpuWorkers -> hd(GpuWorkers)
    end;
select_worker(Workers, _) ->
    %% Round-robin (use process dictionary for state)
    Index = case get(worker_index) of
        undefined -> 0;
        I -> (I + 1) rem length(Workers)
    end,
    put(worker_index, Index),
    lists:nth(Index + 1, Workers).
```

## Error Handling

### Timeout Handling

```python
from hornbeam_erlang import rpc_call

def safe_rpc(node, module, function, args, timeout=5000, retries=3):
    """RPC with retry logic."""
    last_error = None

    for attempt in range(retries):
        try:
            return rpc_call(node, module, function, args, timeout)
        except TimeoutError:
            last_error = TimeoutError(f"Timeout after {timeout}ms")
            timeout = int(timeout * 1.5)  # Exponential backoff
        except ConnectionError as e:
            last_error = e
            time.sleep(0.1 * (attempt + 1))

    raise last_error
```

### Failover

```python
from hornbeam_erlang import rpc_call, nodes, ping

def resilient_call(service, function, args, timeout=10000):
    """Call with automatic failover."""
    service_nodes = [n for n in nodes() if service in n]

    for node in service_nodes:
        if ping(node) != 'pong':
            continue

        try:
            return rpc_call(node, service, function, args, timeout)
        except Exception as e:
            print(f"Node {node} failed: {e}")
            continue

    raise RuntimeError(f"All {service} nodes unavailable")
```

### Circuit Breaker

```python
from hornbeam_erlang import rpc_call, state_get, state_set, state_incr
import time

class CircuitBreaker:
    def __init__(self, node, threshold=5, reset_timeout=60):
        self.node = node
        self.threshold = threshold
        self.reset_timeout = reset_timeout
        self.key = f"circuit:{node}"

    def is_open(self):
        state = state_get(self.key)
        if not state:
            return False

        if state.get('open'):
            # Check if reset timeout passed
            if time.time() - state.get('opened_at', 0) > self.reset_timeout:
                state_set(self.key, {'failures': 0, 'open': False})
                return False
            return True
        return False

    def record_failure(self):
        failures = state_incr(f"{self.key}:failures")
        if failures >= self.threshold:
            state_set(self.key, {
                'open': True,
                'opened_at': time.time(),
                'failures': failures
            })

    def record_success(self):
        state_set(self.key, {'failures': 0, 'open': False})

    def call(self, module, function, args, timeout=5000):
        if self.is_open():
            raise RuntimeError(f"Circuit open for {self.node}")

        try:
            result = rpc_call(self.node, module, function, args, timeout)
            self.record_success()
            return result
        except Exception as e:
            self.record_failure()
            raise
```

## Monitoring

### Node Health

```python
from hornbeam_erlang import nodes, rpc_call

def cluster_health():
    """Check health of all nodes."""
    health = {}

    for node in nodes():
        try:
            # Call health check on each node
            status = rpc_call(node, 'health', 'check', [], 5000)
            health[node] = {'status': 'healthy', **status}
        except TimeoutError:
            health[node] = {'status': 'timeout'}
        except Exception as e:
            health[node] = {'status': 'error', 'error': str(e)}

    return health
```

### Metrics Collection

```erlang
%% Collect metrics from all nodes
collect_cluster_metrics() ->
    Nodes = nodes(),
    Metrics = lists:map(fun(Node) ->
        case rpc:call(Node, metrics, get_all, [], 5000) of
            {badrpc, Reason} ->
                {Node, {error, Reason}};
            Result ->
                {Node, Result}
        end
    end, Nodes),
    maps:from_list(Metrics).
```

## Best Practices

### 1. Use Appropriate Timeouts

```python
# Short timeout for health checks
ping_result = rpc_call(node, 'health', 'ping', [], timeout_ms=1000)

# Longer timeout for ML inference
embedding = rpc_call(gpu_node, 'ml', 'encode', [text], timeout_ms=30000)

# Very long timeout for training
rpc_call(gpu_node, 'ml', 'train', [dataset], timeout_ms=3600000)
```

### 2. Batch Operations

```python
# Bad: Many small calls
embeddings = []
for text in texts:
    emb = rpc_call(node, 'ml', 'encode', [text], 5000)
    embeddings.append(emb)

# Good: Single batch call
embeddings = rpc_call(node, 'ml', 'batch_encode', [texts], 30000)
```

### 3. Local Fallback

```python
def get_embedding(text):
    gpu_nodes = [n for n in nodes() if 'gpu' in n]

    if gpu_nodes:
        try:
            return rpc_call(gpu_nodes[0], 'ml', 'encode', [text], 10000)
        except Exception:
            pass

    # Local fallback
    return local_model.encode(text)
```

### 4. Fire-and-Forget for Logging

```python
from hornbeam_erlang import rpc_cast

# Don't wait for logging
rpc_cast('logger@server', 'audit_log', 'record', [
    'user_action',
    {'user_id': user_id, 'action': 'login', 'ip': ip}
])
```

## See Also

- [Erlang API Reference](https://hexdocs.pm/hornbeam) - `hornbeam_dist` module (hex.pm)
- [Python API Reference](../reference/python-api) - RPC functions
- [Distributed ML Example](../examples/distributed-ml) - Complete example
- [Custom Apps Guide](./custom-apps) - Building applications
