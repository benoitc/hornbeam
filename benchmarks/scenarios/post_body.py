# POST body echo benchmark app

def app(environ, start_response):
    """Echo POST body back."""
    body = environ['wsgi.input'].read()
    start_response('200 OK', [
        ('Content-Type', 'application/octet-stream'),
        ('Content-Length', str(len(body)))
    ])
    return [body]
