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

"""Channel-based ASGI worker for hornbeam.

This module provides a high-performance ASGI worker that uses channels
for communication with Erlang. It supports:

- Async task execution with event loop integration
- Streaming responses via channel
- Long-lived tasks handling multiple requests

Flow:
1. Erlang creates channel, sends scope/body, calls handle_request
2. Python receives request from channel
3. Python processes request with ASGI app
4. Python sends response back via reply() to caller
"""

import asyncio
import importlib
import sys
import threading
from typing import Any, Callable, Dict, List, Optional, Tuple

# Install erlang event loop policy
try:
    from erlang_loop import get_event_loop_policy
    asyncio.set_event_loop_policy(get_event_loop_policy())
except (ImportError, RuntimeError):
    pass

try:
    import erlang
    from erlang import Channel, ChannelClosed, reply
    HAS_ERLANG = True
except ImportError:
    HAS_ERLANG = False


# Thread-safe app cache
_app_cache: Dict[Tuple[str, str], Callable] = {}
_app_cache_lock = threading.Lock()

# Thread-local event loop
_thread_local = threading.local()


def _get_event_loop() -> asyncio.AbstractEventLoop:
    """Get or create a persistent event loop for this thread."""
    loop = getattr(_thread_local, 'loop', None)
    if loop is None or loop.is_closed():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        _thread_local.loop = loop
    return loop


def _load_app(module_name: str, callable_name: str) -> Callable:
    """Load an ASGI application with thread-safe caching."""
    cache_key = (module_name, callable_name)

    if cache_key in _app_cache:
        return _app_cache[cache_key]

    with _app_cache_lock:
        if cache_key in _app_cache:
            return _app_cache[cache_key]

        if module_name not in sys.modules:
            module = importlib.import_module(module_name)
        else:
            module = sys.modules[module_name]

        app = getattr(module, callable_name)
        _app_cache[cache_key] = app
        return app


def _to_str(val) -> str:
    """Convert bytes/None to string."""
    if val is None:
        return ''
    if isinstance(val, bytes):
        return val.decode('utf-8', errors='replace')
    return str(val) if not isinstance(val, str) else val


# Pre-allocated message
_DISCONNECT_MSG = {'type': 'http.disconnect'}


class _ASGIResponse:
    """Collects ASGI response messages."""
    __slots__ = ('status', 'headers', 'body_parts', 'more_body',
                 'early_hints', 'streaming')

    def __init__(self):
        self.status = None
        self.headers = []
        self.body_parts = []
        self.more_body = False
        self.early_hints = []
        self.streaming = False

    async def send(self, message: dict) -> None:
        """ASGI send callable."""
        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            self.status = message.get('status', 200)
            self.headers = message.get('headers', [])

        elif msg_type == 'http.response.body':
            body_part = message.get('body', b'')
            if isinstance(body_part, str):
                body_part = body_part.encode('utf-8')
            if body_part:
                self.body_parts.append(body_part)
            self.more_body = message.get('more_body', False)

        elif msg_type == 'http.response.informational':
            status = message.get('status', 100)
            headers = message.get('headers', [])
            if status == 103:
                self.early_hints.append(headers)


class _ReceiveCallable:
    """Optimized receive callable for ASGI."""
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


class _StreamingResponse:
    """Response handler that streams chunks to Erlang."""
    __slots__ = ('caller_pid', 'status', 'headers', 'headers_sent', 'early_hints')

    def __init__(self, caller_pid):
        self.caller_pid = caller_pid
        self.status = None
        self.headers = []
        self.headers_sent = False
        self.early_hints = []

    async def send(self, message: dict) -> None:
        """Stream response messages to Erlang via reply()."""
        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            self.status = message.get('status', 200)
            self.headers = message.get('headers', [])
            # Send headers immediately for streaming
            reply(self.caller_pid, ('headers', self.status, self.headers))
            self.headers_sent = True

        elif msg_type == 'http.response.body':
            body_part = message.get('body', b'')
            if isinstance(body_part, str):
                body_part = body_part.encode('utf-8')

            if body_part:
                reply(self.caller_pid, ('chunk', body_part))

            more_body = message.get('more_body', False)
            if not more_body:
                reply(self.caller_pid, 'done')

        elif msg_type == 'http.response.informational':
            status = message.get('status', 100)
            headers = message.get('headers', [])
            if status == 103:
                self.early_hints.append(headers)


def handle_request(channel_ref, caller_pid, app_module: str,
                   app_callable: str) -> None:
    """Handle an ASGI request using channel-based I/O.

    Args:
        channel_ref: Reference to py_channel for receiving scope/body
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app
        app_callable: Name of ASGI callable in module
    """
    if not HAS_ERLANG:
        return

    ch = Channel(channel_ref)

    try:
        # 1. Receive request from channel
        msg = ch.receive()

        if not isinstance(msg, tuple) or len(msg) < 5:
            reply(caller_pid, ('error', 'invalid request tuple'))
            return

        tag = msg[0]
        if tag != 'request':
            reply(caller_pid, ('error', f'expected request, got {tag}'))
            return

        # Unpack: (request, app_module, app_callable, scope, body)
        _, _, _, scope, body = msg

        # 2. Ensure body is bytes
        if isinstance(body, str):
            body = body.encode('utf-8')
        elif not isinstance(body, bytes):
            body = b''

        # 3. Load app
        app = _load_app(app_module, app_callable)

        # 4. Create response collector and receive callable
        response = _ASGIResponse()
        receive = _ReceiveCallable(body)

        # 5. Run the app
        loop = _get_event_loop()
        coro = app(scope, receive, response.send)
        loop.run_until_complete(coro)

        # 6. Send response to Erlang
        status = response.status or 500
        headers = response.headers
        body_bytes = b''.join(response.body_parts)

        if response.early_hints:
            reply(caller_pid, ('response', status, headers, body_bytes,
                               response.early_hints))
        else:
            reply(caller_pid, ('response', status, headers, body_bytes))

    except ChannelClosed:
        pass
    except Exception as e:
        try:
            reply(caller_pid, ('error', str(e)))
        except Exception:
            pass


def handle_request_streaming(channel_ref, caller_pid, app_module: str,
                             app_callable: str) -> None:
    """Handle an ASGI request with streaming response.

    This variant sends response chunks directly to Erlang as they're
    produced, enabling real-time streaming (SSE, etc).

    Args:
        channel_ref: Reference to py_channel for receiving scope/body
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app
        app_callable: Name of ASGI callable in module
    """
    if not HAS_ERLANG:
        return

    ch = Channel(channel_ref)

    try:
        # 1. Receive request from channel
        msg = ch.receive()

        if not isinstance(msg, tuple) or len(msg) < 5:
            reply(caller_pid, ('error', 'invalid request tuple'))
            return

        tag = msg[0]
        if tag != 'request':
            reply(caller_pid, ('error', f'expected request, got {tag}'))
            return

        _, _, _, scope, body = msg

        # 2. Ensure body is bytes
        if isinstance(body, str):
            body = body.encode('utf-8')
        elif not isinstance(body, bytes):
            body = b''

        # 3. Load app
        app = _load_app(app_module, app_callable)

        # 4. Create streaming response handler
        response = _StreamingResponse(caller_pid)
        receive = _ReceiveCallable(body)

        # 5. Run the app - responses stream as they're produced
        loop = _get_event_loop()
        coro = app(scope, receive, response.send)
        loop.run_until_complete(coro)

        # 6. Ensure completion is signaled if not already
        if not response.headers_sent:
            reply(caller_pid, ('headers', 500, []))
            reply(caller_pid, 'done')

    except ChannelClosed:
        pass
    except Exception as e:
        try:
            reply(caller_pid, ('error', str(e)))
        except Exception:
            pass


def handle_request_fast(caller_pid, app_module: str, app_callable: str,
                        scope: dict, body: bytes) -> None:
    """Handle an ASGI request directly (no channel).

    This is the fastest path when channel overhead isn't needed.

    Args:
        caller_pid: Erlang PID to send response to
        app_module: Python module containing ASGI app
        app_callable: Name of ASGI callable in module
        scope: ASGI scope dict
        body: Request body bytes
    """
    if not HAS_ERLANG:
        return

    try:
        # 1. Ensure body is bytes
        if isinstance(body, str):
            body = body.encode('utf-8')
        elif not isinstance(body, bytes):
            body = b''

        # 2. Load app
        app = _load_app(app_module, app_callable)

        # 3. Create response collector and receive callable
        response = _ASGIResponse()
        receive = _ReceiveCallable(body)

        # 4. Run the app
        loop = _get_event_loop()
        coro = app(scope, receive, response.send)
        loop.run_until_complete(coro)

        # 5. Send response to Erlang
        status = response.status or 500
        headers = response.headers
        body_bytes = b''.join(response.body_parts)

        if response.early_hints:
            reply(caller_pid, ('response', status, headers, body_bytes,
                               response.early_hints))
        else:
            reply(caller_pid, ('response', status, headers, body_bytes))

    except Exception as e:
        try:
            reply(caller_pid, ('error', str(e)))
        except Exception:
            pass


# =============================================================================
# Long-lived task support (for handling multiple requests per context)
# =============================================================================

class ASGITask:
    """Long-lived async task that processes multiple requests.

    This task stays alive and receives work from a work channel,
    processing requests concurrently using asyncio.
    """

    def __init__(self, work_channel_ref):
        self.work_channel = Channel(work_channel_ref)
        self.running = True

    async def run(self):
        """Main task loop - receives and processes requests."""
        while self.running:
            try:
                # Wait for work from channel
                msg = self.work_channel.receive()

                if msg == 'stop':
                    self.running = False
                    break

                if isinstance(msg, tuple) and msg[0] == 'work':
                    # (work, request_channel_ref)
                    request_ch_ref = msg[1]
                    # Process concurrently
                    asyncio.create_task(self._handle_request(request_ch_ref))

            except ChannelClosed:
                self.running = False
                break

    async def _handle_request(self, request_ch_ref):
        """Handle a single request from its channel."""
        ch = Channel(request_ch_ref)

        try:
            msg = ch.receive()

            if not isinstance(msg, tuple) or len(msg) < 5:
                return

            tag, app_module, app_callable, scope, body, caller_pid = msg

            if isinstance(body, str):
                body = body.encode('utf-8')
            elif not isinstance(body, bytes):
                body = b''

            app = _load_app(app_module, app_callable)
            response = _ASGIResponse()
            receive = _ReceiveCallable(body)

            await app(scope, receive, response.send)

            status = response.status or 500
            headers = response.headers
            body_bytes = b''.join(response.body_parts)

            reply(caller_pid, ('response', status, headers, body_bytes))

        except Exception as e:
            try:
                # Best effort error reporting
                if 'caller_pid' in dir():
                    reply(caller_pid, ('error', str(e)))
            except Exception:
                pass


def run_asgi_task(work_channel_ref) -> None:
    """Start a long-lived ASGI task.

    This function runs until the work channel is closed or 'stop' is received.

    Args:
        work_channel_ref: Channel reference for receiving work items
    """
    if not HAS_ERLANG:
        return

    task = ASGITask(work_channel_ref)
    loop = _get_event_loop()
    loop.run_until_complete(task.run())


# =============================================================================
# Persistent worker loop (for hornbeam_worker_pool)
# =============================================================================

def worker_loop(channel_ref, arbiter_pid, worker_id: str,
                app_module: str, app_callable: str) -> str:
    """Persistent ASGI worker - loops until stopped.

    This worker receives requests via a channel and processes them continuously,
    reducing Python startup overhead for each request.

    Args:
        channel_ref: Reference to the channel for receiving requests
        arbiter_pid: Erlang PID of the arbiter for heartbeat messages
        app_module: Python module containing ASGI app
        app_callable: Name of ASGI callable in module
        worker_id: Unique identifier for this worker (format: mount_id_idx)

    Returns:
        'stopped' when the worker exits cleanly
    """
    if not HAS_ERLANG:
        return 'no_erlang'

    loop = _get_event_loop()
    result = loop.run_until_complete(
        _async_worker_loop(channel_ref, arbiter_pid, worker_id,
                           app_module, app_callable)
    )
    return result


async def _async_worker_loop(channel_ref, arbiter_pid, worker_id: str,
                              app_module: str, app_callable: str) -> str:
    """Async implementation of the persistent ASGI worker loop."""
    import time

    ch = Channel(channel_ref)
    app = _load_app(app_module, app_callable)
    last_heartbeat = time.monotonic()
    heartbeat_interval = 5.0  # seconds

    while True:
        # Maybe send heartbeat
        now = time.monotonic()
        if now - last_heartbeat >= heartbeat_interval:
            try:
                reply(arbiter_pid, ('heartbeat', worker_id))
            except Exception:
                pass  # Arbiter might be restarting
            last_heartbeat = now

        # Receive next message (blocking in executor to release event loop)
        try:
            msg = await asyncio.get_event_loop().run_in_executor(None, ch.receive)
        except ChannelClosed:
            break

        # Handle control messages
        if msg == 'stop':
            break

        # Handle request messages
        if isinstance(msg, tuple) and len(msg) >= 2:
            tag = msg[0]

            if tag == 'start_request':
                # (start_request, caller_pid, scope, body)
                _, caller_pid, scope, body = msg
                await _process_asgi_request(caller_pid, app, scope, body)

            elif tag == 'start_request_streaming':
                # (start_request_streaming, caller_pid, scope)
                _, caller_pid, scope = msg
                body = await _receive_streaming_body_async(ch)
                await _process_asgi_request(caller_pid, app, scope, body)

    return 'stopped'


async def _receive_streaming_body_async(ch) -> bytes:
    """Receive streaming body chunks from channel asynchronously."""
    chunks = []
    loop = asyncio.get_event_loop()

    while True:
        try:
            msg = await loop.run_in_executor(None, ch.receive)
        except ChannelClosed:
            break

        if msg == 'body_done':
            break
        elif isinstance(msg, tuple) and msg[0] == 'body_chunk':
            chunk = msg[1]
            if isinstance(chunk, bytes):
                chunks.append(chunk)
            elif isinstance(chunk, str):
                chunks.append(chunk.encode('utf-8'))

    return b''.join(chunks)


async def _process_asgi_request(caller_pid, app, scope: dict, body: bytes) -> None:
    """Process a single ASGI request and send response to caller."""
    try:
        # Ensure body is bytes
        if isinstance(body, str):
            body = body.encode('utf-8')
        elif not isinstance(body, bytes):
            body = b''

        # Create response collector and receive callable
        response = _ASGIResponse()
        receive = _ReceiveCallable(body)

        # Run the ASGI app
        await app(scope, receive, response.send)

        # Collect response
        status = response.status or 500
        headers = response.headers
        body_bytes = b''.join(response.body_parts)

        # Send buffered response (small responses)
        if response.early_hints:
            reply(caller_pid, ('response', status, headers, body_bytes,
                               response.early_hints))
        else:
            reply(caller_pid, ('response', status, headers, body_bytes))

    except Exception as e:
        try:
            reply(caller_pid, ('error', str(e)))
        except Exception:
            pass


class _StreamingASGIResponse:
    """Response handler that streams chunks to Erlang for pooled workers."""
    __slots__ = ('caller_pid', 'status', 'headers', 'headers_sent', 'early_hints')

    def __init__(self, caller_pid):
        self.caller_pid = caller_pid
        self.status = None
        self.headers = []
        self.headers_sent = False
        self.early_hints = []

    async def send(self, message: dict) -> None:
        """Stream response messages to Erlang via reply()."""
        msg_type = message.get('type', '')

        if msg_type == 'http.response.start':
            self.status = message.get('status', 200)
            self.headers = message.get('headers', [])
            # Send headers immediately
            reply(self.caller_pid, ('headers', self.status, self.headers))
            self.headers_sent = True

        elif msg_type == 'http.response.body':
            body_part = message.get('body', b'')
            if isinstance(body_part, str):
                body_part = body_part.encode('utf-8')

            if body_part:
                reply(self.caller_pid, ('chunk', body_part))

            more_body = message.get('more_body', False)
            if not more_body:
                reply(self.caller_pid, 'done')

        elif msg_type == 'http.response.informational':
            status = message.get('status', 100)
            headers = message.get('headers', [])
            if status == 103:
                self.early_hints.append(headers)
