---
title: Building Erlang Apps
description: Embed Hornbeam in your Erlang/OTP applications
order: 17
---

# Building Erlang Apps

This guide shows how to build Erlang/OTP applications that embed Hornbeam as a component. You'll learn to create production-ready releases with supervision trees, custom handlers, and proper configuration.

## Project Setup

### Create New Project

```bash
rebar3 new app my_app
cd my_app
```

### Add Dependencies

```erlang
%% rebar.config
{deps, [
    {hornbeam, {git, "https://github.com/benoitc/hornbeam.git", {branch, "main"}}}
]}.

{shell, [
    {apps, [my_app]}
]}.

{relx, [
    {release, {my_app, "1.0.0"}, [
        my_app,
        hornbeam,
        sasl
    ]},
    {mode, dev},
    {extended_start_script, true},
    {sys_config, "config/sys.config"},
    {vm_args, "config/vm.args"}
]}.

{profiles, [
    {test, [
        {deps, [
            {hackney, "3.0.2"}
        ]}
    ]}
]}.
```

### Project Structure

```
my_app/
├── rebar.config
├── config/
│   ├── sys.config          # Application configuration
│   └── vm.args              # Erlang VM arguments
├── src/
│   ├── my_app.app.src       # Application resource file
│   ├── my_app_app.erl       # Application behaviour
│   ├── my_app_sup.erl       # Root supervisor
│   ├── my_app_web.erl       # Hornbeam integration
│   └── my_app_handlers.erl  # Custom Erlang handlers
└── priv/
    └── python/
        ├── app.py           # Python WSGI/ASGI app
        └── requirements.txt
```

## Application Module

### app.src

```erlang
%% src/my_app.app.src
{application, my_app, [
    {description, "My Hornbeam Application"},
    {vsn, "1.0.0"},
    {registered, []},
    {mod, {my_app_app, []}},
    {applications, [
        kernel,
        stdlib,
        hornbeam
    ]},
    {env, [
        {http_port, 8000},
        {python_app, "app:application"},
        {worker_class, wsgi}
    ]},
    {modules, []},
    {licenses, ["Apache-2.0"]},
    {links, []}
]}.
```

### Application Behaviour

```erlang
%% src/my_app_app.erl
-module(my_app_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    my_app_sup:start_link().

stop(_State) ->
    ok.
```

## Supervisor Tree

### Root Supervisor

```erlang
%% src/my_app_sup.erl
-module(my_app_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    Children = [
        %% Start Hornbeam web server
        #{
            id => my_app_web,
            start => {my_app_web, start_link, []},
            restart => permanent,
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
```

### Web Server Worker

```erlang
%% src/my_app_web.erl
-module(my_app_web).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    %% Register Erlang functions callable from Python
    register_functions(),

    %% Get configuration
    {ok, App} = application:get_env(my_app, python_app),
    {ok, Port} = application:get_env(my_app, http_port),
    {ok, WorkerClass} = application:get_env(my_app, worker_class),

    %% Start Hornbeam
    case hornbeam:start(App, #{
        bind => "0.0.0.0:" ++ integer_to_list(Port),
        worker_class => WorkerClass,
        pythonpath => [code:priv_dir(my_app) ++ "/python"]
    }) of
        ok ->
            logger:info("Hornbeam started on port ~p", [Port]),
            {ok, #{port => Port}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    hornbeam:stop(),
    ok.

%% Internal functions

register_functions() ->
    %% Register functions Python can call
    hornbeam:register_function(get_config, fun get_config/1),
    hornbeam:register_function(validate_request, fun validate_request/1),
    hornbeam:register_function(process_data, my_app_handlers, process_data),
    ok.

get_config([Key]) when is_binary(Key) ->
    case application:get_env(my_app, binary_to_atom(Key, utf8)) of
        {ok, Value} -> Value;
        undefined -> null
    end.

validate_request([Data]) when is_map(Data) ->
    %% Custom validation logic
    case maps:get(<<"id">>, Data, undefined) of
        undefined -> #{valid => false, error => <<"id required">>};
        _ -> #{valid => true}
    end.
```

## Custom Handlers

### Erlang Handlers

```erlang
%% src/my_app_handlers.erl
-module(my_app_handlers).
-export([process_data/1, handle_webhook/1]).

%% Called from Python via hornbeam:register_function
process_data([Data]) ->
    %% Process data using Erlang's concurrency
    Results = parallel_process(Data),
    #{status => ok, results => Results}.

handle_webhook([Payload]) ->
    %% Handle webhook asynchronously
    spawn(fun() ->
        process_webhook(Payload)
    end),
    #{accepted => true}.

%% Internal

parallel_process(Items) when is_list(Items) ->
    Parent = self(),
    Refs = [spawn_monitor(fun() ->
        Parent ! {self(), process_item(Item)}
    end) || Item <- Items],
    [receive
        {Pid, Result} -> Result
    after 5000 ->
        {error, timeout}
    end || {Pid, _Ref} <- Refs].

process_item(Item) ->
    %% Your processing logic
    Item.

process_webhook(Payload) ->
    %% Async webhook processing
    logger:info("Processing webhook: ~p", [Payload]).
```

### Hooks for Bidirectional Calls

```erlang
%% Register hooks for Python to call
init_hooks() ->
    %% Erlang handler for embeddings
    hornbeam_hooks:reg(<<"embeddings">>, fun(Action, Args, _Kwargs) ->
        case Action of
            <<"encode">> ->
                [Text] = Args,
                %% Call Python ML model via py module
                py:call(embedding_model, encode, [Text]);
            <<"similarity">> ->
                [A, B] = Args,
                py:call(embedding_model, similarity, [A, B])
        end
    end),

    %% Erlang handler for auth
    hornbeam_hooks:reg(<<"auth">>, my_app_auth, handle, 3),

    ok.
```

## Configuration

### sys.config

```erlang
%% config/sys.config
[
    {my_app, [
        {http_port, 8000},
        {python_app, "app:application"},
        {worker_class, asgi},
        {api_key, "${API_KEY}"},
        {db_pool_size, 10}
    ]},
    {hornbeam, [
        {workers, 4},
        {timeout, 30000},
        {max_requests, 10000}
    ]},
    {kernel, [
        {logger_level, info},
        {logger, [
            {handler, default, logger_std_h, #{
                formatter => {logger_formatter, #{
                    template => [time, " ", level, " ", msg, "\n"]
                }}
            }}
        ]}
    ]}
].
```

### vm.args

```
## config/vm.args
-name my_app@127.0.0.1
-setcookie mysecretcookie

+K true
+A 128
+SDio 128

-env ERL_MAX_PORTS 65536
-env ERL_FULLSWEEP_AFTER 10
```

## Python Integration

### WSGI App

```python
# priv/python/app.py
from hornbeam_erlang import call, state_get, state_set, state_incr

def application(environ, start_response):
    path = environ.get('PATH_INFO', '/')

    if path == '/':
        return handle_index(environ, start_response)
    elif path == '/api/process':
        return handle_process(environ, start_response)
    else:
        return handle_404(environ, start_response)

def handle_index(environ, start_response):
    # Get config from Erlang
    config = call('get_config', 'app_name')

    # Track request count
    count = state_incr('requests:total')

    start_response('200 OK', [('Content-Type', 'text/plain')])
    return [f'Welcome to {config}! Request #{count}'.encode()]

def handle_process(environ, start_response):
    import json

    # Read request body
    content_length = int(environ.get('CONTENT_LENGTH', 0))
    body = environ['wsgi.input'].read(content_length)
    data = json.loads(body)

    # Validate via Erlang
    validation = call('validate_request', data)
    if not validation.get('valid'):
        start_response('400 Bad Request', [('Content-Type', 'application/json')])
        return [json.dumps({'error': validation.get('error')}).encode()]

    # Process via Erlang (uses Erlang's parallel processing)
    result = call('process_data', data)

    start_response('200 OK', [('Content-Type', 'application/json')])
    return [json.dumps(result).encode()]

def handle_404(environ, start_response):
    start_response('404 Not Found', [('Content-Type', 'text/plain')])
    return [b'Not Found']
```

### ASGI App (FastAPI)

```python
# priv/python/app.py
from fastapi import FastAPI, HTTPException
from contextlib import asynccontextmanager
from hornbeam_erlang import call, state_incr, register_hook

@asynccontextmanager
async def lifespan(app):
    # Startup: register Python services
    register_hook('ml_service', MLService())
    yield
    # Shutdown: cleanup

app = FastAPI(lifespan=lifespan)

class MLService:
    def __init__(self):
        from sentence_transformers import SentenceTransformer
        self.model = SentenceTransformer('all-MiniLM-L6-v2')

    def encode(self, text):
        return self.model.encode(text).tolist()

@app.get("/")
async def root():
    count = state_incr('requests:total')
    return {"message": "Hello", "request_number": count}

@app.post("/api/process")
async def process(data: dict):
    # Validate via Erlang
    validation = call('validate_request', data)
    if not validation.get('valid'):
        raise HTTPException(400, validation.get('error'))

    # Process via Erlang
    result = call('process_data', data)
    return result
```

## Building Releases

### Development

```bash
# Compile and run shell
rebar3 shell

# Or run specific commands
rebar3 compile
erl -pa _build/default/lib/*/ebin -eval "application:ensure_all_started(my_app)"
```

### Production Release

```bash
# Build release
rebar3 as prod release

# Run
_build/prod/rel/my_app/bin/my_app foreground

# Or as daemon
_build/prod/rel/my_app/bin/my_app daemon
_build/prod/rel/my_app/bin/my_app stop
```

### Docker

```dockerfile
FROM erlang:27 AS builder
WORKDIR /app
COPY rebar.config rebar.lock ./
RUN rebar3 compile
COPY . .
RUN rebar3 as prod release

FROM python:3.13-slim
RUN apt-get update && apt-get install -y libncurses5 libssl3 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/_build/prod/rel/my_app /app
COPY priv/python/requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt
WORKDIR /app
EXPOSE 8000
CMD ["bin/my_app", "foreground"]
```

## Clustering

### Connecting Nodes

```erlang
%% In vm.args, use -name for distributed mode
%% -name my_app@192.168.1.10

%% Connect nodes programmatically
connect_to_cluster() ->
    Nodes = ['my_app@192.168.1.11', 'my_app@192.168.1.12'],
    [net_adm:ping(N) || N <- Nodes].
```

### Distributed State

```erlang
%% State is automatically shared via hornbeam_state (ETS)
%% For cross-node state, use hornbeam_dist

%% From Python
from hornbeam_erlang import rpc_call, nodes

def get_from_remote(key):
    for node in nodes():
        result = rpc_call(node, 'hornbeam_state', 'get', [key], 5000)
        if result is not None:
            return result
    return None
```

## Testing

### Common Test

```erlang
%% test/my_app_SUITE.erl
-module(my_app_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([test_api/1]).

all() -> [test_api].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(my_app),
    Config.

end_per_suite(_Config) ->
    application:stop(my_app),
    application:stop(hackney),
    ok.

test_api(_Config) ->
    {ok, 200, _Headers, ClientRef} = hackney:request(get, <<"http://localhost:8000/">>, [], <<>>, []),
    {ok, Body} = hackney:body(ClientRef),
    true = is_binary(Body),
    ok.
```

## API Reference

For complete Erlang API documentation, see:

- [Hornbeam on hex.pm](https://hexdocs.pm/hornbeam) - Module documentation
- [erlang_python on hex.pm](https://hexdocs.pm/erlang_python) - Python integration

## See Also

- [Custom Apps Guide](./custom-apps.md) - Python-focused patterns
- [Hooks Guide](./hooks.md) - Bidirectional callbacks
- [Distributed RPC Guide](./distributed-rpc.md) - Cluster communication
