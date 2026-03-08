# File response benchmark app
import os
import tempfile

# Create a temporary file for testing
_temp_file = None
_temp_file_size = 0

def _ensure_temp_file():
    global _temp_file, _temp_file_size
    if _temp_file is None:
        # Create 1MB temp file
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, 'wb') as f:
            f.write(b'x' * (1024 * 1024))
        _temp_file = path
        _temp_file_size = 1024 * 1024
    return _temp_file, _temp_file_size


class FileWrapper:
    """Simple file wrapper for WSGI file serving."""

    def __init__(self, fileobj, block_size=8192):
        self.fileobj = fileobj
        self.block_size = block_size

    def __iter__(self):
        return self

    def __next__(self):
        data = self.fileobj.read(self.block_size)
        if not data:
            raise StopIteration()
        return data

    def close(self):
        self.fileobj.close()


def app(environ, start_response):
    """Serve file response."""
    path, size = _ensure_temp_file()

    # Check for wsgi.file_wrapper (efficient file serving)
    file_wrapper = environ.get('wsgi.file_wrapper', FileWrapper)

    f = open(path, 'rb')
    start_response('200 OK', [
        ('Content-Type', 'application/octet-stream'),
        ('Content-Length', str(size))
    ])

    return file_wrapper(f)
