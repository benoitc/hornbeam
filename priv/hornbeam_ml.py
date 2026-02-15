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

"""ML caching for hornbeam.

Erlang handles concurrency - each request runs in its own Erlang process.
Python code can be synchronous. This module provides ETS-backed caching
to avoid redundant computation.

Example:
    from hornbeam_ml import cached_inference

    def application(environ, start_response):
        # Cached in ETS - identical inputs return cached results
        embedding = cached_inference(model.encode, text)

        # Just call model directly - Erlang handles concurrency
        result = model.predict(data)

        start_response('200 OK', [('Content-Type', 'application/json')])
        return [json.dumps(result).encode()]
"""

import hashlib
from typing import Any, Callable, Optional, TypeVar

try:
    from hornbeam_erlang import state_get, state_set, state_incr
except ImportError:
    def state_get(k): return None
    def state_set(k, v): pass
    def state_incr(k, d=1): return d


T = TypeVar('T')


def _make_cache_key(prefix: str, input_data: Any) -> str:
    """Create cache key from input data."""
    if isinstance(input_data, bytes):
        data_str = input_data.decode('utf-8', errors='replace')
    elif isinstance(input_data, str):
        data_str = input_data
    else:
        data_str = str(input_data)
    hash_hex = hashlib.sha256(data_str.encode('utf-8')).hexdigest()[:32]
    return f"{prefix}:{hash_hex}"


def _to_cacheable(value: Any) -> Any:
    """Convert to cacheable format (handle numpy arrays)."""
    if hasattr(value, 'tolist'):
        return value.tolist()
    if isinstance(value, list):
        return [_to_cacheable(v) for v in value]
    if isinstance(value, dict):
        return {k: _to_cacheable(v) for k, v in value.items()}
    return value


def cached_inference(
    fn: Callable[[Any], T],
    input_data: Any,
    cache_key: Optional[str] = None,
    cache_prefix: str = "ml"
) -> T:
    """Run inference with ETS caching.

    Identical inputs return cached results instantly.
    Cache is shared across all requests (ETS).

    Args:
        fn: Inference function
        input_data: Input to the function
        cache_key: Optional explicit cache key
        cache_prefix: Prefix for cache keys

    Returns:
        Result (from cache or computed)

    Example:
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer('all-MiniLM-L6-v2')

        # First call computes and caches
        emb1 = cached_inference(model.encode, "hello")

        # Second call returns from cache
        emb2 = cached_inference(model.encode, "hello")  # instant
    """
    if cache_key is None:
        cache_key = _make_cache_key(cache_prefix, input_data)

    # Check cache
    cached = state_get(cache_key)
    if cached is not None:
        state_incr("ml_cache_hits")
        return cached

    # Compute
    state_incr("ml_cache_misses")
    result = fn(input_data)

    # Cache
    state_set(cache_key, _to_cacheable(result))
    return result


def cache_stats() -> dict:
    """Get cache statistics."""
    hits = state_get("ml_cache_hits") or 0
    misses = state_get("ml_cache_misses") or 0
    total = hits + misses
    return {
        "hits": hits,
        "misses": misses,
        "hit_rate": hits / total if total > 0 else 0.0
    }
