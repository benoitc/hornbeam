# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0

"""Streaming LLM Chat API.

This example demonstrates:
- ASGI streaming responses for LLM output
- Erlang ETS caching for conversation history
- Lifespan protocol for model loading

Run with:
    hornbeam:start("llm_chat.app:app", #{worker_class => asgi, lifespan => on}).

Test with:
    curl -X POST http://localhost:8000/chat \
         -H "Content-Type: application/json" \
         -d '{"prompt": "Hello, how are you?"}'
"""

import json
from typing import Optional

# Try to import transformers - gracefully degrade if not available
try:
    from transformers import pipeline, AutoModelForCausalLM, AutoTokenizer
    HAS_TRANSFORMERS = True
except ImportError:
    HAS_TRANSFORMERS = False

# Import hornbeam utilities
try:
    from hornbeam_erlang import state_get, state_set, state_incr
    from hornbeam_ml import ModelRegistry
except ImportError:
    # Fallback for testing
    def state_get(k): return None
    def state_set(k, v): pass
    def state_incr(k, d=1): return d
    class ModelRegistry:
        _models = {}
        @classmethod
        def register(cls, n, m): cls._models[n] = m
        @classmethod
        def get(cls, n): return cls._models.get(n)

# Global generator (loaded at startup)
generator = None


async def lifespan(scope, receive, send):
    """ASGI lifespan handler for model loading."""
    global generator

    message = await receive()
    if message['type'] == 'lifespan.startup':
        if HAS_TRANSFORMERS:
            try:
                # Load a small model for demo
                # In production, use a larger model or API
                generator = pipeline(
                    'text-generation',
                    model='gpt2',
                    device=-1  # CPU
                )
                ModelRegistry.register('llm', generator)
                await send({'type': 'lifespan.startup.complete'})
            except Exception as e:
                await send({
                    'type': 'lifespan.startup.failed',
                    'message': str(e)
                })
        else:
            # No transformers - use mock generator
            def mock_generate(prompt, **kwargs):
                return [{'generated_text': f"Mock response to: {prompt}"}]
            generator = mock_generate
            ModelRegistry.register('llm', mock_generate)
            await send({'type': 'lifespan.startup.complete'})
        return

    # Wait for shutdown
    message = await receive()
    if message['type'] == 'lifespan.shutdown':
        # Cleanup
        generator = None
        await send({'type': 'lifespan.shutdown.complete'})


async def handle_chat(scope, receive, send):
    """Handle chat request with streaming response."""
    global generator

    # Track request
    state_incr('llm_requests')

    # Read request body
    body = b''
    while True:
        message = await receive()
        body += message.get('body', b'')
        if not message.get('more_body', False):
            break

    try:
        data = json.loads(body)
        prompt = data.get('prompt', '')
    except json.JSONDecodeError:
        await send({
            'type': 'http.response.start',
            'status': 400,
            'headers': [(b'content-type', b'application/json')]
        })
        await send({
            'type': 'http.response.body',
            'body': json.dumps({'error': 'Invalid JSON'}).encode()
        })
        return

    if not prompt:
        await send({
            'type': 'http.response.start',
            'status': 400,
            'headers': [(b'content-type', b'application/json')]
        })
        await send({
            'type': 'http.response.body',
            'body': json.dumps({'error': 'Missing prompt'}).encode()
        })
        return

    # Store conversation in ETS
    conv_id = data.get('conversation_id', 'default')
    history = state_get(f'conv:{conv_id}') or []
    history.append({'role': 'user', 'content': prompt})
    state_set(f'conv:{conv_id}', history)

    # Start streaming response
    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [(b'content-type', b'text/event-stream')]
    })

    # Generate response
    if generator is None:
        # Model not loaded
        chunk = f"data: {json.dumps({'text': 'Model not loaded', 'done': True})}\n\n"
        await send({
            'type': 'http.response.body',
            'body': chunk.encode(),
            'more_body': False
        })
        return

    # Generate text
    try:
        outputs = generator(
            prompt,
            max_length=100,
            num_return_sequences=1,
            do_sample=True,
            temperature=0.7
        )

        # In a real implementation with a streaming model,
        # you would yield tokens as they're generated.
        # For demo, we send the full response.
        text = outputs[0]['generated_text']

        # Send response chunks (simulating streaming)
        chunk = f"data: {json.dumps({'text': text, 'done': True})}\n\n"
        await send({
            'type': 'http.response.body',
            'body': chunk.encode(),
            'more_body': True
        })

        # Store response in history
        history.append({'role': 'assistant', 'content': text})
        state_set(f'conv:{conv_id}', history)
        state_incr('llm_tokens', len(text.split()))

    except Exception as e:
        chunk = f"data: {json.dumps({'error': str(e), 'done': True})}\n\n"
        await send({
            'type': 'http.response.body',
            'body': chunk.encode(),
            'more_body': True
        })

    # End stream
    await send({
        'type': 'http.response.body',
        'body': b'',
        'more_body': False
    })


async def handle_stats(scope, receive, send):
    """Return API statistics."""
    stats = {
        'requests': state_get('llm_requests') or 0,
        'tokens': state_get('llm_tokens') or 0,
        'model_loaded': generator is not None
    }

    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [(b'content-type', b'application/json')]
    })
    await send({
        'type': 'http.response.body',
        'body': json.dumps(stats).encode()
    })


async def app(scope, receive, send):
    """Main ASGI application."""
    if scope['type'] == 'lifespan':
        await lifespan(scope, receive, send)
        return

    if scope['type'] != 'http':
        return

    path = scope['path']
    method = scope['method']

    if path == '/chat' and method == 'POST':
        await handle_chat(scope, receive, send)
    elif path == '/stats' and method == 'GET':
        await handle_stats(scope, receive, send)
    else:
        await send({
            'type': 'http.response.start',
            'status': 404,
            'headers': [(b'content-type', b'text/plain')]
        })
        await send({
            'type': 'http.response.body',
            'body': b'Not Found'
        })
