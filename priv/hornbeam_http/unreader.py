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

"""Buffer management for HTTP parsing - adapted from gunicorn.

Provides classes that can "unread" data, pushing it back to be read again.
This is useful for HTTP parsing where we may read too much data.
"""

import io
import os
from typing import Optional


class Unreader:
    """Base class for read sources that support unreading.

    Subclasses must implement the chunk() method to read new data.
    """

    def __init__(self):
        self.buf = io.BytesIO()

    def chunk(self) -> bytes:
        """Read a chunk of data from the underlying source.

        Returns:
            bytes: Data read, or empty bytes if no more data available
        """
        raise NotImplementedError()

    def read(self, size: Optional[int] = None) -> bytes:
        """Read data, using buffer first then underlying source.

        Args:
            size: Maximum bytes to read, or None for all available

        Returns:
            bytes: Data read
        """
        if size is not None and not isinstance(size, int):
            raise TypeError("size parameter must be an int or long.")

        if size is not None:
            if size == 0:
                return b""
            if size < 0:
                size = None

        self.buf.seek(0, os.SEEK_END)

        if size is None and self.buf.tell():
            ret = self.buf.getvalue()
            self.buf = io.BytesIO()
            return ret
        if size is None:
            d = self.chunk()
            return d

        while self.buf.tell() < size:
            chunk = self.chunk()
            if not chunk:
                ret = self.buf.getvalue()
                self.buf = io.BytesIO()
                return ret
            self.buf.write(chunk)
        data = self.buf.getvalue()
        self.buf = io.BytesIO()
        self.buf.write(data[size:])
        return data[:size]

    def unread(self, data: bytes):
        """Push data back to be read again.

        Args:
            data: Data to push back
        """
        rest = self.buf.getvalue()
        self.buf = io.BytesIO()
        self.buf.write(data)
        self.buf.write(rest)


class FdUnreader(Unreader):
    """Unreader for file descriptors (used with reactor model).

    Reads from a file descriptor using os.read().
    """

    def __init__(self, fd: int, max_chunk: int = 65536):
        """Initialize with file descriptor.

        Args:
            fd: File descriptor to read from
            max_chunk: Maximum bytes to read per chunk
        """
        super().__init__()
        self.fd = fd
        self.max_chunk = max_chunk

    def chunk(self) -> bytes:
        """Read a chunk from the file descriptor."""
        try:
            return os.read(self.fd, self.max_chunk)
        except (BlockingIOError, OSError):
            return b''


class SocketUnreader(Unreader):
    """Unreader for socket objects.

    Reads from a socket using recv().
    """

    def __init__(self, sock, max_chunk: int = 8192):
        """Initialize with socket.

        Args:
            sock: Socket object to read from
            max_chunk: Maximum bytes to read per chunk
        """
        super().__init__()
        self.sock = sock
        self.max_chunk = max_chunk

    def chunk(self) -> bytes:
        """Read a chunk from the socket."""
        return self.sock.recv(self.max_chunk)


class BufferUnreader(Unreader):
    """Unreader for an existing buffer.

    Useful when data has already been read and needs to be parsed.
    """

    def __init__(self, data: bytes = b''):
        """Initialize with initial data.

        Args:
            data: Initial data buffer
        """
        super().__init__()
        self._data = data
        self._pos = 0

    def chunk(self) -> bytes:
        """Return remaining data from buffer."""
        if self._pos >= len(self._data):
            return b''
        chunk = self._data[self._pos:]
        self._pos = len(self._data)
        return chunk

    def feed(self, data: bytes):
        """Add more data to the buffer.

        Args:
            data: New data to append
        """
        self._data = self._data[self._pos:] + data
        self._pos = 0


class IterUnreader(Unreader):
    """Unreader for iterables.

    Reads from an iterable that yields bytes chunks.
    """

    def __init__(self, iterable):
        """Initialize with iterable.

        Args:
            iterable: Iterable yielding bytes chunks
        """
        super().__init__()
        self.iter = iter(iterable)

    def chunk(self) -> bytes:
        """Get next chunk from iterator."""
        if not self.iter:
            return b""
        try:
            return next(self.iter)
        except StopIteration:
            self.iter = None
            return b""
