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

"""ASGI Lifespan runner module for hornbeam.

This module handles the ASGI lifespan protocol for application
startup and shutdown events.

The lifespan protocol allows ASGI applications to:
- Initialize resources at startup (DB connections, ML models, etc.)
- Clean up resources at shutdown
- Share state across all requests via scope['state']
"""

import asyncio
import importlib
import sys
from typing import Dict, Any, Optional

# Global lifespan state shared across requests
_lifespan_state: Dict[str, Any] = {}
_lifespan_app = None
_lifespan_task = None
_receive_queue: Optional[asyncio.Queue] = None
_send_queue: Optional[asyncio.Queue] = None
_loop: Optional[asyncio.AbstractEventLoop] = None


def load_app(module_name: str, callable_name: str):
    """Load an ASGI application."""
    if module_name in sys.modules:
        del sys.modules[module_name]
    module = importlib.import_module(module_name)
    return getattr(module, callable_name)


async def _run_lifespan(app, scope: dict):
    """Run the ASGI lifespan protocol."""
    async def receive():
        return await _receive_queue.get()

    async def send(message):
        await _send_queue.put(message)

    try:
        await app(scope, receive, send)
    except Exception as e:
        # App crashed - send failure message
        await _send_queue.put({
            'type': 'lifespan.startup.failed',
            'message': str(e)
        })


def startup(app_module: str, app_callable: str) -> dict:
    """Run lifespan startup protocol.

    Args:
        app_module: Python module containing the ASGI app
        app_callable: Name of the ASGI callable

    Returns:
        Response dict with type and optional state
    """
    global _lifespan_state, _lifespan_app, _lifespan_task
    global _receive_queue, _send_queue, _loop

    # Load the app
    try:
        app = load_app(app_module, app_callable)
    except Exception as e:
        return {'type': 'lifespan.startup.failed', 'message': str(e)}

    # Create event loop
    _loop = asyncio.new_event_loop()
    asyncio.set_event_loop(_loop)

    # Create queues
    _receive_queue = asyncio.Queue()
    _send_queue = asyncio.Queue()

    # Build lifespan scope
    scope = {
        'type': 'lifespan',
        'asgi': {
            'version': '3.0',
            'spec_version': '2.4'
        },
        'state': _lifespan_state
    }

    # Start the lifespan task
    _lifespan_app = app
    _lifespan_task = _loop.create_task(_run_lifespan(app, scope))

    # Send startup event
    _loop.run_until_complete(_receive_queue.put({'type': 'lifespan.startup'}))

    # Wait for response, checking if app exits early (doesn't support lifespan)
    async def wait_for_response():
        """Wait for a response, checking if task exits early."""
        # Give the app a small moment to process the startup event
        await asyncio.sleep(0.01)

        # Check if task already finished (app doesn't support lifespan)
        if _lifespan_task.done():
            return None

        # Wait for response with timeout, checking periodically if task finished
        total_timeout = 30.0
        check_interval = 0.5
        elapsed = 0.0

        while elapsed < total_timeout:
            try:
                response = await asyncio.wait_for(
                    _send_queue.get(),
                    timeout=check_interval
                )
                return response
            except asyncio.TimeoutError:
                # Check if task finished while we were waiting
                if _lifespan_task.done():
                    return None
                elapsed += check_interval

        raise asyncio.TimeoutError()

    try:
        response = _loop.run_until_complete(wait_for_response())
        if response is None:
            # App exited without sending - doesn't support lifespan
            _cleanup()
            return {'type': 'lifespan.not_supported'}
    except asyncio.TimeoutError:
        return {'type': 'lifespan.startup.failed',
                'message': 'Startup timeout'}
    except Exception as e:
        return {'type': 'lifespan.startup.failed', 'message': str(e)}

    msg_type = response.get('type', '')

    if msg_type == 'lifespan.startup.complete':
        # Store state for access by requests
        _lifespan_state = scope.get('state', {})
        return {
            'type': 'lifespan.startup.complete',
            'state': _lifespan_state
        }
    elif msg_type == 'lifespan.startup.failed':
        # Clean up
        _cleanup()
        return response
    else:
        # App doesn't support lifespan (sent http.* or websocket.* message)
        _cleanup()
        return {'type': 'lifespan.not_supported'}


def shutdown(app_module: str, app_callable: str) -> dict:
    """Run lifespan shutdown protocol.

    Args:
        app_module: Python module (for reference)
        app_callable: ASGI callable name (for reference)

    Returns:
        Response dict with shutdown status
    """
    global _lifespan_task, _loop

    if _lifespan_task is None or _loop is None:
        return {'type': 'lifespan.shutdown.complete'}

    try:
        # Send shutdown event
        _loop.run_until_complete(
            _receive_queue.put({'type': 'lifespan.shutdown'})
        )

        # Wait for response
        try:
            response = _loop.run_until_complete(
                asyncio.wait_for(_send_queue.get(), timeout=10.0)
            )
        except asyncio.TimeoutError:
            response = {'type': 'lifespan.shutdown.complete'}

        # Wait for task to finish
        try:
            _loop.run_until_complete(
                asyncio.wait_for(_lifespan_task, timeout=5.0)
            )
        except asyncio.TimeoutError:
            _lifespan_task.cancel()
            try:
                _loop.run_until_complete(_lifespan_task)
            except asyncio.CancelledError:
                pass

        return response

    except Exception as e:
        return {'type': 'lifespan.shutdown.complete',
                'error': str(e)}
    finally:
        _cleanup()


def _cleanup():
    """Clean up lifespan state."""
    global _lifespan_app, _lifespan_task, _receive_queue, _send_queue, _loop

    if _lifespan_task and not _lifespan_task.done():
        _lifespan_task.cancel()
        if _loop:
            try:
                _loop.run_until_complete(_lifespan_task)
            except asyncio.CancelledError:
                pass

    if _loop:
        _loop.close()

    _lifespan_app = None
    _lifespan_task = None
    _receive_queue = None
    _send_queue = None
    _loop = None


def get_state() -> dict:
    """Get the lifespan state dict.

    This can be used by request handlers to access shared state
    that was initialized during lifespan startup.
    """
    return _lifespan_state.copy()


def set_state(key: str, value: Any) -> None:
    """Set a value in the lifespan state.

    Args:
        key: State key
        value: Value to store
    """
    _lifespan_state[key] = value


def clear_state() -> None:
    """Clear all lifespan state."""
    global _lifespan_state
    _lifespan_state = {}
