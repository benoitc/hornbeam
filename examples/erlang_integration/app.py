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

"""Demo WSGI application showing Python calling Erlang functions.

This example demonstrates how to call registered Erlang functions from
a Python WSGI application running on hornbeam.

Run with hornbeam:
    hornbeam:start("app:application", #{pythonpath => ["examples/erlang_integration"]}).

Run with gunicorn (for comparison):
    gunicorn app:application
"""

import json

# Import hornbeam Erlang integration (or provide fallbacks for gunicorn)
try:
    from hornbeam_erlang import call, rpc_call, state_get, state_set

    def get_config():
        """Get config from Erlang."""
        return call('get_config')

    def log_request(method, path):
        """Log request via Erlang."""
        return call('log_request', method, path)

    def lookup_user(user_id):
        """Look up user from Erlang gen_server."""
        return call('lookup_user', user_id)

    def spawn_task(data):
        """Spawn background Erlang task."""
        return call('spawn_task', data)

except ImportError:
    # Fallback for running standalone or with gunicorn
    import logging
    logging.basicConfig(level=logging.INFO)
    _logger = logging.getLogger(__name__)
    _users = {
        '1': {'id': '1', 'name': 'Alice', 'email': 'alice@example.com'},
        '2': {'id': '2', 'name': 'Bob', 'email': 'bob@example.com'},
    }
    _task_id = 0

    def get_config():
        return {'env': 'development', 'debug': True}

    def log_request(method, path):
        _logger.info(f"{method} {path}")

    def lookup_user(user_id):
        return _users.get(user_id, 'none')

    def spawn_task(data):
        global _task_id
        _task_id += 1
        _logger.info(f"Would spawn task {_task_id} with data: {data}")
        return str(_task_id)


def application(environ, start_response):
    """WSGI application demonstrating Erlang integration."""
    path = environ.get('PATH_INFO', '/')
    method = environ.get('REQUEST_METHOD', 'GET')

    # Log via Erlang (could write to disk, send to telemetry, etc.)
    log_request(method, path)

    if path == '/':
        body = b'Erlang Integration Demo\n\nEndpoints:\n'
        body += b'  GET /config - Get Erlang application config\n'
        body += b'  GET /user/{id} - Lookup user from Erlang gen_server\n'
        body += b'  POST /task - Spawn background Erlang process\n'
        start_response('200 OK', [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ])
        return [body]

    if path == '/config':
        # Get configuration from Erlang application env
        config = get_config()
        response = json.dumps(config)
        start_response('200 OK', [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(response)))
        ])
        return [response.encode()]

    if path.startswith('/user/'):
        user_id = path.split('/')[-1]
        # Query Erlang gen_server or mnesia
        user = lookup_user(user_id)
        if user and user != 'none':
            response = json.dumps(user)
            start_response('200 OK', [
                ('Content-Type', 'application/json'),
                ('Content-Length', str(len(response)))
            ])
            return [response.encode()]
        start_response('404 Not Found', [('Content-Type', 'text/plain')])
        return [b'User not found']

    if path == '/task' and method == 'POST':
        # Read request body
        content_length = int(environ.get('CONTENT_LENGTH', 0))
        if content_length > 0:
            body = environ['wsgi.input']
            if isinstance(body, bytes):
                data = json.loads(body)
            else:
                data = json.loads(body.read(content_length))
        else:
            data = {}

        # Spawn background Erlang process
        task_id = spawn_task(data)
        response = json.dumps({'task_id': task_id})
        start_response('202 Accepted', [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(response)))
        ])
        return [response.encode()]

    start_response('404 Not Found', [('Content-Type', 'text/plain')])
    return [b'Not Found']
