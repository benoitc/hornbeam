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

"""HTTP request parser - adapted from gunicorn.

Provides iterator-based parsing for keep-alive connections.
"""

from typing import Optional, Iterator

from hornbeam_http.message import Request
from hornbeam_http.unreader import Unreader, FdUnreader, SocketUnreader


class Parser:
    """Base parser class for HTTP messages.

    Provides iterator interface for parsing multiple messages
    on a keep-alive connection.
    """

    mesg_class = None

    def __init__(self, cfg, source, source_addr):
        """Initialize parser.

        Args:
            cfg: HTTPConfig instance
            source: Socket, fd, or iterable
            source_addr: Source address tuple (ip, port) or None
        """
        self.cfg = cfg
        if hasattr(source, "recv"):
            self.unreader = SocketUnreader(source)
        elif isinstance(source, int):
            self.unreader = FdUnreader(source)
        else:
            from hornbeam_http.unreader import IterUnreader
            self.unreader = IterUnreader(source)
        self.mesg = None
        self.source_addr = source_addr
        self.req_count = 0

    def __iter__(self) -> Iterator:
        return self

    def finish_body(self):
        """Discard any unread body of the current message.

        This should be called before returning a keepalive connection
        to ensure the socket doesn't appear readable due to leftover body bytes.
        """
        if self.mesg:
            try:
                data = self.mesg.body.read(1024)
                while data:
                    data = self.mesg.body.read(1024)
            except (BlockingIOError, OSError):
                # No more application data available
                pass

    def __next__(self):
        """Parse next request.

        Returns:
            Request: Parsed request

        Raises:
            StopIteration: When connection should close
        """
        # Stop if HTTP dictates a stop
        if self.mesg and self.mesg.should_close():
            raise StopIteration()

        # Discard any unread body of the previous message
        self.finish_body()

        # Parse the next request
        self.req_count += 1
        self.mesg = self.mesg_class(self.cfg, self.unreader, self.source_addr, self.req_count)
        if not self.mesg:
            raise StopIteration()
        return self.mesg

    next = __next__


class RequestParser(Parser):
    """Parser for HTTP requests."""

    mesg_class = Request
