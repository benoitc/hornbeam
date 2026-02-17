---
title: Hooks
description: Bidirectional Python/Erlang callback system
order: 14
---

# Hooks

Hooks provide a bidirectional callback system between Python and Erlang. They enable:

- **Python calling Erlang:** Execute Erlang functions from your Python web app
- **Erlang calling Python:** Invoke Python ML models or services from Erlang
- **Streaming:** Stream results from either side
- **Async execution:** Fire-and-forget or await results

## Concepts

A **hook** is a registered handler identified by an `app_path` string. Handlers can be:

- Python functions, classes, or instances
- Erlang functions or module:function references

When you call `execute(app_path, action, args)`, Hornbeam routes to the registered handler and calls the appropriate method/function.

## Python Handlers

### Function Handler

The simplest handler is a function that dispatches on action:

```python
from hornbeam_erlang import register_hook, execute

def embedding_handler(action, *args, **kwargs):
    if action == 'encode':
        text = args[0]
        return model.encode(text)
    elif action == 'similarity':
        a, b = args[0], args[1]
        return cosine_similarity(
            model.encode(a),
            model.encode(b)
        )
    else:
        raise ValueError(f"Unknown action: {action}")

# Register during app startup
register_hook('embeddings', embedding_handler)

# Call from anywhere
embedding = execute('embeddings', 'encode', "Hello world")
sim = execute('embeddings', 'similarity', "Hello", "Hi there")
```

### Class Handler

For stateful handlers, use a class. Hornbeam instantiates it and calls methods matching action names:

```python
from hornbeam_erlang import register_hook

class EmbeddingService:
    def __init__(self):
        # Called once when hook is registered
        self.model = SentenceTransformer('all-MiniLM-L6-v2')

    def encode(self, text):
        """Action: encode"""
        return self.model.encode(text).tolist()

    def similarity(self, text_a, text_b):
        """Action: similarity"""
        emb_a = self.model.encode(text_a)
        emb_b = self.model.encode(text_b)
        return float(cosine_similarity([emb_a], [emb_b])[0][0])

    def batch_encode(self, texts):
        """Action: batch_encode"""
        return self.model.encode(texts).tolist()

# Register class (instantiated automatically)
register_hook('embeddings', EmbeddingService)
```

### Instance Handler

If you need custom initialization, pass an instance:

```python
from hornbeam_erlang import register_hook

class MLService:
    def __init__(self, model_name, device):
        self.model = load_model(model_name).to(device)

    def predict(self, input_data):
        return self.model(input_data)

# Custom initialization
service = MLService('bert-base', device='cuda:0')
register_hook('ml', service)
```

## Erlang Handlers

### Function Handler

Register an anonymous function:

```erlang
hornbeam_hooks:reg(<<"calculator">>, fun(Action, Args, _Kwargs) ->
    case Action of
        <<"add">> ->
            [A, B] = Args,
            A + B;
        <<"multiply">> ->
            [A, B] = Args,
            A * B;
        _ ->
            {error, unknown_action}
    end
end).
```

### Module Handler

Register a module:function reference:

```erlang
%% In my_handler.erl
-module(my_handler).
-export([handle/3]).

handle(<<"get_user">>, [UserId], _Kwargs) ->
    user_db:fetch(UserId);
handle(<<"create_user">>, [Name, Email], _Kwargs) ->
    user_db:create(#{name => Name, email => Email});
handle(Action, _Args, _Kwargs) ->
    {error, {unknown_action, Action}}.

%% Register
hornbeam_hooks:reg(<<"users">>, my_handler, handle, 3).
```

## Calling Hooks

### From Python

```python
from hornbeam_erlang import execute, execute_async, await_result, stream

# Synchronous call
result = execute('embeddings', 'encode', text)

# Call with kwargs
result = execute('service', 'process', data, option='fast')

# Async call
task_id = execute_async('ml', 'train', large_dataset)
# ... do other work ...
result = await_result(task_id, timeout_ms=60000)

# Streaming
for chunk in stream('llm', 'generate', prompt):
    print(chunk, end='', flush=True)
```

### From Erlang

```erlang
%% Synchronous
{ok, Embedding} = hornbeam_hooks:execute(<<"embeddings">>, <<"encode">>, [Text], #{}).

%% Async
{ok, TaskId} = hornbeam_hooks:execute_async(<<"ml">>, <<"train">>, [Data], #{}),
%% ... do other work ...
{ok, Result} = hornbeam_hooks:await_result(TaskId, 60000).

%% Streaming
{ok, Gen} = hornbeam_hooks:stream(<<"llm">>, <<"generate">>, [Prompt], #{}),
stream_loop(Gen).

stream_loop(Gen) ->
    case Gen() of
        {value, Chunk} ->
            io:format("~s", [Chunk]),
            stream_loop(Gen);
        done ->
            ok
    end.
```

## Streaming Handlers

### Python Streaming

Return a generator for streaming responses:

```python
from hornbeam_erlang import register_hook

def llm_handler(action, *args, **kwargs):
    if action == 'generate':
        prompt = args[0]
        # Return generator for streaming
        return generate_stream(prompt)

def generate_stream(prompt):
    response = openai.chat.completions.create(
        model="gpt-4",
        messages=[{"role": "user", "content": prompt}],
        stream=True
    )
    for chunk in response:
        if chunk.choices[0].delta.content:
            yield chunk.choices[0].delta.content

register_hook('llm', llm_handler)
```

### Erlang Streaming

Use helper functions to create streams:

```erlang
%% Stream from a list
hornbeam_hooks:reg(<<"numbers">>, fun(<<"range">>, [Start, End], _) ->
    List = lists:seq(Start, End),
    hornbeam_hooks:stream_from_list(List)
end).

%% Stream from a function
hornbeam_hooks:reg(<<"counter">>, fun(<<"count">>, [Max], _) ->
    Ref = make_ref(),
    put({counter, Ref}, 0),
    hornbeam_hooks:stream_from_fun(fun() ->
        N = get({counter, Ref}),
        if
            N >= Max -> hornbeam_hooks:stream_done();
            true ->
                put({counter, Ref}, N + 1),
                hornbeam_hooks:stream_chunk(N)
        end
    end)
end).
```

## ASGI Lifespan Integration

Register hooks during ASGI lifespan startup:

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI
from hornbeam_erlang import register_hook, unregister_hook

@asynccontextmanager
async def lifespan(app):
    # Startup: register hooks
    model = load_embedding_model()

    def handler(action, *args, **kwargs):
        if action == 'encode':
            return model.encode(args[0]).tolist()

    register_hook('embeddings', handler)

    yield  # App runs here

    # Shutdown: cleanup
    unregister_hook('embeddings')

app = FastAPI(lifespan=lifespan)

@app.post("/embed")
async def embed(text: str):
    # Use the registered hook
    from hornbeam_erlang import execute
    embedding = execute('embeddings', 'encode', text)
    return {"embedding": embedding}
```

## Cross-Language Patterns

### Python Service Called from Erlang

```python
# Python: Register ML service
from hornbeam_erlang import register_hook

class ImageClassifier:
    def __init__(self):
        self.model = load_model('resnet50')

    def classify(self, image_url):
        image = download_image(image_url)
        return self.model.predict(image)

register_hook('classifier', ImageClassifier)
```

```erlang
%% Erlang: Call from request handler
handle_request(Req) ->
    ImageUrl = get_image_url(Req),
    {ok, Classification} = hornbeam_hooks:execute(
        <<"classifier">>,
        <<"classify">>,
        [ImageUrl],
        #{}
    ),
    respond_json(Req, Classification).
```

### Erlang Service Called from Python

```erlang
%% Erlang: Register authentication service
hornbeam_hooks:reg(<<"auth">>, fun
    (<<"verify_token">>, [Token], _) ->
        case auth_server:verify(Token) of
            {ok, UserId} -> {ok, UserId};
            error -> {error, invalid_token}
        end;
    (<<"create_session">>, [UserId], _) ->
        SessionId = auth_server:create_session(UserId),
        {ok, SessionId}
end).
```

```python
# Python: Call from web handler
from hornbeam_erlang import execute

def login_required(f):
    def wrapper(request, *args, **kwargs):
        token = request.headers.get('Authorization')
        try:
            user_id = execute('auth', 'verify_token', token)
            request.user_id = user_id
            return f(request, *args, **kwargs)
        except:
            return {'error': 'Unauthorized'}, 401
    return wrapper
```

## Best Practices

### 1. Use Descriptive App Paths

```python
# Good
register_hook('embeddings.sentence_transformer', handler)
register_hook('auth.token_validator', handler)

# Avoid
register_hook('h1', handler)
```

### 2. Handle Errors Gracefully

```python
def handler(action, *args, **kwargs):
    try:
        if action == 'encode':
            return model.encode(args[0])
    except Exception as e:
        # Return error tuple for Erlang compatibility
        return {'error': str(e)}
```

### 3. Register During Lifespan

```python
# Good: Register in lifespan
@asynccontextmanager
async def lifespan(app):
    register_hook('service', handler)
    yield
    unregister_hook('service')

# Avoid: Register at module level (may cause issues)
register_hook('service', handler)  # Don't do this
```

### 4. Use Streaming for Large Responses

```python
# Good: Stream large responses
def handler(action, *args, **kwargs):
    if action == 'get_all_users':
        return stream_users()  # Generator

def stream_users():
    for batch in db.iter_users(batch_size=100):
        for user in batch:
            yield user

# Avoid: Load everything in memory
def handler(action, *args, **kwargs):
    if action == 'get_all_users':
        return list(db.get_all_users())  # Memory hog!
```

## See Also

- [Python API Reference](../reference/python-api.md) - Full function documentation
- [Erlang API Reference](https://hexdocs.pm/hornbeam) - Erlang modules (hex.pm)
- [Custom Apps Guide](./custom-apps.md) - Building full applications
