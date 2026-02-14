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

"""Embedding service with Erlang-backed caching.

This example demonstrates how to use hornbeam with an ML model,
using Erlang ETS for caching embeddings.
"""

import json
import hashlib

# These will be registered by Erlang
from erlang import cache_get, cache_set, state_incr, state_get

# Model loading (lazy)
_model = None


def get_model():
    """Lazy load the embedding model."""
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer('all-MiniLM-L6-v2')
    return _model


def embed_with_cache(text):
    """Generate embedding with Erlang ETS cache."""
    key = hashlib.md5(text.encode()).hexdigest()

    # Check Erlang cache
    cached = cache_get(key)
    if cached is not None:
        state_incr('cache_hits')
        return cached

    # Compute embedding
    embedding = get_model().encode(text).tolist()

    # Store in Erlang cache
    cache_set(key, embedding)
    state_incr('cache_misses')
    return embedding


def application(environ, start_response):
    """WSGI application for embedding service."""
    state_incr('requests_total')

    path = environ.get('PATH_INFO', '/')
    method = environ.get('REQUEST_METHOD', 'GET')

    if method == 'POST' and path == '/embed':
        # Read request body
        content_length = int(environ.get('CONTENT_LENGTH', 0))
        if content_length > 0:
            body = environ['wsgi.input']
            if isinstance(body, bytes):
                data = json.loads(body)
            else:
                data = json.loads(body.read(content_length))
        else:
            data = {}

        texts = data.get('texts', [])

        # Generate embeddings with caching
        embeddings = [embed_with_cache(t) for t in texts]

        response = json.dumps({'embeddings': embeddings})
        start_response('200 OK', [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(response)))
        ])
        return [response.encode()]

    if path == '/metrics':
        # Return metrics from Erlang shared state
        metrics = {
            'requests_total': state_get('requests_total') or 0,
            'cache_hits': state_get('cache_hits') or 0,
            'cache_misses': state_get('cache_misses') or 0,
        }
        response = json.dumps(metrics)
        start_response('200 OK', [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(response)))
        ])
        return [response.encode()]

    if path == '/':
        body = b'Embedding Service - POST /embed with {"texts": [...]} or GET /metrics\n'
        start_response('200 OK', [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ])
        return [body]

    start_response('404 Not Found', [('Content-Type', 'text/plain')])
    return [b'Not Found']
