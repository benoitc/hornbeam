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


# Thread-safe app cache to avoid race conditions under concurrent load
_app_cache: Dict[tuple, Any] = {}
_app_cache_lock = threading.Lock()

# Persistent event loop per thread (reused across requests)
_thread_local = threading.local()


def _get_event_loop() -> asyncio.AbstractEventLoop:
    """Get or create a persistent event loop for this thread.

    Reusing the event loop avoids the overhead of creating a new one
    for each request, which is a major performance bottleneck.
    """
    loop = getattr(_thread_local, 'loop', None)
    if loop is None or loop.is_closed():
        # Try to use uvloop if available for better performance
        try:
            import uvloop
            loop = uvloop.new_event_loop()
        except ImportError:
            loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        _thread_local.loop = loop
    return loop


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
    """
    cache_key = (module_name, callable_name)
    with _app_cache_lock:
        # Remove from cache
        _app_cache.pop(cache_key, None)
        # Reload module
        if module_name in sys.modules:
            module = importlib.reload(sys.modules[module_name])
        else:
            module = importlib.import_module(module_name)
        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


class ASGIResponse:
    """Collects ASGI response messages.

    Supports:
    - http.response.start: Initial status and headers
    - http.response.body: Body chunks with more_body flag
    - http.response.informational: 1xx responses (103 Early Hints)
    - http.response.trailers: HTTP/2 trailers
    """

    def __init__(self):
        self.status: Optional[int] = None
        self.headers: List = []
        self.body_parts: List[bytes] = []
        self.more_body: bool = False
        self.informational: List[Dict] = []  # 1xx responses
        self.trailers: List = []
        self.early_hints: List = []

    async def send(self, message: dict) -> None:
        """ASGI send callable."""
        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            self.status = message.get('status', 200)
            self.headers = message.get('headers', [])

        elif msg_type == 'http.response.body':
            body_part = message.get('body', b'')
            if isinstance(body_part, bytes):
                self.body_parts.append(body_part)
            elif isinstance(body_part, str):
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


async def _run_asgi_async(module_name: str, callable_name: str,
                          scope: dict, body: bytes) -> dict:
    """Internal async runner for ASGI apps."""
    # Load the application
    app = load_app(module_name, callable_name)

    # Use Python-side lifespan state for ASGI compliance
    # This ensures scope['state'] is the same dict across all requests
    try:
        from hornbeam_lifespan_runner import get_state
        scope['state'] = get_state()
    except ImportError:
        # Lifespan runner not available, use whatever was passed
        pass

    # Ensure body is bytes
    if isinstance(body, str):
        body = body.encode('utf-8')
    elif not isinstance(body, bytes):
        body = b''

    # Create receive callable
    body_sent = False

    async def receive():
        nonlocal body_sent
        if not body_sent:
            body_sent = True
            return {
                'type': 'http.request',
                'body': body,
                'more_body': False
            }
        return {'type': 'http.disconnect'}

    # Create response collector
    response = ASGIResponse()

    # Run the app
    await app(scope, receive, response.send)

    return response.to_dict()


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
    # Reuse persistent event loop for this thread (major perf improvement)
    loop = _get_event_loop()
    return loop.run_until_complete(
        _run_asgi_async(module_name, callable_name, scope, body)
    )


# Streaming support for real-time responses


class StreamingASGIRunner:
    """Runner for streaming ASGI responses.

    This class supports:
    - Server-Sent Events (SSE)
    - Chunked transfer encoding
    - Real-time response streaming
    """

    def __init__(self, module_name: str, callable_name: str, scope: dict):
        self.module_name = module_name
        self.callable_name = callable_name
        self.scope = scope
        self.app = None
        self.response_started = False
        self.status = None
        self.headers = []
        self.body_queue: asyncio.Queue = None
        self.finished = False
        self.loop = None

    def start(self, body: bytes) -> dict:
        """Start the streaming response.

        Returns the initial response headers.
        """
        self.app = load_app(self.module_name, self.callable_name)
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.body_queue = asyncio.Queue()

        # Create receive/send callables
        body_sent = False

        async def receive():
            nonlocal body_sent
            if not body_sent:
                body_sent = True
                return {
                    'type': 'http.request',
                    'body': body,
                    'more_body': False
                }
            return {'type': 'http.disconnect'}

        async def send(message):
            msg_type = message.get('type', '')
            if msg_type == 'http.response.start':
                self.response_started = True
                self.status = message.get('status', 200)
                self.headers = message.get('headers', [])
            elif msg_type == 'http.response.body':
                body_part = message.get('body', b'')
                more_body = message.get('more_body', False)
                await self.body_queue.put((body_part, more_body))
                if not more_body:
                    self.finished = True

        # Start app in background
        async def run_app():
            try:
                await self.app(self.scope, receive, send)
            except Exception as e:
                await self.body_queue.put((b'', False))
                self.finished = True

        self.loop.create_task(run_app())

        # Wait for response to start
        for _ in range(1000):  # Max iterations
            self.loop.run_until_complete(asyncio.sleep(0.001))
            if self.response_started:
                break

        return {
            'status': self.status or 500,
            'headers': self.headers
        }

    def next_chunk(self, timeout_ms: int = 30000) -> tuple:
        """Get the next body chunk.

        Returns (chunk_bytes, more_body_bool)
        """
        if self.finished or self.loop is None:
            return (b'', False)

        try:
            timeout_sec = timeout_ms / 1000.0
            future = asyncio.wait_for(
                self.body_queue.get(),
                timeout=timeout_sec
            )
            chunk, more_body = self.loop.run_until_complete(future)
            return (chunk, more_body)
        except asyncio.TimeoutError:
            return (b'', True)  # Timeout, but may have more
        except Exception:
            return (b'', False)

    def close(self):
        """Clean up resources."""
        if self.loop:
            self.loop.close()
            self.loop = None


# Module-level streaming session storage
_streaming_sessions: Dict[str, StreamingASGIRunner] = {}


def start_streaming(session_id: str, module_name: str, callable_name: str,
                    scope: dict, body: bytes) -> dict:
    """Start a streaming ASGI response session.

    Returns initial response headers.
    """
    runner = StreamingASGIRunner(module_name, callable_name, scope)
    _streaming_sessions[session_id] = runner

    if isinstance(body, str):
        body = body.encode('utf-8')
    elif not isinstance(body, bytes):
        body = b''

    return runner.start(body)


def get_streaming_chunk(session_id: str, timeout_ms: int = 30000) -> dict:
    """Get the next chunk from a streaming session.

    Returns {'chunk': bytes, 'more_body': bool}
    """
    runner = _streaming_sessions.get(session_id)
    if runner is None:
        return {'chunk': b'', 'more_body': False, 'error': 'session_not_found'}

    chunk, more_body = runner.next_chunk(timeout_ms)
    return {'chunk': chunk, 'more_body': more_body}


def end_streaming(session_id: str) -> None:
    """End a streaming session and clean up resources."""
    runner = _streaming_sessions.pop(session_id, None)
    if runner:
        runner.close()
