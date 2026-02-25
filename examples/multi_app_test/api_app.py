# Multi-app test - API application (WSGI)

def application(environ, start_response):
    """API app that returns JSON with path info."""
    path = environ.get('PATH_INFO', '/')
    script_name = environ.get('SCRIPT_NAME', '')

    import json
    body = json.dumps({
        'app': 'api',
        'path_info': path,
        'script_name': script_name,
        'full_path': script_name + path
    }).encode('utf-8')

    status = '200 OK'
    headers = [
        ('Content-Type', 'application/json'),
        ('Content-Length', str(len(body)))
    ]

    start_response(status, headers)
    return [body]
