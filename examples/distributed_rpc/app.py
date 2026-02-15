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

"""Distributed Erlang RPC Example.

This example demonstrates:
- Calling functions on remote Erlang nodes
- Distributing ML inference across a cluster
- Aggregating results from multiple nodes

Architecture:
    [Python Web App] --> [Local Erlang Node] --> [Remote Erlang Nodes]
                              |                          |
                              v                          v
                         hornbeam                    ML workers
                         (http)                  (GPU nodes, workers)

Run locally:
    hornbeam:start("app:application", #{pythonpath => ["examples/distributed_rpc"]}).

For distributed setup, see start.erl for how to:
1. Start multiple Erlang nodes
2. Connect them together
3. Run ML inference across the cluster
"""

import json
from typing import Any, Dict, List, Optional

# Import hornbeam Erlang integration
try:
    from hornbeam_erlang import (
        rpc_call, rpc_cast, nodes, node,
        state_get, state_set, state_incr
    )
    HAS_ERLANG = True
except ImportError:
    # Fallback for standalone testing
    HAS_ERLANG = False

    def rpc_call(node, module, function, args, timeout_ms=5000):
        return {'error': 'Not connected to Erlang cluster'}

    def rpc_cast(node, module, function, args):
        pass

    def nodes():
        return []

    def node():
        return 'standalone@localhost'

    def state_get(k):
        return None

    def state_set(k, v):
        pass

    def state_incr(k, d=1):
        return d


def get_cluster_status() -> Dict[str, Any]:
    """Get status of all connected Erlang nodes."""
    connected = nodes()
    local = node()

    # Ping each node and get their status
    node_status = []
    for n in connected:
        try:
            result = rpc_call(n, 'erlang', 'system_info', ['process_count'])
            node_status.append({
                'node': n,
                'status': 'connected',
                'processes': result
            })
        except Exception as e:
            node_status.append({
                'node': n,
                'status': 'error',
                'error': str(e)
            })

    return {
        'local_node': local,
        'connected_nodes': connected,
        'node_count': len(connected),
        'node_status': node_status
    }


def distribute_inference(model_name: str, inputs: List[Any]) -> List[Any]:
    """Distribute ML inference across cluster nodes.

    This function:
    1. Gets available ML worker nodes
    2. Splits input across nodes
    3. Calls inference on each node in parallel (via async RPC)
    4. Aggregates results

    In a real setup, ML worker nodes would have models loaded.
    """
    # Track request
    state_incr('distributed_requests')

    connected = nodes()
    if not connected:
        # No remote nodes, run locally (fallback)
        state_incr('local_fallback')
        return [{'input': inp, 'result': f'processed locally: {inp}'}
                for inp in inputs]

    # Split inputs across nodes
    results = []
    for i, inp in enumerate(inputs):
        target_node = connected[i % len(connected)]

        try:
            # Call ML inference on remote node
            result = rpc_call(
                target_node,
                'ml_worker',
                'inference',
                [model_name, inp],
                timeout_ms=30000
            )
            results.append({
                'input': inp,
                'node': target_node,
                'result': result
            })
            state_incr('remote_inference_success')
        except Exception as e:
            results.append({
                'input': inp,
                'node': target_node,
                'error': str(e)
            })
            state_incr('remote_inference_error')

    return results


def application(environ, start_response):
    """WSGI application demonstrating distributed Erlang RPC."""
    state_incr('requests_total')

    path = environ.get('PATH_INFO', '/')
    method = environ.get('REQUEST_METHOD', 'GET')

    if path == '/':
        body = b"""Distributed RPC Example

Endpoints:
  GET  /cluster  - Get cluster status (connected nodes)
  GET  /nodes    - List all connected Erlang nodes
  POST /infer    - Distribute inference across cluster
                   Body: {"model": "embedder", "inputs": ["text1", "text2"]}
  POST /rpc      - Call arbitrary function on remote node
                   Body: {"node": "worker@host2", "module": "mymod",
                          "function": "myfunc", "args": [1, 2, 3]}

Run with:
  # Start main node
  rebar3 shell --sname main
  > hornbeam:start("app:application", #{pythonpath => ["examples/distributed_rpc"]}).

  # Start worker node
  rebar3 shell --sname worker
  > net_adm:ping('main@hostname').

  # Now /cluster shows both nodes
"""
        start_response('200 OK', [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ])
        return [body]

    if path == '/cluster':
        status = get_cluster_status()
        response = json.dumps(status, indent=2)
        start_response('200 OK', [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(response)))
        ])
        return [response.encode()]

    if path == '/nodes':
        connected = nodes()
        local = node()
        response = json.dumps({
            'local': local,
            'connected': connected
        }, indent=2)
        start_response('200 OK', [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(response)))
        ])
        return [response.encode()]

    if path == '/infer' and method == 'POST':
        content_length = int(environ.get('CONTENT_LENGTH', 0))
        if content_length > 0:
            body = environ['wsgi.input']
            if isinstance(body, bytes):
                data = json.loads(body)
            else:
                data = json.loads(body.read(content_length))
        else:
            data = {}

        model = data.get('model', 'default')
        inputs = data.get('inputs', [])

        results = distribute_inference(model, inputs)
        response = json.dumps({'results': results}, indent=2)
        start_response('200 OK', [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(response)))
        ])
        return [response.encode()]

    if path == '/rpc' and method == 'POST':
        content_length = int(environ.get('CONTENT_LENGTH', 0))
        if content_length > 0:
            body = environ['wsgi.input']
            if isinstance(body, bytes):
                data = json.loads(body)
            else:
                data = json.loads(body.read(content_length))
        else:
            data = {}

        target_node = data.get('node')
        module = data.get('module')
        function = data.get('function')
        args = data.get('args', [])
        timeout = data.get('timeout', 5000)

        if not all([target_node, module, function]):
            start_response('400 Bad Request', [('Content-Type', 'application/json')])
            return [b'{"error": "Missing node, module, or function"}']

        try:
            result = rpc_call(target_node, module, function, args, timeout)
            response = json.dumps({'result': result})
            start_response('200 OK', [
                ('Content-Type', 'application/json'),
                ('Content-Length', str(len(response)))
            ])
            return [response.encode()]
        except Exception as e:
            response = json.dumps({'error': str(e)})
            start_response('500 Internal Server Error', [
                ('Content-Type', 'application/json'),
                ('Content-Length', str(len(response)))
            ])
            return [response.encode()]

    start_response('404 Not Found', [('Content-Type', 'text/plain')])
    return [b'Not Found']
