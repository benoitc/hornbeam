---
title: Erlang API Reference
description: Hornbeam Erlang module reference
order: 31
---

# Erlang API Reference

This document covers all Hornbeam Erlang modules and functions.

## hornbeam

Main application module.

### start/1, start/2

Start the Hornbeam server.

```erlang
-spec start(AppSpec :: string()) -> {ok, pid()} | {error, term()}.
-spec start(AppSpec :: string(), Options :: map()) -> {ok, pid()} | {error, term()}.

%% Examples
hornbeam:start("myapp:application").
hornbeam:start("myapp:app", #{worker_class => asgi, workers => 4}).
```

### stop/0

Stop the Hornbeam server.

```erlang
-spec stop() -> ok.

hornbeam:stop().
```

### register_function/2, register_function/3

Register an Erlang function callable from Python.

```erlang
-spec register_function(Name :: atom(), Fun :: function()) -> ok.
-spec register_function(Name :: atom(), Module :: atom(), Function :: atom()) -> ok.

%% Register anonymous function
hornbeam:register_function(add, fun([A, B]) -> A + B end).

%% Register module function
hornbeam:register_function(get_user, user_db, fetch).

%% Called from Python
%% from hornbeam_erlang import call
%% result = call('add', 1, 2)
```

### unregister_function/1

Remove a registered function.

```erlang
-spec unregister_function(Name :: atom()) -> ok.

hornbeam:unregister_function(add).
```

### pool_stats/0

Get worker pool statistics.

```erlang
-spec pool_stats() -> map().

Stats = hornbeam:pool_stats().
%% #{
%%   workers => 4,
%%   busy => 2,
%%   available => 2,
%%   requests => 1000
%% }
```

## hornbeam_state

ETS-backed shared state module.

### get/1

Get value from shared state.

```erlang
-spec get(Key :: term()) -> term() | undefined.

Value = hornbeam_state:get(<<"user:123">>).
```

### set/2

Set value in shared state.

```erlang
-spec set(Key :: term(), Value :: term()) -> ok.

hornbeam_state:set(<<"user:123">>, #{name => <<"Alice">>}).
```

### delete/1

Delete key from shared state.

```erlang
-spec delete(Key :: term()) -> ok.

hornbeam_state:delete(<<"user:123">>).
```

### incr/1, incr/2

Atomically increment counter.

```erlang
-spec incr(Key :: term()) -> integer().
-spec incr(Key :: term(), Delta :: integer()) -> integer().

Count = hornbeam_state:incr(<<"views">>).        % +1
Count = hornbeam_state:incr(<<"views">>, 10).    % +10
```

### decr/1, decr/2

Atomically decrement counter.

```erlang
-spec decr(Key :: term()) -> integer().
-spec decr(Key :: term(), Delta :: integer()) -> integer().

Remaining = hornbeam_state:decr(<<"quota">>).
```

### get_multi/1

Get multiple keys at once.

```erlang
-spec get_multi(Keys :: [term()]) -> #{term() => term()}.

Values = hornbeam_state:get_multi([<<"user:1">>, <<"user:2">>]).
%% #{<<"user:1">> => #{...}, <<"user:2">> => undefined}
```

### keys/0, keys/1

Get all keys, optionally filtered by prefix.

```erlang
-spec keys() -> [term()].
-spec keys(Prefix :: binary()) -> [term()].

AllKeys = hornbeam_state:keys().
UserKeys = hornbeam_state:keys(<<"user:">>).
```

## hornbeam_dist

Distributed Erlang RPC module.

### rpc_call/4, rpc_call/5

Call function on remote node.

```erlang
-spec rpc_call(Node, Module, Function, Args) -> term().
-spec rpc_call(Node, Module, Function, Args, Timeout) -> term().

Result = hornbeam_dist:rpc_call('worker@host', ml_model, predict, [Data]).
Result = hornbeam_dist:rpc_call('worker@host', ml_model, predict, [Data], 30000).
```

### rpc_cast/4

Async call to remote node (fire and forget).

```erlang
-spec rpc_cast(Node, Module, Function, Args) -> ok.

hornbeam_dist:rpc_cast('logger@host', logger, log, [info, Message]).
```

### nodes/0

Get list of connected nodes.

```erlang
-spec nodes() -> [atom()].

ConnectedNodes = hornbeam_dist:nodes().
```

### node/0

Get current node name.

```erlang
-spec node() -> atom().

ThisNode = hornbeam_dist:node().
```

## hornbeam_pubsub

Publish/subscribe messaging module.

### publish/2

Publish message to topic.

```erlang
-spec publish(Topic :: term(), Message :: term()) -> integer().

%% Returns number of subscribers notified
Count = hornbeam_pubsub:publish(<<"updates">>, #{type => new_item}).
```

### subscribe/1

Subscribe current process to topic.

```erlang
-spec subscribe(Topic :: term()) -> ok.

hornbeam_pubsub:subscribe(<<"updates">>).
```

### unsubscribe/1

Unsubscribe current process from topic.

```erlang
-spec unsubscribe(Topic :: term()) -> ok.

hornbeam_pubsub:unsubscribe(<<"updates">>).
```

### get_members/1

Get list of subscriber PIDs.

```erlang
-spec get_members(Topic :: term()) -> [pid()].

Subscribers = hornbeam_pubsub:get_members(<<"updates">>).
```

## hornbeam_callbacks

Registered function management.

### register/2

Register a callback function.

```erlang
-spec register(Name :: atom(), Fun :: function()) -> ok.

hornbeam_callbacks:register(validate, fun([Token]) ->
    case auth:check(Token) of
        ok -> {ok, valid};
        error -> {error, invalid}
    end
end).
```

### unregister/1

Remove a callback.

```erlang
-spec unregister(Name :: atom()) -> ok.

hornbeam_callbacks:unregister(validate).
```

### call/2

Call a registered callback.

```erlang
-spec call(Name :: atom(), Args :: list()) -> term().

Result = hornbeam_callbacks:call(validate, [Token]).
```

### list/0

List all registered callbacks.

```erlang
-spec list() -> [atom()].

Callbacks = hornbeam_callbacks:list().
```

## hornbeam_config

Configuration management.

### get/1, get/2

Get configuration value.

```erlang
-spec get(Key :: atom()) -> term() | undefined.
-spec get(Key :: atom(), Default :: term()) -> term().

Workers = hornbeam_config:get(workers, 4).
Bind = hornbeam_config:get(bind).
```

### set/2

Set configuration value.

```erlang
-spec set(Key :: atom(), Value :: term()) -> ok.

hornbeam_config:set(timeout, 60000).
```

### all/0

Get all configuration.

```erlang
-spec all() -> map().

Config = hornbeam_config:all().
```

## hornbeam_lifespan

ASGI lifespan management.

### start/1

Start lifespan for app.

```erlang
-spec start(AppSpec :: string()) -> ok | {error, term()}.

hornbeam_lifespan:start("app:app").
```

### shutdown/0

Trigger lifespan shutdown.

```erlang
-spec shutdown() -> ok.

hornbeam_lifespan:shutdown().
```

### status/0

Get lifespan status.

```erlang
-spec status() -> started | stopped | not_supported.

Status = hornbeam_lifespan:status().
```

## hornbeam_tasks

Async task management.

### spawn/1

Spawn an async task.

```erlang
-spec spawn(Fun :: function()) -> {ok, TaskId :: reference()}.

{ok, TaskId} = hornbeam_tasks:spawn(fun() ->
    expensive_computation()
end).
```

### await/1, await/2

Wait for task completion.

```erlang
-spec await(TaskId :: reference()) -> term().
-spec await(TaskId :: reference(), Timeout :: integer()) -> term().

Result = hornbeam_tasks:await(TaskId).
Result = hornbeam_tasks:await(TaskId, 30000).
```

### cancel/1

Cancel a running task.

```erlang
-spec cancel(TaskId :: reference()) -> ok | {error, not_found}.

hornbeam_tasks:cancel(TaskId).
```

## Next Steps

- [Python API Reference](./python-api) - Python modules
- [Configuration Reference](./configuration) - All options
