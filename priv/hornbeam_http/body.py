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

"""HTTP body readers - adapted from gunicorn.

Provides readers for different body transfer encodings:
- ChunkedReader: Transfer-Encoding: chunked
- LengthReader: Content-Length specified
- EOFReader: Read until connection close
"""

import io
import sys
from typing import Optional

from hornbeam_http.errors import NoMoreData, ChunkMissingTerminator, InvalidChunkSize


class ChunkedReader:
    """Reader for chunked transfer encoding."""

    def __init__(self, req, unreader):
        """Initialize chunked reader.

        Args:
            req: Request object (for parsing trailers)
            unreader: Unreader instance for reading data
        """
        self.req = req
        self.parser = self.parse_chunked(unreader)
        self.buf = io.BytesIO()

    def read(self, size: int) -> bytes:
        """Read up to size bytes.

        Args:
            size: Maximum bytes to read

        Returns:
            bytes: Data read (may be less than size)
        """
        if not isinstance(size, int):
            raise TypeError("size must be an integer type")
        if size < 0:
            raise ValueError("Size must be positive.")
        if size == 0:
            return b""

        if self.parser:
            while self.buf.tell() < size:
                try:
                    self.buf.write(next(self.parser))
                except StopIteration:
                    self.parser = None
                    break

        data = self.buf.getvalue()
        ret, rest = data[:size], data[size:]
        self.buf = io.BytesIO()
        self.buf.write(rest)
        return ret

    def parse_trailers(self, unreader, data):
        """Parse trailer headers after final chunk."""
        buf = io.BytesIO()
        buf.write(data)

        idx = buf.getvalue().find(b"\r\n\r\n")
        done = buf.getvalue()[:2] == b"\r\n"
        while idx < 0 and not done:
            self.get_data(unreader, buf)
            idx = buf.getvalue().find(b"\r\n\r\n")
            done = buf.getvalue()[:2] == b"\r\n"
        if done:
            unreader.unread(buf.getvalue()[2:])
            return b""
        self.req.trailers = self.req.parse_headers(buf.getvalue()[:idx], from_trailer=True)
        unreader.unread(buf.getvalue()[idx + 4:])

    def parse_chunked(self, unreader):
        """Generator that yields body chunks."""
        (size, rest) = self.parse_chunk_size(unreader)
        while size > 0:
            while size > len(rest):
                size -= len(rest)
                yield rest
                rest = unreader.read()
                if not rest:
                    raise NoMoreData()
            yield rest[:size]
            # Remove \r\n after chunk
            rest = rest[size:]
            while len(rest) < 2:
                new_data = unreader.read()
                if not new_data:
                    break
                rest += new_data
            if rest[:2] != b'\r\n':
                raise ChunkMissingTerminator(rest[:2])
            (size, rest) = self.parse_chunk_size(unreader, data=rest[2:])

    def parse_chunk_size(self, unreader, data=None):
        """Parse chunk size line."""
        buf = io.BytesIO()
        if data is not None:
            buf.write(data)

        idx = buf.getvalue().find(b"\r\n")
        while idx < 0:
            self.get_data(unreader, buf)
            idx = buf.getvalue().find(b"\r\n")

        data = buf.getvalue()
        line, rest_chunk = data[:idx], data[idx + 2:]

        # RFC9112 7.1.1: BWS before chunk-ext - but ONLY then
        chunk_size, *chunk_ext = line.split(b";", 1)
        if chunk_ext:
            chunk_size = chunk_size.rstrip(b" \t")
        if any(n not in b"0123456789abcdefABCDEF" for n in chunk_size):
            raise InvalidChunkSize(chunk_size)
        if len(chunk_size) == 0:
            raise InvalidChunkSize(chunk_size)
        chunk_size = int(chunk_size, 16)

        if chunk_size == 0:
            try:
                self.parse_trailers(unreader, rest_chunk)
            except NoMoreData:
                pass
            return (0, None)
        return (chunk_size, rest_chunk)

    def get_data(self, unreader, buf):
        """Read data and append to buffer."""
        data = unreader.read()
        if not data:
            raise NoMoreData()
        buf.write(data)


class LengthReader:
    """Reader for Content-Length specified bodies."""

    def __init__(self, unreader, length: int):
        """Initialize length reader.

        Args:
            unreader: Unreader instance for reading data
            length: Content-Length value
        """
        self.unreader = unreader
        self.length = length

    def read(self, size: int) -> bytes:
        """Read up to size bytes.

        Args:
            size: Maximum bytes to read

        Returns:
            bytes: Data read (may be less than size)
        """
        if not isinstance(size, int):
            raise TypeError("size must be an integral type")

        size = min(self.length, size)
        if size < 0:
            raise ValueError("Size must be positive.")
        if size == 0:
            return b""

        buf = io.BytesIO()
        data = self.unreader.read()
        while data:
            buf.write(data)
            if buf.tell() >= size:
                break
            data = self.unreader.read()

        buf = buf.getvalue()
        ret, rest = buf[:size], buf[size:]
        self.unreader.unread(rest)
        self.length -= size
        return ret


class EOFReader:
    """Reader that reads until EOF/connection close."""

    def __init__(self, unreader):
        """Initialize EOF reader.

        Args:
            unreader: Unreader instance for reading data
        """
        self.unreader = unreader
        self.buf = io.BytesIO()
        self.finished = False

    def read(self, size: int) -> bytes:
        """Read up to size bytes.

        Args:
            size: Maximum bytes to read

        Returns:
            bytes: Data read (may be less than size)
        """
        if not isinstance(size, int):
            raise TypeError("size must be an integral type")
        if size < 0:
            raise ValueError("Size must be positive.")
        if size == 0:
            return b""

        if self.finished:
            data = self.buf.getvalue()
            ret, rest = data[:size], data[size:]
            self.buf = io.BytesIO()
            self.buf.write(rest)
            return ret

        data = self.unreader.read()
        while data:
            self.buf.write(data)
            if self.buf.tell() > size:
                break
            data = self.unreader.read()

        if not data:
            self.finished = True

        data = self.buf.getvalue()
        ret, rest = data[:size], data[size:]
        self.buf = io.BytesIO()
        self.buf.write(rest)
        return ret


class Body:
    """File-like object wrapping body readers.

    Provides standard file interface (read, readline, readlines, __iter__).
    """

    def __init__(self, reader):
        """Initialize body wrapper.

        Args:
            reader: ChunkedReader, LengthReader, or EOFReader instance
        """
        self.reader = reader
        self.buf = io.BytesIO()

    def __iter__(self):
        return self

    def __next__(self):
        ret = self.readline()
        if not ret:
            raise StopIteration()
        return ret

    next = __next__

    def getsize(self, size: Optional[int]) -> int:
        """Normalize size parameter."""
        if size is None:
            return sys.maxsize
        elif not isinstance(size, int):
            raise TypeError("size must be an integral type")
        elif size < 0:
            return sys.maxsize
        return size

    def read(self, size: Optional[int] = None) -> bytes:
        """Read up to size bytes.

        Args:
            size: Maximum bytes to read, or None for all

        Returns:
            bytes: Data read
        """
        size = self.getsize(size)
        if size == 0:
            return b""

        if size < self.buf.tell():
            data = self.buf.getvalue()
            ret, rest = data[:size], data[size:]
            self.buf = io.BytesIO()
            self.buf.write(rest)
            return ret

        while size > self.buf.tell():
            data = self.reader.read(1024)
            if not data:
                break
            self.buf.write(data)

        data = self.buf.getvalue()
        ret, rest = data[:size], data[size:]
        self.buf = io.BytesIO()
        self.buf.write(rest)
        return ret

    def readline(self, size: Optional[int] = None) -> bytes:
        """Read a line.

        Args:
            size: Maximum bytes to read, or None for full line

        Returns:
            bytes: Line data including newline
        """
        size = self.getsize(size)
        if size == 0:
            return b""

        data = self.buf.getvalue()
        self.buf = io.BytesIO()

        ret = []
        while 1:
            idx = data.find(b"\n", 0, size)
            idx = idx + 1 if idx >= 0 else size if len(data) >= size else 0
            if idx:
                ret.append(data[:idx])
                self.buf.write(data[idx:])
                break

            ret.append(data)
            size -= len(data)
            data = self.reader.read(min(1024, size))
            if not data:
                break

        return b"".join(ret)

    def readlines(self, size: Optional[int] = None) -> list:
        """Read all lines.

        Args:
            size: Hint for total bytes (ignored)

        Returns:
            list: List of line bytes
        """
        ret = []
        data = self.read()
        while data:
            pos = data.find(b"\n")
            if pos < 0:
                ret.append(data)
                data = b""
            else:
                line, data = data[:pos + 1], data[pos + 1:]
                ret.append(line)
        return ret
