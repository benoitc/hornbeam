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

"""HTTP configuration for hornbeam HTTP parser."""

from dataclasses import dataclass, field
from typing import List, Dict, Optional, Set
import ipaddress


@dataclass
class HTTPConfig:
    """Configuration for HTTP parsing.

    This replaces the gunicorn cfg object with a simple dataclass that
    can be easily constructed from Erlang-provided configuration.

    Attributes:
        is_ssl: Whether the connection is SSL/TLS
        limit_request_fields: Maximum number of header fields (default: 100)
        limit_request_field_size: Maximum size of header field (default: 8190)
        limit_request_line: Maximum request line size (default: 4094)
        proxy_protocol: PROXY protocol mode: 'off', 'v1', 'v2', 'auto'
        proxy_allow_ips: List of IPs allowed to send PROXY protocol
        forwarded_allow_ips: List of IPs allowed to set forwarded headers
        secure_scheme_headers: Headers that indicate HTTPS
        forwarder_headers: Headers from trusted forwarders
        strip_header_spaces: Strip spaces around header names
        permit_obsolete_folding: Allow obsolete header folding (RFC 7230)
        header_map: How to handle underscores in headers: 'refuse', 'drop', 'dangerous'
        permit_unconventional_http_method: Allow non-standard HTTP methods
        permit_unconventional_http_version: Allow non-standard HTTP versions
        casefold_http_method: Uppercase HTTP methods
    """

    is_ssl: bool = False
    limit_request_fields: int = 100
    limit_request_field_size: int = 8190
    limit_request_line: int = 4094

    # PROXY protocol settings
    proxy_protocol: str = 'off'  # 'off', 'v1', 'v2', 'auto'
    proxy_allow_ips: List[str] = field(default_factory=lambda: ['127.0.0.1', '::1'])

    # Forwarded headers settings
    forwarded_allow_ips: List[str] = field(default_factory=lambda: ['127.0.0.1', '::1'])
    secure_scheme_headers: Dict[str, str] = field(default_factory=lambda: {
        'X-FORWARDED-PROTO': 'https'
    })
    forwarder_headers: List[str] = field(default_factory=list)

    # Header parsing options
    strip_header_spaces: bool = False
    permit_obsolete_folding: bool = False
    header_map: str = 'refuse'  # 'refuse', 'drop', 'dangerous'

    # Method/version handling
    permit_unconventional_http_method: bool = False
    permit_unconventional_http_version: bool = False
    casefold_http_method: bool = False

    # Cached network objects
    _proxy_allow_networks: Optional[List] = field(default=None, repr=False)
    _forwarded_allow_networks: Optional[List] = field(default=None, repr=False)

    def proxy_allow_networks(self) -> List:
        """Get pre-computed network objects for proxy_allow_ips."""
        if self._proxy_allow_networks is None:
            self._proxy_allow_networks = self._parse_networks(self.proxy_allow_ips)
        return self._proxy_allow_networks

    def forwarded_allow_networks(self) -> List:
        """Get pre-computed network objects for forwarded_allow_ips."""
        if self._forwarded_allow_networks is None:
            self._forwarded_allow_networks = self._parse_networks(self.forwarded_allow_ips)
        return self._forwarded_allow_networks

    def _parse_networks(self, ip_list: List[str]) -> List:
        """Parse IP list into network objects."""
        networks = []
        for ip_str in ip_list:
            if ip_str == '*':
                continue
            try:
                networks.append(ipaddress.ip_network(ip_str, strict=False))
            except ValueError:
                pass
        return networks

    @classmethod
    def from_dict(cls, d: dict) -> 'HTTPConfig':
        """Create HTTPConfig from dictionary (e.g., from Erlang)."""
        # Convert keys from snake_case or camelCase
        mapping = {
            'is_ssl': 'is_ssl',
            'isSsl': 'is_ssl',
            'limit_request_fields': 'limit_request_fields',
            'limitRequestFields': 'limit_request_fields',
            'limit_request_field_size': 'limit_request_field_size',
            'limitRequestFieldSize': 'limit_request_field_size',
            'limit_request_line': 'limit_request_line',
            'limitRequestLine': 'limit_request_line',
            'proxy_protocol': 'proxy_protocol',
            'proxyProtocol': 'proxy_protocol',
            'proxy_allow_ips': 'proxy_allow_ips',
            'proxyAllowIps': 'proxy_allow_ips',
            'forwarded_allow_ips': 'forwarded_allow_ips',
            'forwardedAllowIps': 'forwarded_allow_ips',
            'secure_scheme_headers': 'secure_scheme_headers',
            'secureSchemeHeaders': 'secure_scheme_headers',
            'forwarder_headers': 'forwarder_headers',
            'forwarderHeaders': 'forwarder_headers',
            'strip_header_spaces': 'strip_header_spaces',
            'stripHeaderSpaces': 'strip_header_spaces',
            'permit_obsolete_folding': 'permit_obsolete_folding',
            'permitObsoleteFolding': 'permit_obsolete_folding',
            'header_map': 'header_map',
            'headerMap': 'header_map',
            'permit_unconventional_http_method': 'permit_unconventional_http_method',
            'permitUnconventionalHttpMethod': 'permit_unconventional_http_method',
            'permit_unconventional_http_version': 'permit_unconventional_http_version',
            'permitUnconventionalHttpVersion': 'permit_unconventional_http_version',
            'casefold_http_method': 'casefold_http_method',
            'casefoldHttpMethod': 'casefold_http_method',
        }

        kwargs = {}
        for key, value in d.items():
            mapped_key = mapping.get(key, key)
            if mapped_key in cls.__dataclass_fields__:
                kwargs[mapped_key] = value

        return cls(**kwargs)
