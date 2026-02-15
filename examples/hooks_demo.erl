%%% @doc Hooks demo showing reentrant Python↔Erlang callbacks.
%%%
%%% This example demonstrates hornbeam hooks with erlang-python's reentrant
%%% callback support. Python code can call Erlang hooks, which call back
%%% into Python without deadlocking.
%%%
%%% Usage:
%%%   1> hooks_demo:start().
%%%   2> hooks_demo:demo_sync().
%%%   3> hooks_demo:demo_async().
%%%   4> hooks_demo:demo_nested().
%%%   5> hooks_demo:stop().
-module(hooks_demo).

-export([
    start/0,
    stop/0,
    demo_sync/0,
    demo_async/0,
    demo_nested/0,
    demo_all/0
]).

%% Hook handler exports
-export([handle_compute/3, handle_data/3]).

%% @doc Start hornbeam and register hooks.
start() ->
    %% Ensure hornbeam application is started
    {ok, _} = application:ensure_all_started(hornbeam),

    %% Add priv and examples directories to Python path
    PrivDir = filename:join(code:lib_dir(hornbeam), "priv"),
    py:exec(io_lib:format("import sys; sys.path.insert(0, '~s')", [PrivDir])),
    py:exec(<<"import sys; sys.path.insert(0, 'examples')">>),

    %% Register hornbeam callback functions (normally done by hornbeam:start/2)
    register_hornbeam_callbacks(),

    %% Register Erlang hook handlers
    %% These can call back into Python via py:call()
    hornbeam_hooks:reg(<<"compute">>, ?MODULE, handle_compute, 3),
    hornbeam_hooks:reg(<<"data">>, ?MODULE, handle_data, 3),

    %% Register callback functions for Python to call
    py:register_function(hooks_demo_multiply, fun([X, Y]) ->
        X * Y
    end),
    py:register_function(hooks_demo_get_config, fun([Key]) ->
        %% Call Python to get config - demonstrates reentrant callback
        {ok, Result} = py:call(hooks_demo_py, get_config, [Key]),
        Result
    end),

    io:format("Hooks demo started. Try:~n"),
    io:format("  hooks_demo:demo_sync().~n"),
    io:format("  hooks_demo:demo_async().~n"),
    io:format("  hooks_demo:demo_nested().~n"),
    io:format("  hooks_demo:demo_all().~n"),
    ok.

%% @doc Stop the demo.
stop() ->
    hornbeam_hooks:unreg(<<"compute">>),
    hornbeam_hooks:unreg(<<"data">>),
    ok.

%% @doc Demonstrate synchronous hook execution.
%%
%% Flow: Erlang -> Python (execute) -> Erlang (hook) -> Python (py:call)
demo_sync() ->
    io:format("~n=== Synchronous Hook Demo ===~n"),
    io:format("Testing Python → Erlang → Python callback chain~n~n"),

    %% Call Python which uses hooks to call back to Erlang
    {ok, Result} = py:call(hooks_demo_py, test_sync_hooks, []),

    io:format("Results: ~p~n", [Result]),

    %% Verify results
    #{<<"sum_result">> := SumResult,
      <<"product_result">> := ProductResult} = Result,

    io:format("Sum result: ~p (expected: 15)~n", [SumResult]),
    io:format("Product result: ~p (expected: 24)~n", [ProductResult]),

    Success = (SumResult == 15) andalso (ProductResult == 24),
    io:format("Test ~s~n", [if Success -> "PASSED"; true -> "FAILED" end]),
    Result.

%% @doc Demonstrate async hook execution with asyncio.
%%
%% Shows how to use hooks with Python's asyncio for concurrent operations.
demo_async() ->
    io:format("~n=== Async Hook Demo ===~n"),
    io:format("Testing hooks with Python asyncio~n~n"),

    %% Call Python's async test function
    {ok, Result} = py:call(hooks_demo_py, test_async_hooks, []),

    io:format("Results: ~p~n", [Result]),

    #{<<"concurrent_results">> := ConcurrentResults,
      <<"sequential_time">> := SeqTime,
      <<"concurrent_time">> := ConcTime} = Result,

    io:format("Concurrent results: ~p~n", [ConcurrentResults]),
    io:format("Sequential time: ~.3f ms~n", [SeqTime]),
    io:format("Concurrent time: ~.3f ms~n", [ConcTime]),

    %% Concurrent should be faster (but we won't enforce this in test)
    io:format("Speedup: ~.2fx~n", [SeqTime / max(ConcTime, 0.001)]),
    io:format("Test PASSED~n"),
    Result.

%% @doc Demonstrate deeply nested callbacks.
%%
%% Shows Python → Erlang → Python → Erlang → Python chain working correctly.
demo_nested() ->
    io:format("~n=== Nested Callbacks Demo ===~n"),
    io:format("Testing deep Python ↔ Erlang nesting~n~n"),

    %% Call Python with nested hooks
    {ok, Result} = py:call(hooks_demo_py, test_nested, [5]),

    io:format("Nested result: ~p (expected: 5)~n", [Result]),

    Success = Result == 5,
    io:format("Test ~s~n", [if Success -> "PASSED"; true -> "FAILED" end]),
    Result.

%% @doc Run all demos.
demo_all() ->
    io:format("~n========================================~n"),
    io:format("   HOOKS DEMO - REENTRANT CALLBACKS~n"),
    io:format("========================================~n"),

    demo_sync(),
    demo_async(),
    demo_nested(),

    io:format("~n========================================~n"),
    io:format("   ALL DEMOS COMPLETE~n"),
    io:format("========================================~n"),
    ok.

%%% ============================================================================
%%% Hook Handlers
%%% ============================================================================

%% @doc Handle compute actions.
%% This handler can call back into Python to demonstrate reentrant callbacks.
handle_compute(<<"sum">>, Args, _Kwargs) ->
    %% Simple computation - no callback needed
    lists:sum(Args);

handle_compute(<<"product">>, [List], _Kwargs) when is_list(List) ->
    %% Call Python for the actual computation (reentrant callback)
    {ok, Result} = py:call(hooks_demo_py, compute_product, [List]),
    Result;

handle_compute(<<"with_config">>, [Value], _Kwargs) ->
    %% Get config from Python, then compute
    %% This creates: Python -> Erlang -> Python -> Erlang (get_config) -> Python
    {ok, Multiplier} = py:call(hooks_demo_py, get_config, [<<"multiplier">>]),
    Value * Multiplier;

handle_compute(Action, Args, _Kwargs) ->
    error({unknown_compute_action, Action, Args}).

%% @doc Handle data actions with simulated work.
handle_data(<<"process">>, [Data], #{<<"delay">> := Delay}) ->
    %% Simulate work with delay
    timer:sleep(Delay),
    %% Process data in Python
    {ok, Result} = py:call(hooks_demo_py, process_data, [Data]),
    Result;

handle_data(<<"process">>, [Data], _Kwargs) ->
    %% No delay version
    {ok, Result} = py:call(hooks_demo_py, process_data, [Data]),
    Result;

handle_data(<<"nested_step">>, [N, Depth], _Kwargs) ->
    %% Call Python to continue the nesting chain
    {ok, Result} = py:call(hooks_demo_py, nested_continue, [N + 1, Depth - 1]),
    Result;

handle_data(Action, Args, _Kwargs) ->
    error({unknown_data_action, Action, Args}).

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

%% Register hornbeam callbacks that Python uses via erlang.call()
register_hornbeam_callbacks() ->
    %% Hook execution
    py:register_function(hornbeam_hooks_execute, fun([AppPath, Action, Args, Kwargs]) ->
        hornbeam_hooks:execute(AppPath, Action, Args, Kwargs)
    end),
    py:register_function(hornbeam_hooks_execute_async, fun([AppPath, Action, Args, Kwargs]) ->
        hornbeam_hooks:execute_async(AppPath, Action, Args, Kwargs)
    end),
    py:register_function(hornbeam_hooks_await_result, fun([TaskRef, TimeoutMs]) ->
        hornbeam_hooks:await_result(TaskRef, TimeoutMs)
    end),
    %% State functions
    py:register_function(hornbeam_state_get, fun([Key]) ->
        hornbeam_state:get(Key)
    end),
    py:register_function(hornbeam_state_set, fun([Key, Value]) ->
        hornbeam_state:set(Key, Value)
    end),
    py:register_function(hornbeam_state_delete, fun([Key]) ->
        hornbeam_state:delete(Key)
    end),
    py:register_function(hornbeam_state_incr, fun([Key, Delta]) ->
        hornbeam_state:incr(Key, Delta)
    end),
    py:register_function(hornbeam_state_decr, fun([Key, Delta]) ->
        hornbeam_state:decr(Key, Delta)
    end),
    ok.
