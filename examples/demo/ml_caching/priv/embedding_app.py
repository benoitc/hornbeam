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

"""Embedding App - Similar to gunicorn's DirtyApp pattern.

This module provides ML embedding functionality via a singleton instance.
The Erlang process (ml_caching_embedder) calls init_app() to load the model,
then routes hook calls to embed() and similarity().

Usage from Erlang:
    %% Initialize (done once by ml_caching_embedder)
    py:call(embedding_app, init_app, []).

    %% Compute embeddings
    py:call(embedding_app, embed, [Texts]).

    %% Compute similarity
    py:call(embedding_app, similarity, [Text1, Text2]).

    %% Cleanup
    py:call(embedding_app, close_app, []).
"""


class EmbeddingApp:
    """Embedding application with persistent model state."""

    def __init__(self, model_name: str = "all-MiniLM-L6-v2"):
        self.model_name = model_name
        self.model = None
        self._initialized = False

    def init(self):
        """Initialize the app - load the model.

        Called once after instantiation. This is where heavy
        initialization (loading ML models, etc.) should happen.
        """
        if self._initialized:
            return

        print(f"EmbeddingApp: Loading model {self.model_name}...", flush=True)
        from sentence_transformers import SentenceTransformer
        self.model = SentenceTransformer(self.model_name)
        self._initialized = True
        print(f"EmbeddingApp: Model loaded (dim={self.model.get_sentence_embedding_dimension()})", flush=True)

    def embed(self, texts):
        """Encode texts into embeddings.

        Args:
            texts: List of strings to encode

        Returns:
            List of embeddings (list of floats)
        """
        if not self._initialized:
            self.init()

        # Handle bytes from Erlang
        if isinstance(texts, (str, bytes)):
            texts = [texts]
        texts = [t.decode() if isinstance(t, bytes) else t for t in texts]

        embeddings = self.model.encode(texts)
        return embeddings.tolist()

    def similarity(self, text1, text2):
        """Compute cosine similarity between two texts.

        Args:
            text1: First text
            text2: Second text

        Returns:
            Cosine similarity score (float)
        """
        if not self._initialized:
            self.init()

        import numpy as np
        from numpy.linalg import norm

        if isinstance(text1, bytes):
            text1 = text1.decode()
        if isinstance(text2, bytes):
            text2 = text2.decode()

        embeddings = self.model.encode([text1, text2])
        cos_sim = np.dot(embeddings[0], embeddings[1]) / (norm(embeddings[0]) * norm(embeddings[1]))
        return float(cos_sim)

    def close(self):
        """Cleanup resources."""
        self.model = None
        self._initialized = False


# =============================================================================
# Singleton instance and module-level functions
# =============================================================================

_instance = None


def init_app(model_name: str = "all-MiniLM-L6-v2"):
    """Initialize the singleton embedding app.

    Called by Erlang ml_caching_embedder during startup.
    """
    global _instance
    if _instance is None:
        _instance = EmbeddingApp(model_name)
    _instance.init()
    return "ok"


def embed(texts):
    """Compute embeddings for texts.

    Called by Erlang hook handler.
    """
    if _instance is None:
        raise RuntimeError("EmbeddingApp not initialized - call init_app() first")
    return _instance.embed(texts)


def similarity(text1, text2):
    """Compute cosine similarity between two texts.

    Called by Erlang hook handler.
    """
    if _instance is None:
        raise RuntimeError("EmbeddingApp not initialized - call init_app() first")
    return _instance.similarity(text1, text2)


def close_app():
    """Cleanup the singleton instance.

    Called by Erlang ml_caching_embedder during shutdown.
    """
    global _instance
    if _instance is not None:
        _instance.close()
        _instance = None
    return "ok"
