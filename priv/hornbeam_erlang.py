# Copyright 2026 Benoit Chesneau
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Erlang integration module for hornbeam Python apps.

Provides Python access to Erlang's features:
- Hook registration (register Python handlers during lifespan)
- Shared state (ETS - concurrent reads/writes)
- Distributed calls (RPC to other nodes)
- Pub/Sub messaging
- Dirty execution (execute/stream)

Example:
    from hornbeam_erlang import register_hook, execute, stream, state_incr

    # Register hook during lifespan startup
    register_hook("ml.service", MLServiceInstance)

    # Atomic counter
    views = state_incr(f'views:{path}')

    # Execute action on registered hook (calls Python handler)
    result = execute("ml.service", "predict", data)

    # Stream results
    for chunk in stream("llm.service", "generate", prompt):
        yield chunk
"""

from typing import Any, Callable, Dict, Generator, Iterator, List, Optional, Union

# Try to import erlang module (provided by erlang_python when embedded)
try:
    import erlang as erl
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False

ErlValue = Union[str, int, float, bytes, bool, list, dict, None]


def _call_erlang(name: str, *args) -> Any:
    """Call a registered Erlang function."""
    if not HAS_ERLANG:
        raise RuntimeError("erlang module not available")
    return erl.call(name, *args)


# =============================================================================
# Hook Registration API
# =============================================================================

def register_hook(app_path: str, handler: Any) -> None:
    """Register a Python handler for a hook.

    Use this during ASGI lifespan startup to register handlers that
    can be called via execute/stream from other workers or Erlang.

    The handler can be:
    - A callable (function) that receives (action, args, kwargs)
    - A class (instantiated per call, method = action name)
    - An instance (method = action name)

    Args:
        app_path: App identifier (e.g., "myservice", "ml.inference")
        handler: The handler (callable, class, or instance)

    Example:
        # During ASGI lifespan startup
        async def lifespan(scope, receive, send):
            msg = await receive()
            if msg['type'] == 'lifespan.startup':
                # Register handler
                register_hook("ml.service", MLService())
                await send({'type': 'lifespan.startup.complete'})
            ...

        # Later, from any worker
        result = execute("ml.service", "predict", data)
    """
    # Import here to avoid circular dependency
    import hornbeam_hooks_runner

    # Store handler in Python
    hornbeam_hooks_runner.register_handler(app_path, handler)

    # Tell Erlang this is a Python handler
    _call_erlang('hornbeam_hooks', 'reg_python', [app_path])


def unregister_hook(app_path: str) -> None:
    """Unregister a Python handler.

    Args:
        app_path: App identifier
    """
    import hornbeam_hooks_runner
    hornbeam_hooks_runner.unregister_handler(app_path)
    _call_erlang('hornbeam_hooks', 'unreg', [app_path])


# =============================================================================
# Dirty Execution API (like gunicorn dirty client)
# =============================================================================

def execute(app_path: str, action: str, *args, **kwargs) -> Any:
    """Execute an action on a registered app.

    Calls Erlang's hornbeam_hooks:execute/4 which looks up the handler
    (can be Python or Erlang) and executes it.

    Args:
        app_path: App identifier (e.g., "myapp.ml:MLService")
        action: Action/method name
        *args: Positional arguments
        **kwargs: Keyword arguments

    Returns:
        Result of the action

    Raises:
        RuntimeError: If execution fails

    Example:
        result = execute("myapp.ml:MLService", "inference", data, model="gpt-4")
    """
    result = _call_erlang('hornbeam_hooks_execute',
                          app_path, action, list(args), kwargs)
    if isinstance(result, tuple):
        if result[0] == 'ok':
            return result[1]
        if result[0] == 'error':
            raise RuntimeError(f"Execute failed: {result[1]}")
    return result


def execute_async(app_path: str, action: str, *args, **kwargs) -> str:
    """Execute an action asynchronously.

    Returns a task ID that can be used with await_result().

    Args:
        app_path: App identifier
        action: Action/method name
        *args: Positional arguments
        **kwargs: Keyword arguments

    Returns:
        Task ID (binary string)

    Example:
        task_id = execute_async("myapp.ml:MLService", "train", data)
        # ... do other work ...
        result = await_result(task_id)
    """
    result = _call_erlang('hornbeam_hooks_execute_async',
                          app_path, action, list(args), kwargs)
    if isinstance(result, tuple):
        if result[0] == 'ok':
            return result[1]
        if result[0] == 'error':
            raise RuntimeError(f"Execute async failed: {result[1]}")
    return result


def await_result(task_id: str, timeout_ms: int = 30000) -> Any:
    """Wait for async task result.

    Args:
        task_id: Task ID from execute_async
        timeout_ms: Timeout in milliseconds

    Returns:
        Task result

    Raises:
        RuntimeError: If task failed or timed out
    """
    result = _call_erlang('hornbeam_hooks_await_result', task_id, timeout_ms)
    if isinstance(result, tuple):
        if result[0] == 'ok':
            return result[1]
        if result[0] == 'error':
            raise RuntimeError(f"Await failed: {result[1]}")
    return result


def stream(app_path: str, action: str, *args, **kwargs) -> Generator[Any, None, None]:
    """Stream results from an action.

    Returns a generator that yields chunks from the action.

    Args:
        app_path: App identifier
        action: Action/method name
        *args: Positional arguments
        **kwargs: Keyword arguments

    Yields:
        Chunks from the streaming action

    Example:
        for chunk in stream("myapp.llm:LLMService", "generate", prompt):
            print(chunk, end="", flush=True)
    """
    result = _call_erlang('hornbeam_hooks', 'stream',
                          [app_path, action, list(args), kwargs])

    if isinstance(result, tuple):
        if result[0] == 'error':
            raise RuntimeError(f"Stream failed: {result[1]}")
        if result[0] == 'ok':
            # result[1] is a reference to Erlang generator function
            gen_ref = result[1]
            while True:
                chunk = _call_erlang('hornbeam_hooks', 'stream_next_ref', [gen_ref])
                if chunk == 'done':
                    break
                if isinstance(chunk, tuple):
                    if chunk[0] == 'value':
                        yield chunk[1]
                    elif chunk[0] == 'error':
                        raise RuntimeError(f"Stream error: {chunk[1]}")


async def stream_async(app_path: str, action: str, *args, **kwargs):
    """Async stream results from an action.

    Returns an async generator that yields chunks from the action.

    Args:
        app_path: App identifier
        action: Action/method name
        *args: Positional arguments
        **kwargs: Keyword arguments

    Yields:
        Chunks from the streaming action

    Example:
        async for chunk in stream_async("myapp.llm:LLMService", "generate", prompt):
            print(chunk, end="", flush=True)
    """
    # For now, wrap sync stream - could be optimized with proper async
    for chunk in stream(app_path, action, *args, **kwargs):
        yield chunk


# =============================================================================
# Shared State (ETS)
# =============================================================================

def state_get(key: ErlValue) -> Optional[ErlValue]:
    """Get value from ETS. Returns None if not found."""
    result = _call_erlang('hornbeam_state_get', key)
    return None if result == 'undefined' else result


def state_set(key: ErlValue, value: ErlValue) -> None:
    """Set value in ETS."""
    _call_erlang('hornbeam_state_set', key, value)


def state_delete(key: ErlValue) -> None:
    """Delete key from ETS."""
    _call_erlang('hornbeam_state_delete', key)


def state_incr(key: ErlValue, delta: int = 1) -> int:
    """Atomically increment counter. Returns new value."""
    return _call_erlang('hornbeam_state_incr', key, delta)


def state_decr(key: ErlValue, delta: int = 1) -> int:
    """Atomically decrement counter."""
    return _call_erlang('hornbeam_state_decr', key, delta)


def state_get_multi(keys: List[ErlValue]) -> Dict[ErlValue, ErlValue]:
    """Get multiple keys at once."""
    return _call_erlang('hornbeam_state', 'get_multi', [keys])


def state_keys(prefix: Optional[str] = None) -> List[ErlValue]:
    """Get all keys, optionally filtered by prefix."""
    if prefix is not None:
        return _call_erlang('hornbeam_state', 'keys', [prefix])
    return _call_erlang('hornbeam_state', 'keys', [])


# =============================================================================
# Distributed Erlang
# =============================================================================

def rpc_call(node: str, module: str, function: str, args: list,
             timeout_ms: int = 5000) -> ErlValue:
    """Call function on remote Erlang node.

    Args:
        node: Target node (e.g., 'worker@host2')
        module: Erlang module
        function: Function name
        args: Arguments
        timeout_ms: Timeout

    Returns:
        Function result

    Raises:
        RuntimeError: If RPC fails
    """
    result = _call_erlang('hornbeam_dist', 'rpc_call',
                          [node, module, function, args, timeout_ms])
    if isinstance(result, tuple):
        if result[0] == 'ok':
            return result[1]
        if result[0] == 'error':
            raise RuntimeError(f"RPC failed: {result[1]}")
    return result


def rpc_cast(node: str, module: str, function: str, args: list) -> None:
    """Async call to remote node (fire and forget)."""
    _call_erlang('hornbeam_dist', 'rpc_cast', [node, module, function, args])


def nodes() -> List[str]:
    """Get connected Erlang nodes."""
    return _call_erlang('hornbeam_dist', 'connected_nodes', [])


def node() -> str:
    """Get this node's name."""
    return _call_erlang('hornbeam_dist', 'node', [])


# =============================================================================
# Pub/Sub
# =============================================================================

def publish(topic: str, message: ErlValue) -> int:
    """Publish message to topic. Returns subscriber count."""
    return _call_erlang('hornbeam_pubsub', 'publish', [topic, message])


# =============================================================================
# Erlang Function Calls
# =============================================================================

def call(name: str, *args) -> ErlValue:
    """Call registered Erlang function."""
    result = _call_erlang('hornbeam_callbacks', 'call', [name, list(args)])
    if isinstance(result, tuple):
        if result[0] == 'ok':
            return result[1]
        if result[0] == 'error':
            raise RuntimeError(f"Call failed: {result[1]}")
    return result


def cast(name: str, *args) -> None:
    """Async call to registered Erlang function."""
    _call_erlang('hornbeam_callbacks', 'cast', [name, list(args)])


# =============================================================================
# Shortcuts
# =============================================================================

get = state_get
set = state_set
delete = state_delete
incr = state_incr
decr = state_decr
hook = register_hook
unhook = unregister_hook
