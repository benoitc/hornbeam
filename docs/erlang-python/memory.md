---
title: Memory Management
description: Python memory monitoring and garbage collection from Erlang, including statistics, manual collection, tracing, and troubleshooting memory issues.
order: 6
---

# Memory Management

This guide covers Python memory monitoring and garbage collection from Erlang.

## Memory Statistics

Get current Python memory statistics:

```erlang
{ok, Stats} = py:memory_stats().
```

The returned map contains:

- `gc_stats` - List of per-generation statistics (collected, collections, uncollectable)
- `gc_count` - Tuple of object counts per generation `{gen0, gen1, gen2}`
- `gc_threshold` - Collection thresholds per generation

Example output:

```erlang
#{gc_stats =>
    [#{<<"collected">> => 0, <<"collections">> => 0, <<"uncollectable">> => 0},
     #{<<"collected">> => 0, <<"collections">> => 0, <<"uncollectable">> => 0},
     #{<<"collected">> => 145, <<"collections">> => 1, <<"uncollectable">> => 0}],
  gc_count => {1837, 0, 0},
  gc_threshold => {2000, 10, 0}}
```

## Garbage Collection

### Manual Collection

Force Python garbage collection:

```erlang
%% Full collection (all generations)
{ok, Collected} = py:gc().

%% Collection by generation
{ok, _} = py:gc(0).   %% Youngest objects only
{ok, _} = py:gc(1).   %% Generations 0 and 1
{ok, _} = py:gc(2).   %% Full collection
```

### When to Force GC

- After processing large datasets
- Before measuring memory usage
- When memory pressure is detected

## Memory Tracing

For detailed memory debugging, use tracemalloc:

```erlang
%% Start tracing
ok = py:tracemalloc_start().

%% Do some work
{ok, _} = py:eval(<<"[x**2 for x in range(100000)]">>).

%% Check memory
{ok, Stats} = py:memory_stats().
%% Stats now includes:
%%   traced_memory_current => 1234567,  %% Current bytes
%%   traced_memory_peak => 2345678      %% Peak bytes

%% Stop tracing
ok = py:tracemalloc_stop().
```

### Frame Depth

For more detailed tracebacks, specify frame depth:

```erlang
ok = py:tracemalloc_start(10).  %% Store 10 frames per allocation
```

Higher frame counts provide more detail but use more memory.

## Memory Best Practices

### 1. Use Streaming for Large Data

Instead of loading everything into memory:

```erlang
%% Bad - loads entire list
{ok, Huge} = py:eval(<<"list(range(10000000))">>).

%% Good - processes incrementally
{ok, Chunks} = py:stream_eval(<<"(x for x in range(10000000))">>).
```

### 2. Clear Large Objects

Python objects are cleaned up when their references are released.
Force cleanup with explicit GC:

```erlang
process_large_data(Data) ->
    Result = py:call(processor, handle, [Data]),
    {ok, _} = py:gc(),  %% Clean up Python side
    Result.
```

### 3. Monitor Pool Memory

Track memory across workers:

```erlang
monitor_memory() ->
    {ok, Stats} = py:memory_stats(),
    Count = element(1, maps:get(gc_count, Stats)),
    Threshold = element(1, maps:get(gc_threshold, Stats)),
    if Count > Threshold * 0.8 ->
        logger:warning("Python memory pressure: ~p/~p", [Count, Threshold]),
        py:gc();
       true ->
        ok
    end.
```

## Understanding GC Stats

### Generations

Python uses generational garbage collection:

- **Generation 0**: Newly created objects. Collected frequently.
- **Generation 1**: Objects that survived one collection. Collected less often.
- **Generation 2**: Long-lived objects. Collected rarely.

### Thresholds

Default thresholds are `{700, 10, 10}`:

- Gen 0 collects after 700 new allocations
- Gen 1 collects after 10 Gen 0 collections
- Gen 2 collects after 10 Gen 1 collections

### Uncollectable Objects

Objects with circular references and `__del__` methods may be uncollectable.
Monitor the `uncollectable` count in gc_stats.

## Troubleshooting

### High Memory Usage

1. Enable tracemalloc to identify allocations
2. Check for large objects not being released
3. Force GC and re-measure
4. Consider streaming large datasets

### Memory Leaks

1. Check `uncollectable` count in gc_stats
2. Look for circular references in Python code
3. Ensure generators are fully consumed or explicitly closed

### Worker Memory Growth

Each worker maintains its own namespace. Objects defined via `exec` persist:

```erlang
%% This grows worker memory over time
[py:exec(<<"x", N, " = [0] * 1000000">>) || N <- lists:seq(1, 100)].

%% Consider using eval with locals instead
[py:eval(<<"len(data)">>, #{data => LargeList}) || _ <- lists:seq(1, 100)].
```
