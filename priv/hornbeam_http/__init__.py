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

"""Hornbeam HTTP Parser - extracted and adapted from gunicorn.

This package provides HTTP/1.1 parsing with PROXY protocol v1/v2 support,
designed for use with the hornbeam FD reactor model.

Example usage:
    from hornbeam_http import HTTPConfig, Request, FdUnreader

    config = HTTPConfig()
    unreader = FdUnreader(fd)
    request = Request(config, unreader, ("127.0.0.1", 12345))

    # Access parsed request
    print(request.method, request.path)
    body = request.body.read(1024)
"""

from hornbeam_http.config import HTTPConfig
from hornbeam_http.message import Message, Request
from hornbeam_http.parser import RequestParser
from hornbeam_http.unreader import Unreader, FdUnreader, BufferUnreader
from hornbeam_http.errors import (
    ParseException,
    NoMoreData,
    InvalidRequestLine,
    InvalidRequestMethod,
    InvalidHTTPVersion,
    InvalidHeader,
    InvalidHeaderName,
    InvalidProxyLine,
    InvalidProxyHeader,
    ForbiddenProxyRequest,
    LimitRequestLine,
    LimitRequestHeaders,
)

__all__ = [
    'HTTPConfig',
    'Message',
    'Request',
    'RequestParser',
    'Unreader',
    'FdUnreader',
    'BufferUnreader',
    'ParseException',
    'NoMoreData',
    'InvalidRequestLine',
    'InvalidRequestMethod',
    'InvalidHTTPVersion',
    'InvalidHeader',
    'InvalidHeaderName',
    'InvalidProxyLine',
    'InvalidProxyHeader',
    'ForbiddenProxyRequest',
    'LimitRequestLine',
    'LimitRequestHeaders',
]

__version__ = '1.0.0'
