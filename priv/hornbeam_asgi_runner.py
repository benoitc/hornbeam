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

This module handles calling ASGI applications from Erlang.
"""

import asyncio
import importlib

# Cache for loaded application callables
_app_cache = {}


def load_app(module_name, callable_name):
    """Load an ASGI application (no caching to handle reloads)."""
    import sys
    # Force reload if already imported to handle path changes
    if module_name in sys.modules:
        del sys.modules[module_name]
    module = importlib.import_module(module_name)
    return getattr(module, callable_name)


def clear_cache():
    """Clear the application cache."""
    global _app_cache
    _app_cache = {}


async def _run_asgi_async(module_name, callable_name, scope, body):
    """Internal async runner for ASGI apps."""
    # Load the application
    app = load_app(module_name, callable_name)

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

    # Create send callable and collect response
    response = {
        'status': None,
        'headers': [],
        'body': b''
    }

    async def send(message):
        msg_type = message.get('type', '')
        if msg_type == 'http.response.start':
            response['status'] = message.get('status', 200)
            response['headers'] = message.get('headers', [])
        elif msg_type == 'http.response.body':
            body_part = message.get('body', b'')
            if isinstance(body_part, bytes):
                response['body'] += body_part

    # Run the app
    await app(scope, receive, send)

    return response


def run_asgi(module_name, callable_name, scope, body):
    """Run an ASGI application and return the response.

    Args:
        module_name: Python module containing the ASGI app
        callable_name: Name of the ASGI callable in the module
        scope: ASGI scope dict
        body: Request body bytes

    Returns:
        Dict with status, headers, body
    """
    # Run in asyncio event loop
    return asyncio.run(_run_asgi_async(module_name, callable_name, scope, body))
