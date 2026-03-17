# ASGI app that returns large responses to test streaming

SMALL_BODY = b'x' * 1000        # 1KB - should buffer
LARGE_BODY = b'x' * 100000      # 100KB - should stream

async def app(scope, receive, send):
    """ASGI app with configurable response size."""
    if scope['type'] == 'http':
        path = scope.get('path', '/')

        if path == '/large':
            body = LARGE_BODY
        else:
            body = SMALL_BODY

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
