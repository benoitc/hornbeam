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

"""Sentence-transformers model wrapper for Erlang-Python binding.

Called from Erlang via py:call/3 to:
- Load sentence-transformers models
- Compute embeddings for texts
- Compute similarity between texts
"""

from typing import List, Tuple
import numpy as np

_models = {}


def init():
    """Initialize the module."""
    try:
        from sentence_transformers import SentenceTransformer
        print("sentence-transformers loaded successfully")
    except ImportError:
        raise ImportError(
            "sentence-transformers not installed. "
            "Run: pip install sentence-transformers"
        )


def load_model(model_name: str):
    """Load a sentence-transformers model."""
    if isinstance(model_name, bytes):
        model_name = model_name.decode()

    if model_name in _models:
        print(f"Using cached model: {model_name}")
        return _models[model_name]

    from sentence_transformers import SentenceTransformer

    print(f"Loading model: {model_name}...")
    model = SentenceTransformer(model_name)
    _models[model_name] = model
    print(f"Model loaded: {model_name} (dim={model.get_sentence_embedding_dimension()})")

    return model


def encode(model, texts: List[str]) -> List[List[float]]:
    """Encode texts into embeddings."""
    texts = [t.decode() if isinstance(t, bytes) else t for t in texts]
    embeddings = model.encode(texts, convert_to_numpy=True)
    return embeddings.tolist()


def similarity(model, text1: str, text2: str) -> float:
    """Compute cosine similarity between two texts."""
    if isinstance(text1, bytes):
        text1 = text1.decode()
    if isinstance(text2, bytes):
        text2 = text2.decode()

    embeddings = model.encode([text1, text2], convert_to_numpy=True)

    from numpy.linalg import norm
    cos_sim = np.dot(embeddings[0], embeddings[1]) / (norm(embeddings[0]) * norm(embeddings[1]))

    return float(cos_sim)


def find_most_similar(model, query: str, candidates: List[str]) -> Tuple[int, float, str]:
    """Find the most similar text from candidates."""
    if isinstance(query, bytes):
        query = query.decode()
    candidates = [c.decode() if isinstance(c, bytes) else c for c in candidates]

    query_emb = model.encode([query], convert_to_numpy=True)[0]
    cand_embs = model.encode(candidates, convert_to_numpy=True)

    from numpy.linalg import norm
    similarities = []
    for cand_emb in cand_embs:
        cos_sim = np.dot(query_emb, cand_emb) / (norm(query_emb) * norm(cand_emb))
        similarities.append(cos_sim)

    best_idx = int(np.argmax(similarities))
    best_score = float(similarities[best_idx])

    return (best_idx, best_score, candidates[best_idx])
