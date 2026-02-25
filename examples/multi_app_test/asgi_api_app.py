# Multi-app test - ASGI API application

async def application(scope, receive, send):
    """ASGI API app that returns JSON with path info."""
    if scope['type'] != 'http':
        return

    path = scope.get('path', '/')
    root_path = scope.get('root_path', '')

    import json
    body = json.dumps({
        'app': 'asgi_api',
        'path': path,
        'root_path': root_path,
        'full_path': root_path + path
    }).encode('utf-8')

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
