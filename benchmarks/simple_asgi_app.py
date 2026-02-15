# Simple ASGI app for benchmarking
# Async version of the WSGI benchmark app


async def application(scope, receive, send):
    """Basic hello world ASGI response."""
    if scope['type'] != 'http':
        return

    path = scope.get('path', '/')

    if path == '/large':
        body = b'X' * 65536  # 64KB
    else:
        body = b'Hello, World!'

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
