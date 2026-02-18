---
title: Streaming
description: Working with Python generators from Erlang, including generator expressions, iterator objects, and custom streaming consumers.
order: 5
---

This guide covers working with Python generators from Erlang.

## Overview

Python generators allow processing large datasets or infinite sequences
efficiently by yielding values one at a time. erlang_python supports
streaming these values back to Erlang.

## Generator Expressions

The simplest way to stream is with generator expressions:

```erlang
%% Stream squares of numbers 0-9
{ok, Squares} = py:stream_eval(<<"(x**2 for x in range(10))">>).
%% Squares = [0,1,4,9,16,25,36,49,64,81]

%% Stream uppercase characters
{ok, Upper} = py:stream_eval(<<"(c.upper() for c in 'hello')">>).
%% Upper = [<<"H">>,<<"E">>,<<"L">>,<<"L">>,<<"O">>]

%% Stream filtered values
{ok, Evens} = py:stream_eval(<<"(x for x in range(20) if x % 2 == 0)">>).
%% Evens = [0,2,4,6,8,10,12,14,16,18]
```

## Iterator Objects

Any Python iterator can be streamed:

```erlang
%% Stream from range
{ok, Numbers} = py:stream_eval(<<"iter(range(5))">>).
%% Numbers = [0,1,2,3,4]

%% Stream dictionary items
{ok, Items} = py:stream_eval(<<"iter({'a': 1, 'b': 2}.items())">>).
%% Items = [{<<"a">>, 1}, {<<"b">>, 2}]
```

## Generator Functions

Define generator functions with `yield`:

```erlang
%% Define a generator function
ok = py:exec(<<"
def fibonacci(n):
    a, b = 0, 1
    for _ in range(n):
        yield a
        a, b = b, a + b
">>).

%% Stream from it
%% Note: Functions defined with exec are local to the worker that executes them.
%% Subsequent calls may go to different workers in the pool.
{ok, Fib} = py:stream('__main__', fibonacci, [10]).
%% Fib = [0,1,1,2,3,5,8,13,21,34]
```

For reliable inline generators, use lambda with walrus operator (Python 3.8+):

```erlang
%% Fibonacci using inline lambda - works reliably across workers
{ok, Fib} = py:stream_eval(<<"(lambda: ((fib := [0, 1]), [fib.append(fib[-1] + fib[-2]) for _ in range(8)], iter(fib))[-1])()">>).
%% Fib = [0,1,1,2,3,5,8,13,21,34]
```

## Streaming Protocol

Internally, streaming uses these messages:

```erlang
{py_chunk, Ref, Value}   %% Each yielded value
{py_end, Ref}            %% Generator exhausted
{py_error, Ref, Error}   %% Exception occurred
```

You can build custom streaming consumers:

```erlang
start_stream(Code) ->
    Ref = make_ref(),
    py_pool:request({stream_eval, Ref, self(), Code, #{}}),
    process_stream(Ref).

process_stream(Ref) ->
    receive
        {py_chunk, Ref, Value} ->
            io:format("Got: ~p~n", [Value]),
            process_stream(Ref);
        {py_end, Ref} ->
            io:format("Done~n");
        {py_error, Ref, Error} ->
            io:format("Error: ~p~n", [Error])
    after 30000 ->
        io:format("Timeout~n")
    end.
```

## Memory Considerations

- Values are collected into a list by `stream_eval/1,2`
- For large datasets, consider processing chunks as they arrive
- Generators are garbage collected after exhaustion

## Use Cases

### Data Processing Pipelines

```erlang
%% Process file lines (if defined in Python)
{ok, Lines} = py:stream(mymodule, read_lines, [<<"data.txt">>]).

%% Transform each line
Results = [process_line(L) || L <- Lines].
```

### Infinite Sequences

```erlang
%% Define infinite counter
ok = py:exec(<<"
def counter():
    n = 0
    while True:
        yield n
        n += 1
">>).

%% Take first 100 (use your own take function)
%% Can't use stream/3 directly for infinite - need custom handling
```

### Batch Processing

```erlang
%% Process in batches
ok = py:exec(<<"
def batches(data, size):
    for i in range(0, len(data), size):
        yield data[i:i+size]
">>).
```
