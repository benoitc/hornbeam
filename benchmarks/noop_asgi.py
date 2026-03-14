# Minimal ASGI app - no processing
async def application(scope, receive, send):
    if scope['type'] == 'http':
        await send({
            'type': 'http.response.start',
            'status': 200,
            'headers': [(b'content-type', b'text/plain'), (b'content-length', b'13')],
        })
        await send({
            'type': 'http.response.body',
            'body': b'Hello, World!',
        })
