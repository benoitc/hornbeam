---
title: Context Affinity
description: How to bind Erlang processes to dedicated Python workers to preserve state across multiple calls, including explicit contexts and automatic cleanup.
order: 4
---

Context affinity allows you to bind an Erlang process to a dedicated Python worker, preserving Python state (variables, imports, objects) across multiple `py:call/eval/exec` invocations.

## Why Context Affinity?

By default, each call to `py:call`, `py:eval`, or `py:exec` may be handled by a different worker from the pool. This means:

- Variables defined in one call are not available in the next
- Imported modules must be re-imported
- Objects created in one call cannot be accessed later

Context affinity solves this by dedicating a worker to your process, ensuring all calls go to the same Python interpreter with preserved state.

## Process-Implicit Binding

The simplest approach binds the current Erlang process to a worker:

```erlang
%% Bind current process to a dedicated worker
ok = py:bind(),

%% Now all calls use the same worker - state persists!
ok = py:exec(<<"counter = 0">>),
ok = py:exec(<<"counter += 1">>),
{ok, 1} = py:eval(<<"counter">>),

ok = py:exec(<<"counter += 1">>),
{ok, 2} = py:eval(<<"counter">>),

%% Release the worker back to the pool
ok = py:unbind().
```

### Checking Binding Status

```erlang
false = py:is_bound(),
ok = py:bind(),
true = py:is_bound(),
ok = py:unbind(),
false = py:is_bound().
```

## Explicit Contexts

For more control, create explicit context handles. This allows multiple independent Python contexts within a single Erlang process:

```erlang
%% Create two independent contexts
{ok, Ctx1} = py:bind(new),
{ok, Ctx2} = py:bind(new),

%% Each context has its own namespace
ok = py:ctx_exec(Ctx1, <<"x = 'context one'">>),
ok = py:ctx_exec(Ctx2, <<"x = 'context two'">>),

%% Values are isolated
{ok, <<"context one">>} = py:ctx_eval(Ctx1, <<"x">>),
{ok, <<"context two">>} = py:ctx_eval(Ctx2, <<"x">>),

%% Release both
ok = py:unbind(Ctx1),
ok = py:unbind(Ctx2).
```

### Context-Aware Functions

When using explicit contexts, use these functions:

| Function | Description |
|----------|-------------|
| `py:ctx_call(Ctx, Module, Func, Args)` | Call with context |
| `py:ctx_call(Ctx, Module, Func, Args, Kwargs)` | Call with kwargs |
| `py:ctx_call(Ctx, Module, Func, Args, Kwargs, Timeout)` | Call with timeout |
| `py:ctx_eval(Ctx, Code)` | Evaluate expression |
| `py:ctx_eval(Ctx, Code, Locals)` | Evaluate with locals |
| `py:ctx_eval(Ctx, Code, Locals, Timeout)` | Evaluate with timeout |
| `py:ctx_exec(Ctx, Code)` | Execute statements |

## Scoped Helper

The `with_context/1` function provides automatic bind/unbind with cleanup on exception:

### Implicit Binding (arity-0 function)

```erlang
Result = py:with_context(fun() ->
    ok = py:exec(<<"total = 0">>),
    ok = py:exec(<<"for i in range(10): total += i">>),
    py:eval(<<"total">>)
end),
{ok, 45} = Result.
%% Process is automatically unbound here
```

### Explicit Context (arity-1 function)

```erlang
Result = py:with_context(fun(Ctx) ->
    ok = py:ctx_exec(Ctx, <<"import json">>),
    ok = py:ctx_exec(Ctx, <<"data = {'key': 'value'}">>),
    py:ctx_eval(Ctx, <<"json.dumps(data)">>)
end),
{ok, <<"{\"key\": \"value\"}">>} = Result.
```

## Automatic Cleanup

### Process Death

If a bound process dies, the worker is automatically returned to the pool:

```erlang
Pid = spawn(fun() ->
    ok = py:bind(),
    %% Do some work...
    exit(normal)  %% Worker automatically returned
end).
```

### Worker Crash

If a bound worker crashes, the binding is cleaned up and a new worker is created:

```erlang
ok = py:bind(),
%% If the worker crashes, binding is cleaned up
%% Next bind() will get a fresh worker
```

## Use Cases

### Stateful Computation

```erlang
py:with_context(fun() ->
    %% Load a model once
    py:exec(<<"
import pickle
with open('model.pkl', 'rb') as f:
    model = pickle.load(f)
">>),

    %% Use it multiple times
    {ok, Pred1} = py:eval(<<"model.predict([[1, 2, 3]])">>),
    {ok, Pred2} = py:eval(<<"model.predict([[4, 5, 6]])">>),
    {Pred1, Pred2}
end).
```

### Database Connections

```erlang
ok = py:bind(),

%% Establish connection once
py:exec(<<"
import sqlite3
conn = sqlite3.connect(':memory:')
cursor = conn.cursor()
cursor.execute('CREATE TABLE users (id INTEGER, name TEXT)')
">>),

%% Use the connection across multiple calls
py:exec(<<"cursor.execute('INSERT INTO users VALUES (1, \"Alice\")')">>),
py:exec(<<"cursor.execute('INSERT INTO users VALUES (2, \"Bob\")')">>),
{ok, Users} = py:eval(<<"cursor.execute('SELECT * FROM users').fetchall()">>),

%% Clean up
py:exec(<<"conn.close()">>),
py:unbind().
```

### Incremental Processing

```erlang
{ok, Ctx} = py:bind(new),

%% Initialize accumulator
py:ctx_exec(Ctx, <<"results = []">>),

%% Process items one at a time
lists:foreach(fun(Item) ->
    py:ctx_exec(Ctx, <<"results.append(process_item(item))">>,
                #{item => Item})
end, Items),

%% Get final results
{ok, Results} = py:ctx_eval(Ctx, <<"results">>),

py:unbind(Ctx).
```

## Performance Considerations

- **Binding overhead**: `bind()` requires a gen_server call to checkout a worker
- **Lookup overhead**: Once bound, routing adds only an O(1) ETS lookup
- **Pool exhaustion**: Each bound context removes a worker from the pool
- **Recommendation**: Use `with_context/1` for short-lived operations; explicit `bind/unbind` for long-lived sessions

## Pool Statistics

Check how many workers are bound:

```erlang
Stats = py_pool:get_stats(),
#{
    num_workers := 8,
    available_workers := 6,  %% 2 workers are checked out
    checked_out := 2,
    pending_requests := 0
} = Stats.
```

## Error Handling

### No Workers Available

```erlang
%% If all workers are bound
{error, no_workers_available} = py:bind().
```

### Context Not Bound

```erlang
%% Using a context after unbind raises an error
{ok, Ctx} = py:bind(new),
ok = py:unbind(Ctx),
%% This will crash with context_not_bound
py:ctx_eval(Ctx, <<"1 + 1">>).  %% error(context_not_bound)
```

## Best Practices

1. **Always unbind**: Use `with_context/1` or ensure `unbind` in a `try/after` block
2. **Minimize binding time**: Don't hold workers longer than necessary
3. **Watch pool size**: Monitor `py_pool:get_stats()` to avoid exhaustion
4. **Use explicit contexts**: When you need multiple independent namespaces
5. **Prefer implicit binding**: For simple sequential operations in a single process
