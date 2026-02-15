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

"""Example: Registering Python hooks during ASGI lifespan.

This example demonstrates how to register Python handlers during
ASGI lifespan startup, making them callable from any worker or Erlang.

Run with:
    hornbeam:start("examples.hooks_lifespan.app:app", #{
        worker_class => asgi,
        lifespan => on
    }).

Then from any worker or Erlang:
    # Python
    from hornbeam_erlang import execute, stream
    result = execute("calculator", "add", 1, 2)
    for chunk in stream("generator", "count", 5):
        print(chunk)

    # Erlang
    hornbeam_hooks:execute(<<"calculator">>, <<"add">>, [1, 2], #{}).
"""

import json

# Will be available after lifespan startup
calculator = None
generator = None


class Calculator:
    """Simple calculator service."""

    def add(self, a, b):
        return a + b

    def multiply(self, a, b):
        return a * b

    def divide(self, a, b):
        if b == 0:
            raise ValueError("Cannot divide by zero")
        return a / b


class StreamGenerator:
    """Generator for streaming responses."""

    def count(self, n):
        """Generate numbers from 0 to n-1."""
        for i in range(n):
            yield i

    def words(self, text):
        """Stream words from text."""
        for word in text.split():
            yield word


async def lifespan(scope, receive, send):
    """ASGI lifespan handler - register hooks on startup."""
    global calculator, generator

    msg = await receive()

    if msg['type'] == 'lifespan.startup':
        # Import here so it's available in the worker
        from hornbeam_erlang import register_hook

        # Create instances
        calculator = Calculator()
        generator = StreamGenerator()

        # Register as hooks - now callable from any worker or Erlang
        register_hook("calculator", calculator)
        register_hook("generator", generator)

        print("Hooks registered: calculator, generator")

        await send({'type': 'lifespan.startup.complete'})

    # Wait for shutdown
    msg = await receive()
    if msg['type'] == 'lifespan.shutdown':
        # Unregister hooks
        from hornbeam_erlang import unregister_hook
        unregister_hook("calculator")
        unregister_hook("generator")

        print("Hooks unregistered")
        await send({'type': 'lifespan.shutdown.complete'})


async def http_handler(scope, receive, send):
    """HTTP request handler - demonstrates calling hooks."""
    path = scope['path']

    if path == '/add':
        # Call the registered hook
        from hornbeam_erlang import execute
        result = execute("calculator", "add", 3, 5)
        body = json.dumps({'result': result}).encode()

    elif path == '/stream':
        # Stream from the registered hook
        from hornbeam_erlang import stream
        chunks = list(stream("generator", "count", 5))
        body = json.dumps({'chunks': chunks}).encode()

    elif path == '/':
        body = json.dumps({
            'message': 'Hooks example',
            'endpoints': ['/add', '/stream']
        }).encode()

    else:
        await send({
            'type': 'http.response.start',
            'status': 404,
            'headers': [(b'content-type', b'application/json')],
        })
        await send({
            'type': 'http.response.body',
            'body': b'{"error": "Not found"}',
        })
        return

    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [(b'content-type', b'application/json')],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def app(scope, receive, send):
    """ASGI application entry point."""
    if scope['type'] == 'lifespan':
        await lifespan(scope, receive, send)
    elif scope['type'] == 'http':
        await http_handler(scope, receive, send)
