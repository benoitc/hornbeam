# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0
#
# Fixture module for hornbeam_doc_python_api_SUITE.
#
# Every function below wraps a runnable code block from
# docs/reference/python-api.md as closely as possible. Each is invoked via
# py:call from the suite, so the bidirectional Python<->Erlang callback
# machinery is exercised end-to-end (which the suspension-based py:exec
# path doesn't reliably support for nested register_hook flows).

# ---------------------------------------------------------------------------
# Sanity probe used to debug nested-callback deadlocks.
# ---------------------------------------------------------------------------

def _warmup():
    """Prime every kind of Python <-> Erlang callback the snippet tests
    will use, so the FIRST hook-related test in the suite doesn't hit
    the cold-context lockout we observed.
    """
    from hornbeam_erlang import (state_get, register_hook, execute,
                                 unregister_hook)
    # one-level callback
    state_get('whatever')

    # two-level (Python -> Erlang -> Python) via a hook + execute round-trip
    def _h(action, *args, **kwargs):
        return action

    register_hook('_warmup', _h)
    try:
        execute('_warmup', 'ping')
    finally:
        unregister_hook('_warmup')

    return 'ok'


# ---------------------------------------------------------------------------
# Hooks (snippet 25, 26, 29, 31)
# ---------------------------------------------------------------------------

def register_hook_function_handler():
    """Doc snippet 25: function-style hook + execute round-trip."""
    from hornbeam_erlang import register_hook, execute, unregister_hook

    class _Model:
        def encode(self, text):
            return [len(text)]
    model = _Model()
    def cosine_sim(a, b):
        return 0.42

    def my_handler(action, *args, **kwargs):
        if action == 'encode':
            return model.encode(args[0])
        elif action == 'similarity':
            return cosine_sim(args[0], args[1])

    # Use a test-unique app_path so a stale registration from another
    # case can't shadow this one.
    register_hook('embeddings_fn', my_handler)
    try:
        return [
            execute('embeddings_fn', 'encode', 'hello'),
            execute('embeddings_fn', 'similarity', [1], [2]),
        ]
    finally:
        unregister_hook('embeddings_fn')


def register_hook_class_handler():
    """Doc snippet 26: class-style hook."""
    from hornbeam_erlang import register_hook, execute, unregister_hook

    def load_model():
        class _M:
            def encode(self, text):
                return [len(text)]
        return _M()

    def cosine_sim(a, b):
        return 0.99

    class EmbeddingService:
        def __init__(self):
            self.model = load_model()

        def encode(self, text):
            return self.model.encode(text)

        def similarity(self, a, b):
            return cosine_sim(a, b)

    register_hook('embeddings_class', EmbeddingService)
    try:
        return [
            execute('embeddings_class', 'encode', 'abc'),
            execute('embeddings_class', 'similarity', [1], [2]),
        ]
    finally:
        unregister_hook('embeddings_class')


def execute_calls_registered_hook():
    """Doc snippet 29: execute over an instance handler."""
    from hornbeam_erlang import register_hook, execute, unregister_hook

    class _Svc:
        def encode(self, text):
            return [len(text)]
        def similarity(self, a, b):
            return 1.0

    register_hook('embeddings_exec', _Svc())
    try:
        embedding = execute('embeddings_exec', 'encode', 'text')
        similarity = execute('embeddings_exec', 'similarity', 'text1', 'text2')
        return [embedding, similarity]
    finally:
        unregister_hook('embeddings_exec')


def execute_async_returns_task_id():
    """Doc snippet 31: execute_async + await_result."""
    from hornbeam_erlang import register_hook, execute_async, await_result, unregister_hook

    class _ML:
        def train(self, dataset):
            return {'epochs': 1, 'loss': 0.0}

    register_hook('ml', _ML())
    try:
        task_id = execute_async('ml', 'train', ['x'])
        result = await_result(task_id, timeout_ms=5000)
        return [
            isinstance(task_id, (str, bytes)),
            result['epochs'] if isinstance(result, dict) else result,
        ]
    finally:
        unregister_hook('ml')


# ---------------------------------------------------------------------------
# Streaming (snippet 34, 36)
# ---------------------------------------------------------------------------

def stream_yields_chunks():
    """Doc snippet 34: stream over a generator hook."""
    from hornbeam_erlang import register_hook, stream, unregister_hook

    class _LLM:
        def generate(self, prompt):
            for tok in ['hel', 'lo']:
                yield tok

    register_hook('llm', _LLM())
    try:
        chunks = []
        for chunk in stream('llm', 'generate', 'hi'):
            chunks.append(chunk)
        return ''.join(c if isinstance(c, str) else c.decode() for c in chunks)
    finally:
        unregister_hook('llm')


def stream_async_callable():
    """Doc snippet 36: verify stream_async is callable + sync stream works."""
    from hornbeam_erlang import register_hook, stream_async, stream, unregister_hook

    class _LLM2:
        def generate(self, prompt):
            for tok in ['ab', 'cd']:
                yield tok

    register_hook('llm2', _LLM2())
    try:
        if not callable(stream_async):
            return 'not_callable'
        chunks = list(stream('llm2', 'generate', 'p'))
        return ''.join(c if isinstance(c, str) else c.decode() for c in chunks)
    finally:
        unregister_hook('llm2')
