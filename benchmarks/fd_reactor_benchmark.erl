%% Copyright 2026 Benoit Chesneau
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%%% @doc Benchmark runner for comparing NIF vs FD Reactor modes.
%%%
%%% This module runs benchmarks comparing the two backend modes:
%%% - nif: Traditional NIF-based WSGI/ASGI marshalling
%%% - fd_reactor: New socketpair-based FD reactor model
%%%
%%% Usage:
%%%   cd benchmarks
%%%   erl -pa ../_build/default/lib/*/ebin -s fd_reactor_benchmark run_all -s init stop
%%%
%%% Or from rebar3 shell:
%%%   fd_reactor_benchmark:run_all().
-module(fd_reactor_benchmark).

-export([
    run_all/0,
    run/1,
    run_scenario/2
]).

-define(PORT, 18888).
-define(HOST, "127.0.0.1").
-define(DURATION, 10).  %% seconds
-define(CONCURRENCY_LEVELS, [1, 10, 50, 100]).

%% Scenarios to benchmark
-define(SCENARIOS, [
    {simple_get, "Simple GET (no body)", "simple_get.py"},
    {post_1kb, "POST 1KB body", "post_body.py"},
    {post_64kb, "POST 64KB body", "post_body.py"},
    {response_1kb, "Response 1KB", "response_body.py"},
    {file_response, "File response (sendfile)", "file_response.py"}
]).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Run all benchmark scenarios.
run_all() ->
    io:format("~n=== Hornbeam FD Reactor Benchmark ===~n~n"),
    io:format("Comparing NIF vs FD Reactor backend modes~n"),
    io:format("Duration: ~p seconds per test~n", [?DURATION]),
    io:format("Concurrency levels: ~p~n~n", [?CONCURRENCY_LEVELS]),

    Results = lists:map(fun({Scenario, Desc, _App}) ->
        io:format("~n--- ~s ---~n", [Desc]),
        NifResult = run_scenario(Scenario, nif),
        FdResult = run_scenario(Scenario, fd_reactor),
        compare_results(Desc, NifResult, FdResult)
    end, ?SCENARIOS),

    print_summary(Results),
    ok.

%% @doc Run a single scenario.
run(Scenario) ->
    io:format("Running scenario: ~p~n", [Scenario]),
    NifResult = run_scenario(Scenario, nif),
    FdResult = run_scenario(Scenario, fd_reactor),
    compare_results(atom_to_list(Scenario), NifResult, FdResult).

%% @doc Run a scenario with specific backend mode.
run_scenario(Scenario, Mode) ->
    io:format("  Mode: ~p~n", [Mode]),

    %% Get scenario app
    App = get_scenario_app(Scenario),

    %% Start hornbeam
    {ok, _} = hornbeam:start(App, #{
        bind => ?HOST ++ ":" ++ integer_to_list(?PORT),
        backend_mode => Mode,
        workers => 4,
        timeout => 30000
    }),

    %% Wait for server to be ready
    timer:sleep(500),

    %% Run benchmarks at each concurrency level
    Results = lists:map(fun(Concurrency) ->
        Url = build_url(Scenario),
        Result = run_wrk(Url, Concurrency, ?DURATION, Scenario),
        {Concurrency, Result}
    end, ?CONCURRENCY_LEVELS),

    %% Stop hornbeam
    hornbeam:stop(),
    timer:sleep(200),

    Results.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

get_scenario_app(simple_get) -> "scenarios.simple_get:app";
get_scenario_app(post_1kb) -> "scenarios.post_body:app";
get_scenario_app(post_64kb) -> "scenarios.post_body:app";
get_scenario_app(response_1kb) -> "scenarios.response_body:app";
get_scenario_app(file_response) -> "scenarios.file_response:app";
get_scenario_app(_) -> "scenarios.simple_get:app".

build_url(simple_get) ->
    "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/";
build_url(post_1kb) ->
    "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/echo";
build_url(post_64kb) ->
    "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/echo";
build_url(response_1kb) ->
    "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/1kb";
build_url(file_response) ->
    "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/file";
build_url(_) ->
    "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/".

run_wrk(Url, Concurrency, Duration, Scenario) ->
    %% Build wrk command
    Method = case Scenario of
        post_1kb -> " -s post_1kb.lua";
        post_64kb -> " -s post_64kb.lua";
        _ -> ""
    end,

    Cmd = io_lib:format(
        "wrk -t2 -c~p -d~ps~s ~s 2>&1",
        [Concurrency, Duration, Method, Url]
    ),

    %% Run wrk
    Output = os:cmd(lists:flatten(Cmd)),

    %% Parse output
    parse_wrk_output(Output).

parse_wrk_output(Output) ->
    %% Extract requests/sec
    ReqsPerSec = case re:run(Output, "Requests/sec:\\s+([0-9.]+)", [{capture, [1], list}]) of
        {match, [Reqs]} -> list_to_float(Reqs);
        nomatch -> 0.0
    end,

    %% Extract latency avg
    LatencyAvg = case re:run(Output, "Latency\\s+([0-9.]+)(ms|us|s)", [{capture, [1, 2], list}]) of
        {match, [Lat, Unit]} ->
            LatVal = list_to_float(Lat),
            case Unit of
                "us" -> LatVal / 1000;
                "s" -> LatVal * 1000;
                _ -> LatVal
            end;
        nomatch -> 0.0
    end,

    %% Extract errors
    Errors = case re:run(Output, "Non-2xx or 3xx responses:\\s+([0-9]+)", [{capture, [1], list}]) of
        {match, [E]} -> list_to_integer(E);
        nomatch -> 0
    end,

    #{
        requests_per_second => ReqsPerSec,
        latency_avg_ms => LatencyAvg,
        errors => Errors
    }.

compare_results(Desc, NifResults, FdResults) ->
    io:format("~n  | Concurrency | NIF req/s | FD req/s | Diff |~n"),
    io:format("  |-------------|-----------|----------|------|~n"),

    Comparisons = lists:zipwith(fun({C, NifR}, {C, FdR}) ->
        NifReqs = maps:get(requests_per_second, NifR, 0),
        FdReqs = maps:get(requests_per_second, FdR, 0),
        Diff = case NifReqs of
            0 -> 0;
            _ -> ((FdReqs - NifReqs) / NifReqs) * 100
        end,
        io:format("  | ~11p | ~9.0f | ~8.0f | ~+.0f% |~n",
                  [C, NifReqs, FdReqs, Diff]),
        {C, NifReqs, FdReqs, Diff}
    end, NifResults, FdResults),

    {Desc, Comparisons}.

print_summary(Results) ->
    io:format("~n~n=== Summary ===~n~n"),
    io:format("| Scenario | Avg Improvement |~n"),
    io:format("|----------|-----------------|~n"),

    lists:foreach(fun({Desc, Comparisons}) ->
        Diffs = [D || {_, _, _, D} <- Comparisons],
        AvgDiff = case length(Diffs) of
            0 -> 0;
            N -> lists:sum(Diffs) / N
        end,
        io:format("| ~-30s | ~+.1f% |~n", [Desc, AvgDiff])
    end, Results),

    io:format("~n").
