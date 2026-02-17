---
title: Building Custom Apps
description: Create full applications with Hornbeam
order: 15
---

# Building Custom Apps

This guide shows how to build complete applications with Hornbeam, combining Python web frameworks with Erlang's infrastructure capabilities.

## Application Architecture

A typical Hornbeam application consists of:

```
my_app/
├── rebar.config           # Erlang dependencies
├── sys.config             # Erlang configuration
├── src/
│   ├── my_app.erl         # Erlang application
│   ├── my_app_sup.erl     # Supervisor
│   └── my_handlers.erl    # Custom Erlang handlers
├── priv/
│   └── python/
│       ├── app.py         # Python WSGI/ASGI app
│       ├── services.py    # Python services
│       └── requirements.txt
└── config/
    └── config.exs         # (optional) Elixir config
```

## Quick Start

### 1. Create Project Structure

```bash
mkdir my_app && cd my_app
rebar3 new app my_app
mkdir -p priv/python
```

### 2. Add Dependencies

```erlang
%% rebar.config
{deps, [
    {hornbeam, {git, "https://github.com/benoitc/hornbeam.git", {branch, "main"}}}
]}.
```

### 3. Create Python App

```python
# priv/python/app.py
from fastapi import FastAPI
from contextlib import asynccontextmanager
from hornbeam_erlang import register_hook, state_get, state_set, call

@asynccontextmanager
async def lifespan(app):
    # Register services with Erlang
    register_hook('python_service', PythonService())
    yield

app = FastAPI(lifespan=lifespan)

class PythonService:
    def process(self, data):
        return {'processed': data, 'status': 'ok'}

@app.get("/")
async def root():
    return {"message": "Hello from Hornbeam!"}

@app.get("/counter")
async def counter():
    from hornbeam_erlang import incr
    count = incr('request_counter')
    return {"count": count}

@app.post("/process")
async def process(data: dict):
    # Call Erlang function
    result = call('validate', data)
    if result.get('valid'):
        state_set(f"data:{data['id']}", data)
        return {"status": "stored"}
    return {"status": "invalid", "errors": result.get('errors')}
```

### 4. Create Erlang Application

```erlang
%% src/my_app.erl
-module(my_app).
-export([start/0, stop/0]).

start() ->
    %% Register Erlang functions callable from Python
    hornbeam:register_function(validate, fun validate/1),
    hornbeam:register_function(get_config, fun get_config/1),

    %% Start the server
    hornbeam:start("app:app", #{
        bind => "0.0.0.0:8000",
        worker_class => asgi,
        pythonpath => ["priv/python"]
    }).

stop() ->
    hornbeam:stop().

%% Validation function called from Python
validate([Data]) ->
    case maps:get(<<"id">>, Data, undefined) of
        undefined ->
            #{valid => false, errors => [<<"id is required">>]};
        Id when is_binary(Id), byte_size(Id) > 0 ->
            #{valid => true};
        _ ->
            #{valid => false, errors => [<<"id must be a non-empty string">>]}
    end.

%% Config function
get_config([Key]) ->
    application:get_env(my_app, binary_to_atom(Key, utf8), undefined).
```

### 5. Run

```bash
rebar3 shell
> my_app:start().
```

## Patterns

### Shared State Pattern

Use ETS for high-performance shared state between Python and Erlang:

```python
# Python side
from hornbeam_erlang import state_get, state_set, state_incr

class SessionManager:
    def create_session(self, user_id):
        session_id = generate_session_id()
        state_set(f'session:{session_id}', {
            'user_id': user_id,
            'created_at': time.time()
        })
        return session_id

    def get_session(self, session_id):
        return state_get(f'session:{session_id}')

    def track_activity(self, session_id):
        state_incr(f'activity:{session_id}')
```

```erlang
%% Erlang side - same state accessible
get_active_sessions() ->
    Keys = hornbeam_state:keys(<<"session:">>),
    [hornbeam_state:get(K) || K <- Keys].

cleanup_old_sessions(MaxAge) ->
    Now = erlang:system_time(second),
    Keys = hornbeam_state:keys(<<"session:">>),
    lists:foreach(fun(Key) ->
        case hornbeam_state:get(Key) of
            #{<<"created_at">> := Created} when Now - Created > MaxAge ->
                hornbeam_state:delete(Key);
            _ ->
                ok
        end
    end, Keys).
```

### Background Task Pattern

Use hooks for background processing:

```python
# Python: Register background worker
from hornbeam_erlang import register_hook

class BackgroundWorker:
    def process_image(self, image_url):
        image = download(image_url)
        processed = apply_filters(image)
        upload(processed)
        return {'status': 'completed', 'url': processed.url}

    def send_email(self, to, subject, body):
        smtp.send(to, subject, body)
        return {'sent': True}

register_hook('background', BackgroundWorker())
```

```erlang
%% Erlang: Queue background tasks
queue_image_processing(ImageUrl) ->
    %% Async - don't wait for result
    {ok, TaskId} = hornbeam_hooks:execute_async(
        <<"background">>,
        <<"process_image">>,
        [ImageUrl],
        #{}
    ),
    %% Store task ID for status checking
    hornbeam_state:set(<<"task:", TaskId/binary>>, #{
        status => pending,
        started => erlang:system_time(second)
    }),
    TaskId.

check_task_status(TaskId) ->
    hornbeam_state:get(<<"task:", TaskId/binary>>).
```

### Pub/Sub Pattern

Real-time updates using pub/sub:

```python
# Python: Publish updates
from hornbeam_erlang import publish

def update_product(product_id, data):
    # Update in database
    db.products.update(product_id, data)

    # Notify subscribers
    publish(f'product:{product_id}', {
        'type': 'updated',
        'product_id': product_id,
        'changes': data
    })
```

```erlang
%% Erlang: WebSocket handler subscribing to updates
websocket_init(State) ->
    ProductId = maps:get(product_id, State),
    hornbeam_pubsub:subscribe(<<"product:", ProductId/binary>>),
    {ok, State}.

websocket_info({pubsub, Topic, Message}, State) ->
    %% Forward to WebSocket client
    {reply, {text, jsx:encode(Message)}, State}.
```

### ML Service Pattern

Integrate ML models with caching:

```python
# Python: ML service with caching
from hornbeam_erlang import register_hook
from hornbeam_ml import cached_inference

class MLService:
    def __init__(self):
        self.embedding_model = load_embedding_model()
        self.classifier = load_classifier()

    def embed(self, text):
        # Cached: same text returns cached embedding
        return cached_inference(
            self.embedding_model.encode,
            text,
            cache_prefix='embed'
        )

    def classify(self, text):
        embedding = self.embed(text)
        return self.classifier.predict([embedding])[0]

    def similar(self, text, candidates):
        text_emb = self.embed(text)
        candidate_embs = [self.embed(c) for c in candidates]
        scores = cosine_similarity([text_emb], candidate_embs)[0]
        return sorted(zip(candidates, scores), key=lambda x: -x[1])

register_hook('ml', MLService())
```

```erlang
%% Erlang: Use ML service
search_similar(Query, Candidates) ->
    {ok, Results} = hornbeam_hooks:execute(
        <<"ml">>,
        <<"similar">>,
        [Query, Candidates],
        #{}
    ),
    Results.
```

### Distributed Pattern

Distribute work across cluster:

```python
# Python: Coordinator
from hornbeam_erlang import rpc_call, nodes

def distributed_inference(texts):
    """Distribute embedding computation across GPU nodes."""
    gpu_nodes = [n for n in nodes() if 'gpu' in n]

    if not gpu_nodes:
        # Local fallback
        return [model.encode(t) for t in texts]

    # Split work
    chunks = split_into_chunks(texts, len(gpu_nodes))
    results = []

    for node, chunk in zip(gpu_nodes, chunks):
        result = rpc_call(
            node,
            'ml_worker',
            'batch_encode',
            [chunk],
            timeout_ms=30000
        )
        results.extend(result)

    return results
```

## Custom Cowboy Routes

Add custom routes alongside your Python app:

```erlang
%% Start with custom routes
hornbeam:start("app:app", #{
    worker_class => asgi,
    pythonpath => ["priv/python"],
    routes => [
        %% Health check - pure Erlang, no Python
        {"/health", health_handler, []},

        %% Metrics endpoint
        {"/metrics", metrics_handler, []},

        %% WebSocket with custom handler
        {"/ws/[...]", my_websocket_handler, []}
    ]
}).
```

```erlang
%% health_handler.erl
-module(health_handler).
-export([init/2]).

init(Req, State) ->
    Reply = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        <<"{\"status\":\"ok\"}">>,
        Req
    ),
    {ok, Reply, State}.
```

## Configuration

### sys.config

```erlang
[
    {my_app, [
        {api_key, "secret"},
        {max_connections, 10000},
        {cache_ttl, 3600}
    ]},
    {hornbeam, [
        {bind, "0.0.0.0:8000"},
        {workers, 8},
        {worker_class, asgi},
        {timeout, 30000}
    ]}
].
```

### Environment Variables

```python
# Python: Access Erlang config
from hornbeam_erlang import call
import os

def get_config(key, default=None):
    # Try Erlang config first
    result = call('get_config', key)
    if result is not None:
        return result
    # Fall back to environment
    return os.environ.get(key.upper(), default)
```

## Production Deployment

### Supervisor Tree

```erlang
%% my_app_sup.erl
-module(my_app_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        %% Start Hornbeam as supervised child
        #{
            id => hornbeam,
            start => {my_app, start_hornbeam, []},
            restart => permanent,
            type => worker
        }
    ],
    {ok, {#{strategy => one_for_one}, Children}}.
```

### Release Configuration

```erlang
%% rebar.config
{relx, [
    {release, {my_app, "1.0.0"}, [
        my_app,
        hornbeam,
        sasl
    ]},
    {dev_mode, false},
    {include_erts, true},
    {extended_start_script, true},
    {sys_config, "config/sys.config"},
    {vm_args, "config/vm.args"}
]}.
```

### Docker

```dockerfile
FROM erlang:27 AS builder
WORKDIR /app
COPY . .
RUN rebar3 as prod release

FROM python:3.13-slim
COPY --from=builder /app/_build/prod/rel/my_app /app
COPY priv/python/requirements.txt /tmp/
RUN pip install -r /tmp/requirements.txt
WORKDIR /app
CMD ["bin/my_app", "foreground"]
```

## See Also

- [Hooks Guide](./hooks.md) - Bidirectional callback system
- [Distributed RPC Guide](./distributed-rpc.md) - Cluster patterns
- [ML Integration Guide](./ml-integration.md) - ML caching and inference
- [ASGI Guide](./asgi.md) - ASGI protocol details
