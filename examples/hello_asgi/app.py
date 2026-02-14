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

"""Simple ASGI hello world application."""


async def application(scope, receive, send):
    """ASGI application that returns a hello message."""
    if scope['type'] != 'http':
        return

    path = scope.get('path', '/')
    method = scope.get('method', 'GET')

    if path == '/':
        body = b'Hello from Hornbeam ASGI!\n'
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
    elif path == '/info':
        # Return request info
        qs = scope.get('query_string', b'')
        if isinstance(qs, bytes):
            qs = qs.decode()
        server = scope.get('server', ['', ''])
        info = f"""Request Info:
Method: {method}
Path: {path}
Query String: {qs}
Server: {server[0]}:{server[1]}
ASGI Version: {scope.get('asgi', {}).get('version', 'unknown')}
"""
        body = info.encode('utf-8')
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
    elif path == '/echo' and method == 'POST':
        # Read request body
        body = b''
        while True:
            message = await receive()
            body += message.get('body', b'')
            if not message.get('more_body', False):
                break

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
    else:
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
