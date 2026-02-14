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

"""Simple WSGI hello world application."""


def application(environ, start_response):
    """WSGI application that returns a hello message."""
    path = environ.get('PATH_INFO', '/')
    method = environ.get('REQUEST_METHOD', 'GET')

    if path == '/':
        status = '200 OK'
        body = b'Hello from Hornbeam WSGI!\n'
        headers = [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ]
    elif path == '/info':
        # Return request info
        info = f"""Request Info:
Method: {method}
Path: {path}
Query String: {environ.get('QUERY_STRING', '')}
Server: {environ.get('SERVER_NAME', '')}:{environ.get('SERVER_PORT', '')}
"""
        body = info.encode('utf-8')
        status = '200 OK'
        headers = [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ]
    elif path == '/echo' and method == 'POST':
        # Echo back the request body
        content_length = int(environ.get('CONTENT_LENGTH', 0))
        if content_length > 0:
            body = environ['wsgi.input']
            if isinstance(body, bytes):
                pass  # Already bytes
            else:
                body = body.read(content_length)
        else:
            body = b''
        status = '200 OK'
        headers = [
            ('Content-Type', 'application/octet-stream'),
            ('Content-Length', str(len(body)))
        ]
    else:
        status = '404 Not Found'
        body = b'Not Found\n'
        headers = [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ]

    start_response(status, headers)
    return [body]
