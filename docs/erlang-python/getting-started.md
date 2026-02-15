---
title: Getting Started
description: A walkthrough guide for using erlang_python to execute Python code from Erlang, covering installation, basic usage, and core features.
order: 1
---

# Getting Started

This guide walks you through using erlang_python to execute Python code from Erlang.

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {erlang_python, {git, "https://github.com/benoitc/erlang-python.git", {tag, "v1.2.0"}}}
]}.
```

## Starting the Application

```erlang
1> application:ensure_all_started(erlang_python).
{ok, [erlang_python]}
```

The application starts a pool of Python worker processes that handle requests.

## Basic Usage

### Calling Python Functions

```erlang
%% Call math.sqrt(16)
{ok, 4.0} = py:call(math, sqrt, [16]).

%% Call json.dumps with keyword arguments
{ok, Json} = py:call(json, dumps, [#{name => <<"Alice">>}], #{indent => 2}).
```

### Evaluating Expressions

```erlang
%% Simple arithmetic
{ok, 42} = py:eval(<<"21 * 2">>).

%% Using Python built-ins
{ok, 45} = py:eval(<<"sum(range(10))">>).

%% With local variables
{ok, 100} = py:eval(<<"x * y">>, #{x => 10, y => 10}).

%% Note: Python locals aren't accessible in nested scopes (lambda/comprehensions).
%% Use default arguments to capture values:
{ok, [2, 4, 6]} = py:eval(<<"list(map(lambda x, m=multiplier: x * m, items))">>,
                          #{items => [1, 2, 3], multiplier => 2}).
```

### Executing Statements

Use `py:exec/1` to execute Python statements:

```erlang
ok = py:exec(<<"
import random

def roll_dice(sides=6):
    return random.randint(1, sides)
">>).
```

Note: Definitions made with `exec` are local to the worker that executes them.
Subsequent calls may go to different workers. Use [Shared State](#shared-state) to
share data between workers, or [Context Affinity](#context-affinity) to bind to a
dedicated worker.

## Working with Timeouts

All operations support optional timeouts:

```erlang
%% 5 second timeout
{ok, Result} = py:call(mymodule, slow_func, [], #{}, 5000).

%% Timeout error
{error, timeout} = py:eval(<<"sum(range(10**9))">>, #{}, 100).
```

## Async Calls

For non-blocking operations:

```erlang
%% Start async call
Ref = py:call_async(math, factorial, [1000]).

%% Do other work...

%% Wait for result
{ok, HugeNumber} = py:await(Ref).
```

## Streaming from Generators

Python generators can be streamed efficiently:

```erlang
%% Stream a generator expression
{ok, [0,1,4,9,16]} = py:stream_eval(<<"(x**2 for x in range(5))">>).

%% Stream from a generator function (if defined)
{ok, Chunks} = py:stream(mymodule, generate_data, [arg1, arg2]).
```

## Shared State

Python workers don't share namespace state, but you can share data via the
built-in state API:

```erlang
%% Store from Erlang
py:state_store(<<"config">>, #{api_key => <<"secret">>, timeout => 5000}).

%% Read from Python
ok = py:exec(<<"
from erlang import state_get
config = state_get('config')
print(config['api_key'])
">>).
```

### From Python

```python
from erlang import state_set, state_get, state_delete, state_keys
from erlang import state_incr, state_decr

# Key-value storage
state_set('my_key', {'data': [1, 2, 3]})
value = state_get('my_key')

# Atomic counters (thread-safe)
state_incr('requests')       # +1, returns new value
state_incr('requests', 10)   # +10
state_decr('requests')       # -1

# Management
keys = state_keys()
state_delete('my_key')
```

### From Erlang

```erlang
py:state_store(Key, Value).
{ok, Value} = py:state_fetch(Key).
py:state_remove(Key).
Keys = py:state_keys().

%% Atomic counters
1 = py:state_incr(<<"hits">>).
11 = py:state_incr(<<"hits">>, 10).
10 = py:state_decr(<<"hits">>).
```

## Type Conversions

Values are automatically converted between Erlang and Python:

```erlang
%% Numbers
{ok, 42} = py:eval(<<"42">>).           %% int -> integer
{ok, 3.14} = py:eval(<<"3.14">>).       %% float -> float

%% Strings
{ok, <<"hello">>} = py:eval(<<"'hello'">>).  %% str -> binary

%% Collections
{ok, [1,2,3]} = py:eval(<<"[1,2,3]">>).      %% list -> list
{ok, {1,2,3}} = py:eval(<<"(1,2,3)">>).      %% tuple -> tuple
{ok, #{<<"a">> := 1}} = py:eval(<<"{'a': 1}">>).  %% dict -> map

%% Booleans and None
{ok, true} = py:eval(<<"True">>).
{ok, false} = py:eval(<<"False">>).
{ok, none} = py:eval(<<"None">>).
```

## Context Affinity

By default, each call may go to a different worker. To preserve Python state across
calls (variables, imports, objects), bind to a dedicated worker:

```erlang
%% Bind current process to a worker
ok = py:bind(),

%% State persists across calls
ok = py:exec(<<"counter = 0">>),
ok = py:exec(<<"counter += 1">>),
{ok, 1} = py:eval(<<"counter">>),

%% Release the worker
ok = py:unbind().
```

Or use the scoped helper for automatic cleanup:

```erlang
Result = py:with_context(fun() ->
    ok = py:exec(<<"x = 10">>),
    py:eval(<<"x * 2">>)
end),
{ok, 20} = Result.
```

See [Context Affinity](context-affinity.md) for explicit contexts and advanced usage.

## Execution Mode and Scalability

Check the current execution mode:

```erlang
%% See how Python is being executed
py:execution_mode().
%% => free_threaded | subinterp | multi_executor

%% Check rate limiting status
py_semaphore:max_concurrent().  %% Maximum concurrent calls
py_semaphore:current().         %% Currently executing
```

See [Scalability](scalability.md) for details on execution modes and performance tuning.

## Using from Elixir

erlang_python works seamlessly with Elixir. The `:py` module can be called directly:

```elixir
# Start the application
{:ok, _} = Application.ensure_all_started(:erlang_python)

# Call Python functions
{:ok, 4.0} = :py.call(:math, :sqrt, [16])

# Evaluate expressions
{:ok, result} = :py.eval("2 + 2")

# With variables
{:ok, 100} = :py.eval("x * y", %{x: 10, y: 10})

# Call with keyword arguments
{:ok, json} = :py.call(:json, :dumps, [%{name: "Elixir"}], %{indent: 2})
```

### Register Elixir Functions for Python

```elixir
# Register an Elixir function
:py.register_function(:factorial, fn [n] ->
  Enum.reduce(1..n, 1, &*/2)
end)

# Call from Python
{:ok, 3628800} = :py.eval("__import__('erlang').call('factorial', 10)")

# Cleanup
:py.unregister_function(:factorial)
```

### Parallel Processing with BEAM

```elixir
# Register parallel map using BEAM processes
:py.register_function(:parallel_map, fn [func_name, items] ->
  parent = self()

  refs = Enum.map(items, fn item ->
    ref = make_ref()
    spawn(fn ->
      result = apply_function(func_name, item)
      send(parent, {ref, result})
    end)
    ref
  end)

  Enum.map(refs, fn ref ->
    receive do
      {^ref, result} -> result
    after
      5000 -> {:error, :timeout}
    end
  end)
end)
```

### Running the Elixir Example

A complete working example is available:

```bash
elixir --erl "-pa _build/default/lib/erlang_python/ebin" examples/elixir_example.exs
```

This demonstrates basic calls, data conversion, callbacks, parallel processing (10x speedup), and AI integration.

## Next Steps

- See [Type Conversion](type-conversion.md) for detailed type mapping
- See [Context Affinity](context-affinity.md) for preserving Python state
- See [Streaming](streaming.md) for working with generators
- See [Memory Management](memory.md) for GC and debugging
- See [Scalability](scalability.md) for parallelism and performance
- See [AI Integration](ai-integration.md) for ML/AI examples
