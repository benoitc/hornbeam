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

"""ASGI runner module for hornbeam.

This module handles calling ASGI applications from Erlang with full
support for streaming responses, informational responses, and trailers.
"""

import asyncio
import importlib
import sys
import threading
from typing import List, Dict, Any, Optional


# Install erlang event loop as the default event loop policy (once per interpreter)
def _install_erlang_loop() -> bool:
    """Install erlang event loop as the default asyncio event loop policy."""
    try:
        from erlang_loop import get_event_loop_policy
        asyncio.set_event_loop_policy(get_event_loop_policy())
        return True
    except (ImportError, AttributeError, RuntimeError):
        return False


_install_erlang_loop()


# Cache lifespan state getter at module level (avoid import on every request)
_get_lifespan_state = None


def _init_lifespan_getter():
    global _get_lifespan_state
    try:
        from hornbeam_lifespan_runner import get_state
        _get_lifespan_state = get_state
    except ImportError:
        _get_lifespan_state = None


_init_lifespan_getter()


# Check if _erlang_sleep is available
_has_erlang_sleep = False
_erlang_sleep = None


def _init_erlang_sleep():
    global _has_erlang_sleep, _erlang_sleep
    try:
        import py_event_loop as pel
        if hasattr(pel, '_erlang_sleep'):
            _erlang_sleep = pel._erlang_sleep
            _has_erlang_sleep = True
    except ImportError:
        pass


_init_erlang_sleep()


def _is_asyncio_sleep_coro(coro) -> bool:
    """Check if a coroutine is asyncio.sleep()."""
    try:
        if coro.cr_frame is None:
            return False
        code = coro.cr_frame.f_code
        return (code.co_name == 'sleep' and 'asyncio' in code.co_filename)
    except (AttributeError, TypeError):
        return False


def _extract_sleep_delay(coro) -> float:
    """Extract delay value from asyncio.sleep coroutine."""
    try:
        if coro.cr_frame is None:
            return -1
        delay = coro.cr_frame.f_locals.get('delay', -1)
        if isinstance(delay, (int, float)) and delay >= 0:
            return float(delay)
        return -1
    except (AttributeError, TypeError, KeyError):
        return -1


# Pre-allocated message templates
_DISCONNECT_MSG = {'type': 'http.disconnect'}


def get_event_loop_info() -> dict:
    """Get information about the current event loop for debugging."""
    loop = _get_event_loop()
    return {
        'loop_type': type(loop).__name__,
        'loop_module': type(loop).__module__,
        'policy_type': type(asyncio.get_event_loop_policy()).__name__,
    }


# Thread-safe app cache to avoid race conditions under concurrent load
_app_cache: Dict[tuple, Any] = {}
_app_cache_lock = threading.Lock()

# Per-app execution mode cache: 'fast' (default) or 'loop'
# Apps that need the event loop are cached as 'loop' to skip fast path overhead
_app_execution_mode: Dict[tuple, str] = {}
_EXEC_MODE_FAST = 'fast'
_EXEC_MODE_LOOP = 'loop'

# Persistent event loop per thread (reused across requests)
_thread_local = threading.local()

# Global persistent loop for high-performance mode
_persistent_loop: Optional[asyncio.AbstractEventLoop] = None
_persistent_loop_thread: Optional[threading.Thread] = None
_persistent_loop_lock = threading.Lock()
_persistent_loop_ready = threading.Event()  # Signals when loop is running
_use_persistent_loop = True  # Enable by default for better performance


def _get_event_loop() -> asyncio.AbstractEventLoop:
    """Get or create a persistent event loop for this thread.

    Reusing the event loop avoids the overhead of creating a new one
    for each request, which is a major performance bottleneck.

    Note: The erlang event loop is installed as the default policy at module
    import, so asyncio.new_event_loop() automatically creates ErlangEventLoop
    instances that integrate with Erlang's scheduler.
    """
    loop = getattr(_thread_local, 'loop', None)
    if loop is None or loop.is_closed():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        _thread_local.loop = loop
    return loop


def _get_persistent_loop() -> asyncio.AbstractEventLoop:
    """Get or create a persistent running event loop.

    This loop runs continuously in a background thread, allowing
    tasks to be submitted without run_until_complete() overhead.
    """
    global _persistent_loop, _persistent_loop_thread

    if _persistent_loop is not None and _persistent_loop.is_running():
        return _persistent_loop

    with _persistent_loop_lock:
        # Double-check after acquiring lock
        if _persistent_loop is not None and _persistent_loop.is_running():
            return _persistent_loop

        # Clear ready event for new loop startup
        _persistent_loop_ready.clear()

        # Create new loop
        _persistent_loop = asyncio.new_event_loop()

        def run_loop():
            asyncio.set_event_loop(_persistent_loop)
            # Signal that the loop is about to start
            _persistent_loop.call_soon(_persistent_loop_ready.set)
            _persistent_loop.run_forever()

        _persistent_loop_thread = threading.Thread(
            target=run_loop,
            daemon=True,
            name="asgi-loop"
        )
        _persistent_loop_thread.start()

        # Wait for loop to start (event-driven, not busy-spin)
        _persistent_loop_ready.wait(timeout=5.0)

        return _persistent_loop


def _run_in_persistent_loop(coro) -> Any:
    """Run a coroutine in the persistent loop and wait for result.

    This is faster than run_until_complete() because:
    1. The loop is already running (no startup overhead)
    2. Uses run_coroutine_threadsafe which is optimized for this pattern
    """
    loop = _get_persistent_loop()
    future = asyncio.run_coroutine_threadsafe(coro, loop)
    return future.result()  # Block until done


class _NeedEventLoop(Exception):
    """Raised when fast path cannot handle an awaitable."""
    pass


def _run_coro_fast(coro):
    """Fast coroutine runner for simple ASGI apps.

    Manually steps through the coroutine without creating a Task.
    Raises _NeedEventLoop for complex async operations.

    This optimization works because most ASGI request handlers:
    1. Only await receive() once (for body)
    2. Call send() a few times (start + body)
    3. Don't do real async I/O

    For these simple cases, we avoid Task creation overhead entirely.

    When _erlang_sleep is available, asyncio.sleep() calls are intercepted
    and executed using Erlang's native timer for ~8x better performance.
    """
    try:
        # Start the coroutine
        awaitable = coro.send(None)

        # Keep stepping through awaitables
        while True:
            # Check if it's a simple awaitable we can resolve directly
            if hasattr(awaitable, 'send'):
                # Check if it's asyncio.sleep - intercept and use Erlang timer
                if _has_erlang_sleep and _is_asyncio_sleep_coro(awaitable):
                    delay = _extract_sleep_delay(awaitable)
                    if delay >= 0:
                        awaitable.close()
                        if delay > 0:
                            delay_ms = int(delay * 1000)
                            if delay_ms < 1:
                                delay_ms = 1
                            _erlang_sleep(delay_ms)
                        awaitable = coro.send(None)
                        continue

                # It's a coroutine - step into it
                try:
                    inner = awaitable.send(None)
                    # If inner returns immediately, continue outer
                    if inner is None:
                        awaitable = coro.send(None)
                    else:
                        # Chain the inner coroutine (only one level deep)
                        while hasattr(inner, 'send'):
                            # Check for nested asyncio.sleep
                            if _has_erlang_sleep and _is_asyncio_sleep_coro(inner):
                                delay = _extract_sleep_delay(inner)
                                if delay >= 0:
                                    inner.close()
                                    if delay > 0:
                                        delay_ms = int(delay * 1000)
                                        if delay_ms < 1:
                                            delay_ms = 1
                                        _erlang_sleep(delay_ms)
                                    inner = None
                                    break
                            try:
                                inner = inner.send(None)
                            except StopIteration as e:
                                inner = e.value
                                break
                        if inner is not None and not isinstance(inner, (int, str, bytes, bool, type(None))):
                            # Complex result - needs event loop
                            raise _NeedEventLoop()
                        awaitable = coro.send(inner)
                except StopIteration as e:
                    # Inner coroutine completed
                    awaitable = coro.send(e.value)
            elif awaitable is None:
                # Simple None yield - continue
                awaitable = coro.send(None)
            else:
                # Complex awaitable (Future, Task, asyncio.sleep, etc.)
                raise _NeedEventLoop()

    except StopIteration as e:
        return e.value


def load_app(module_name: str, callable_name: str):
    """Load an ASGI application with thread-safe caching."""
    cache_key = (module_name, callable_name)

    # Fast path: check cache without lock
    if cache_key in _app_cache:
        return _app_cache[cache_key]

    # Slow path: acquire lock and load
    with _app_cache_lock:
        # Double-check after acquiring lock
        if cache_key in _app_cache:
            return _app_cache[cache_key]

        # Import module (don't delete from sys.modules - causes race conditions)
        if module_name not in sys.modules:
            module = importlib.import_module(module_name)
        else:
            module = sys.modules[module_name]

        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


def reload_app(module_name: str, callable_name: str):
    """Force reload an ASGI application.

    Use this when the application code has changed on disk.
    Also clears the cached execution mode so the app is re-evaluated.
    """
    cache_key = (module_name, callable_name)
    with _app_cache_lock:
        # Remove from cache
        _app_cache.pop(cache_key, None)
        # Clear execution mode so it's re-evaluated after reload
        _app_execution_mode.pop(cache_key, None)
        # Reload module
        if module_name in sys.modules:
            module = importlib.reload(sys.modules[module_name])
        else:
            module = importlib.import_module(module_name)
        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


# Response object pool for reuse
_RESPONSE_POOL = []
_RESPONSE_POOL_SIZE = 100
_RESPONSE_POOL_LOCK = threading.Lock()


class ASGIResponse:
    """Collects ASGI response messages.

    Supports:
    - http.response.start: Initial status and headers
    - http.response.body: Body chunks with more_body flag
    - http.response.informational: 1xx responses (103 Early Hints)
    - http.response.trailers: HTTP/2 trailers
    """
    __slots__ = ('status', 'headers', 'body_parts', 'more_body',
                 'informational', 'trailers', 'early_hints')

    def __init__(self):
        self.status = None
        self.headers = []
        self.body_parts = []
        self.more_body = False
        self.informational = []
        self.trailers = []
        self.early_hints = []

    def reset(self):
        """Reset response for reuse from pool."""
        self.status = None
        self.headers = []
        self.body_parts = []
        self.more_body = False
        self.informational = []
        self.trailers = []
        self.early_hints = []

    async def send(self, message: dict) -> None:
        """ASGI send callable."""
        msg_type = message['type'] if 'type' in message else ''

        if msg_type == 'http.response.start':
            self.status = message.get('status', 200)
            self.headers = message.get('headers', [])

        elif msg_type == 'http.response.body':
            body_part = message.get('body', b'')
            if body_part.__class__ is bytes:
                self.body_parts.append(body_part)
            elif body_part.__class__ is str:
                self.body_parts.append(body_part.encode('utf-8'))
            self.more_body = message.get('more_body', False)

        elif msg_type == 'http.response.informational':
            # 1xx informational responses (e.g., 103 Early Hints)
            status = message.get('status', 100)
            headers = message.get('headers', [])
            self.informational.append({
                'status': status,
                'headers': headers
            })
            # Track early hints specifically
            if status == 103:
                self.early_hints.append(headers)

        elif msg_type == 'http.response.trailers':
            # HTTP/2 trailers
            self.trailers = message.get('headers', [])

    def to_dict(self) -> dict:
        """Convert response to dict for Erlang."""
        result = {
            'status': self.status or 500,
            'headers': self.headers,
            'body': b''.join(self.body_parts),
        }

        if self.early_hints:
            result['early_hints'] = self.early_hints

        if self.informational:
            result['informational'] = self.informational

        if self.trailers:
            result['trailers'] = self.trailers

        return result


def _get_response() -> ASGIResponse:
    """Get an ASGIResponse from pool or create new."""
    with _RESPONSE_POOL_LOCK:
        if _RESPONSE_POOL:
            resp = _RESPONSE_POOL.pop()
            resp.reset()
            return resp
    return ASGIResponse()


def _return_response(resp: ASGIResponse) -> None:
    """Return an ASGIResponse to the pool."""
    with _RESPONSE_POOL_LOCK:
        if len(_RESPONSE_POOL) < _RESPONSE_POOL_SIZE:
            _RESPONSE_POOL.append(resp)


async def _run_asgi_async(module_name: str, callable_name: str,
                          scope: dict, body: bytes) -> dict:
    """Internal async runner for ASGI apps."""
    # Load the application
    app = load_app(module_name, callable_name)

    # Use cached lifespan state getter
    if _get_lifespan_state is not None:
        scope['state'] = _get_lifespan_state()

    # Ensure body is bytes
    if body.__class__ is str:
        body = body.encode('utf-8')
    elif body.__class__ is not bytes:
        body = b''

    # Create response collector and receive callable
    response = ASGIResponse()
    receive = _ReceiveCallable(body)

    # Run the app
    await app(scope, receive, response.send)

    return response.to_dict()


class _ReceiveCallable:
    """Optimized receive callable - avoids closure creation per request."""
    __slots__ = ('body', 'body_sent', '_request_msg')

    def __init__(self, body: bytes):
        self.body = body
        self.body_sent = False
        self._request_msg = {
            'type': 'http.request',
            'body': body,
            'more_body': False
        }

    async def __call__(self):
        if not self.body_sent:
            self.body_sent = True
            return self._request_msg
        return _DISCONNECT_MSG


def run_asgi(module_name: str, callable_name: str,
             scope: dict, body: bytes) -> dict:
    """Run an ASGI application and return the response.

    Args:
        module_name: Python module containing the ASGI app
        callable_name: Name of the ASGI callable in the module
        scope: ASGI scope dict
        body: Request body bytes

    Returns:
        Dict with status, headers, body, and optional early_hints/trailers
    """
    cache_key = (module_name, callable_name)

    # Load the application
    app = load_app(module_name, callable_name)

    # Use cached lifespan state getter (avoid import on every request)
    if _get_lifespan_state is not None:
        scope['state'] = _get_lifespan_state()

    # Ensure body is bytes
    if body.__class__ is str:
        body = body.encode('utf-8')
    elif body.__class__ is not bytes:
        body = b''

    # Create response collector and receive callable
    response = ASGIResponse()
    receive = _ReceiveCallable(body)

    # Check cached execution mode for this app
    exec_mode = _app_execution_mode.get(cache_key, _EXEC_MODE_FAST)

    if exec_mode == _EXEC_MODE_LOOP:
        # App is known to need event loop - skip fast path entirely
        coro = app(scope, receive, response.send)
        if _use_persistent_loop:
            try:
                _run_in_persistent_loop(coro)
            except Exception:
                # Fallback to per-thread loop on persistent loop failure
                response = ASGIResponse()
                receive = _ReceiveCallable(body)
                coro = app(scope, receive, response.send)
                loop = _get_event_loop()
                loop.run_until_complete(coro)
        else:
            loop = _get_event_loop()
            loop.run_until_complete(coro)
    else:
        # Try fast path first (avoids Task creation for simple apps)
        coro = app(scope, receive, response.send)
        try:
            _run_coro_fast(coro)
        except (_NeedEventLoop, RuntimeError) as e:
            # Fast path can't handle this app - needs real async
            # RuntimeError with "no running event loop" happens when code
            # calls asyncio.sleep(), asyncio.gather(), etc.
            if isinstance(e, RuntimeError) and "no running event loop" not in str(e):
                raise  # Re-raise other RuntimeErrors

            # Cache this app as needing the event loop
            _app_execution_mode[cache_key] = _EXEC_MODE_LOOP

            # Only safe to retry if no response has been sent yet
            if response.status is None:
                # Clean slate - recreate everything
                response = ASGIResponse()
                receive = _ReceiveCallable(body)
                coro = app(scope, receive, response.send)
                loop = _get_event_loop()
                loop.run_until_complete(coro)
            else:
                # Response already started - can't retry safely
                # Just return what we have (partial response)
                pass

    return response.to_dict()


def _run_asgi_sync(module_name: str, callable_name: str,
                   scope: dict, body: bytes) -> tuple:
    """Optimized ASGI runner called by py_asgi NIF.

    This function is called directly from the C NIF for maximum performance.
    Returns a tuple (status, headers, body) for efficient NIF marshalling,
    avoiding the overhead of dict creation and key lookups.

    Args:
        module_name: Python module containing the ASGI app
        callable_name: Name of the ASGI callable in the module
        scope: ASGI scope dict (already built by NIF with interned keys)
        body: Request body bytes

    Returns:
        Tuple of (status: int, headers: list, body: bytes)
    """
    result = run_asgi(module_name, callable_name, scope, body)
    return (
        result.get('status', 500),
        result.get('headers', []),
        result.get('body', b'')
    )
