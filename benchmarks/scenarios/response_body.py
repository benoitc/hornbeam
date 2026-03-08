# Response body size benchmark app

# Pre-generate response bodies
BODY_1KB = b'x' * 1024
BODY_64KB = b'x' * 65536

def app(environ, start_response):
    """Return sized response body."""
    path = environ.get('PATH_INFO', '/')

    if path == '/1kb':
        body = BODY_1KB
    elif path == '/64kb':
        body = BODY_64KB
    else:
        body = b'Hello'

    start_response('200 OK', [
        ('Content-Type', 'application/octet-stream'),
        ('Content-Length', str(len(body)))
    ])
    return [body]
