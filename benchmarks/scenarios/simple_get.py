# Simple GET benchmark app

def app(environ, start_response):
    """Simple GET handler - returns minimal response."""
    start_response('200 OK', [
        ('Content-Type', 'text/plain'),
        ('Content-Length', '11')
    ])
    return [b'Hello World']
