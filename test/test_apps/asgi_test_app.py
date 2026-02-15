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

"""ASGI test application with various endpoints for testing."""

import asyncio
import json
import traceback


async def application(scope, receive, send):
    """ASGI application for testing various HTTP scenarios."""
    if scope['type'] == 'lifespan':
        await handle_lifespan(scope, receive, send)
        return

    if scope['type'] != 'http':
        return

    path = scope.get('path', '/')

    try:
        # Route to appropriate handler
        if path == '/':
            await handle_hello(scope, receive, send)
        elif path == '/info':
            await handle_info(scope, receive, send)
        elif path == '/scope':
            await handle_scope(scope, receive, send)
        elif path == '/echo':
            await handle_echo(scope, receive, send)
        elif path == '/headers':
            await handle_headers(scope, receive, send)
        elif path == '/status':
            await handle_status(scope, receive, send)
        elif path == '/json':
            await handle_json(scope, receive, send)
        elif path == '/large':
            await handle_large(scope, receive, send)
        elif path == '/streaming':
            await handle_streaming(scope, receive, send)
        elif path == '/slow':
            await handle_slow(scope, receive, send)
        elif path == '/error':
            await handle_error(scope, receive, send)
        elif path == '/unicode':
            await handle_unicode(scope, receive, send)
        elif path == '/early-hints':
            await handle_early_hints(scope, receive, send)
        elif path == '/trailers':
            await handle_trailers(scope, receive, send)
        elif path.startswith('/methods/'):
            await handle_methods(scope, receive, send)
        else:
            await handle_not_found(scope, receive, send)
    except Exception as e:
        # Return 500 with error details
        body = f"Internal Server Error: {str(e)}\n{traceback.format_exc()}".encode('utf-8')
        await send({
            'type': 'http.response.start',
            'status': 500,
            'headers': [
                [b'content-type', b'text/plain'],
                [b'content-length', str(len(body)).encode()],
            ],
        })
        await send({
            'type': 'http.response.body',
            'body': body,
        })


async def handle_lifespan(scope, receive, send):
    """Handle ASGI lifespan protocol."""
    while True:
        message = await receive()
        if message['type'] == 'lifespan.startup':
            await send({'type': 'lifespan.startup.complete'})
        elif message['type'] == 'lifespan.shutdown':
            await send({'type': 'lifespan.shutdown.complete'})
            return


async def handle_hello(scope, receive, send):
    """Simple hello world response."""
    body = b'Hello from ASGI Test App!\n'
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'text/plain'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_info(scope, receive, send):
    """Return detailed request information as JSON."""
    qs = scope.get('query_string', b'')
    if isinstance(qs, bytes):
        qs = qs.decode()

    server = scope.get('server', ('', 0))
    client = scope.get('client', ('', 0))

    info = {
        'method': scope.get('method', ''),
        'path': scope.get('path', ''),
        'query_string': qs,
        'root_path': scope.get('root_path', ''),
        'scheme': scope.get('scheme', ''),
        'http_version': scope.get('http_version', ''),
        'server': {'host': server[0], 'port': server[1]},
        'client': {'host': client[0] if client else '', 'port': client[1] if client else 0},
        'asgi': scope.get('asgi', {}),
    }

    # Include headers
    headers = {}
    for name, value in scope.get('headers', []):
        if isinstance(name, bytes):
            name = name.decode()
        if isinstance(value, bytes):
            value = value.decode()
        headers[name] = value
    info['headers'] = headers

    body = json.dumps(info, indent=2).encode('utf-8')
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'application/json'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_scope(scope, receive, send):
    """Return raw ASGI scope for compliance testing."""
    # Convert scope to JSON-serializable format
    scope_data = {}
    for key, value in scope.items():
        if isinstance(value, bytes):
            scope_data[key] = value.decode('utf-8', errors='replace')
        elif isinstance(value, (list, tuple)):
            scope_data[key] = [
                [
                    item[0].decode('utf-8', errors='replace') if isinstance(item[0], bytes) else item[0],
                    item[1].decode('utf-8', errors='replace') if isinstance(item[1], bytes) else item[1]
                ] if isinstance(item, (list, tuple)) and len(item) == 2 else str(item)
                for item in value
            ]
        else:
            try:
                json.dumps(value)
                scope_data[key] = value
            except (TypeError, ValueError):
                scope_data[key] = str(value)

    body = json.dumps(scope_data, indent=2).encode('utf-8')
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'application/json'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_echo(scope, receive, send):
    """Echo back the request body."""
    body = b''
    while True:
        message = await receive()
        body += message.get('body', b'')
        if not message.get('more_body', False):
            break

    # Get content type from request headers
    content_type = b'application/octet-stream'
    for name, value in scope.get('headers', []):
        if name == b'content-type':
            content_type = value
            break

    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', content_type],
            [b'content-length', str(len(body)).encode()],
            [b'x-echo-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_headers(scope, receive, send):
    """Test various response header scenarios."""
    qs = scope.get('query_string', b'')
    if isinstance(qs, bytes):
        qs = qs.decode()
    params = dict(p.split('=', 1) for p in qs.split('&') if '=' in p)

    headers = [[b'content-type', b'text/plain']]

    # Add custom headers from query params
    if 'custom' in params:
        headers.append([b'x-custom-header', params['custom'].encode()])

    # Test multiple headers with same name
    if 'multi' in params:
        headers.append([b'x-multi', b'value1'])
        headers.append([b'x-multi', b'value2'])

    # Test special headers
    if 'cache' in params:
        headers.append([b'cache-control', f'max-age={params["cache"]}'.encode()])

    body = b'Headers test response\n'
    headers.append([b'content-length', str(len(body)).encode()])

    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': headers,
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_status(scope, receive, send):
    """Return specific HTTP status codes."""
    qs = scope.get('query_string', b'')
    if isinstance(qs, bytes):
        qs = qs.decode()
    params = dict(p.split('=', 1) for p in qs.split('&') if '=' in p)

    code = int(params.get('code', 200))

    if code == 204:
        # No content, no body
        await send({
            'type': 'http.response.start',
            'status': 204,
            'headers': [],
        })
        await send({
            'type': 'http.response.body',
            'body': b'',
        })
    elif code in (301, 302):
        # Redirect
        location = params.get('location', '/')
        await send({
            'type': 'http.response.start',
            'status': code,
            'headers': [
                [b'location', location.encode()],
            ],
        })
        await send({
            'type': 'http.response.body',
            'body': b'',
        })
    else:
        body = f'Status: {code}\n'.encode('utf-8')
        await send({
            'type': 'http.response.start',
            'status': code,
            'headers': [
                [b'content-type', b'text/plain'],
                [b'content-length', str(len(body)).encode()],
            ],
        })
        await send({
            'type': 'http.response.body',
            'body': body,
        })


async def handle_json(scope, receive, send):
    """Handle JSON request and response."""
    method = scope.get('method', 'GET')

    if method == 'POST':
        body = b''
        while True:
            message = await receive()
            body += message.get('body', b'')
            if not message.get('more_body', False):
                break

        if body:
            try:
                data = json.loads(body)
                response = {'received': data, 'status': 'ok'}
            except json.JSONDecodeError as e:
                response = {'error': str(e), 'status': 'error'}
        else:
            response = {'error': 'No body', 'status': 'error'}
    else:
        response = {'message': 'Use POST to send JSON', 'status': 'info'}

    resp_body = json.dumps(response).encode('utf-8')
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'application/json'],
            [b'content-length', str(len(resp_body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': resp_body,
    })


async def handle_large(scope, receive, send):
    """Generate a large response body."""
    qs = scope.get('query_string', b'')
    if isinstance(qs, bytes):
        qs = qs.decode()
    params = dict(p.split('=', 1) for p in qs.split('&') if '=' in p)

    size = int(params.get('size', 1024))  # Default 1KB
    size = min(size, 10 * 1024 * 1024)  # Cap at 10MB

    body = b'X' * size
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'application/octet-stream'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_streaming(scope, receive, send):
    """Return a streaming response."""
    qs = scope.get('query_string', b'')
    if isinstance(qs, bytes):
        qs = qs.decode()
    params = dict(p.split('=', 1) for p in qs.split('&') if '=' in p)

    chunks = int(params.get('chunks', 5))
    chunk_size = int(params.get('size', 100))

    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'text/plain'],
            # No content-length for streaming
        ],
    })

    for i in range(chunks):
        chunk = f'Chunk {i + 1}: {"X" * chunk_size}\n'.encode('utf-8')
        await send({
            'type': 'http.response.body',
            'body': chunk,
            'more_body': i < chunks - 1,
        })


async def handle_slow(scope, receive, send):
    """Simulate a slow response."""
    qs = scope.get('query_string', b'')
    if isinstance(qs, bytes):
        qs = qs.decode()
    params = dict(p.split('=', 1) for p in qs.split('&') if '=' in p)

    delay = float(params.get('delay', 1.0))
    delay = min(delay, 10.0)  # Cap at 10 seconds

    await asyncio.sleep(delay)

    body = f'Response after {delay}s delay\n'.encode('utf-8')
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'text/plain'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_error(scope, receive, send):
    """Simulate various error conditions."""
    qs = scope.get('query_string', b'')
    if isinstance(qs, bytes):
        qs = qs.decode()
    params = dict(p.split('=', 1) for p in qs.split('&') if '=' in p)

    error_type = params.get('type', 'exception')

    if error_type == 'exception':
        raise ValueError("Intentional test exception")
    elif error_type == 'timeout':
        await asyncio.sleep(300)  # Will be killed by timeout
    elif error_type == 'empty':
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [],
        })
        await send({
            'type': 'http.response.body',
            'body': b'',
        })
    else:
        body = b'Unknown error type\n'
        await send({
            'type': 'http.response.start',
            'status': 400,
            'headers': [
                [b'content-type', b'text/plain'],
                [b'content-length', str(len(body)).encode()],
            ],
        })
        await send({
            'type': 'http.response.body',
            'body': body,
        })


async def handle_unicode(scope, receive, send):
    """Test Unicode handling."""
    unicode_text = """Unicode Test:
- ASCII: Hello World
- Accents: café, naïve, résumé
- Greek: Ελληνικά
- Chinese: 中文测试
- Japanese: 日本語テスト
- Emoji: 🎉 🚀 ✨
- Math: ∑ ∫ √ π ∞
"""
    body = unicode_text.encode('utf-8')
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'text/plain; charset=utf-8'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_early_hints(scope, receive, send):
    """Test 103 Early Hints response."""
    # Send 103 Early Hints (informational response)
    await send({
        'type': 'http.response.start',
        'status': 103,
        'headers': [
            [b'link', b'</style.css>; rel=preload; as=style'],
            [b'link', b'</script.js>; rel=preload; as=script'],
        ],
    })

    # Send actual response
    body = b'Response with early hints\n'
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'text/plain'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_trailers(scope, receive, send):
    """Test HTTP trailers."""
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'text/plain'],
            [b'trailer', b'x-checksum'],
        ],
    })

    body = b'Response body for trailer test\n'
    await send({
        'type': 'http.response.body',
        'body': body,
        'more_body': True,
    })

    # Send trailers
    await send({
        'type': 'http.response.body',
        'body': b'',
        'more_body': False,
    })


async def handle_methods(scope, receive, send):
    """Test HTTP method handling."""
    method = scope.get('method', 'GET')
    path = scope.get('path', '')

    # Extract expected method from path: /methods/{method}
    expected = path.split('/')[-1].upper()

    if method == expected:
        body = f'Method {method} OK\n'.encode('utf-8')
        status = 200
    else:
        body = f'Expected {expected}, got {method}\n'.encode('utf-8')
        status = 405

    await send({
        'type': 'http.response.start',
        'status': status,
        'headers': [
            [b'content-type', b'text/plain'],
            [b'content-length', str(len(body)).encode()],
            [b'allow', b'GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS'],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })


async def handle_not_found(scope, receive, send):
    """404 handler."""
    body = b'Not Found\n'
    await send({
        'type': 'http.response.start',
        'status': 404,
        'headers': [
            [b'content-type', b'text/plain'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })
