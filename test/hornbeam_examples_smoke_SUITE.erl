%% Copyright 2026 Benoit Chesneau
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0

%%% @doc Smoke tests for example apps under examples/.
%%%
%%% Each test starts the example via hornbeam:start/2, hits one HTTP endpoint,
%%% and asserts a 200 response. Heavy ML/LLM examples and rebar-release demos
%%% are out of scope and live in separate flows.
-module(hornbeam_examples_smoke_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    test_async_chat/1,
    test_channels_chat/1,
    test_demo_realtime_chat/1,
    test_erlang_integration/1,
    test_fastapi_app/1,
    test_hooks_lifespan/1,
    test_websocket_chat/1
]).

-define(HOST, "127.0.0.1").

%% Order matters: examples that exercise the ASGI lifespan path
%% (`lifespan => on`) leave hornbeam_lifespan_runner state that the simple
%% eviction in `evict_app_modules/0` can't fully unwind across the worker-mode
%% main interpreter. Run the lifespan-using cases LAST.
all() ->
    [
        test_async_chat,
        test_websocket_chat,
        test_channels_chat,
        test_erlang_integration,
        test_demo_realtime_chat,
        test_fastapi_app,
        test_hooks_lifespan
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(inets),
    ProjectRoot = project_root(),
    [{project_root, ProjectRoot} | Config].

end_per_suite(_Config) ->
    application:stop(inets),
    application:stop(hornbeam),
    ok.

init_per_testcase(TestCase, Config) ->
    case skip_reason(TestCase, Config) of
        {skip, _} = Skip -> Skip;
        ok ->
            Port = pick_port(),
            [{port, Port}, {tc, TestCase} | Config]
    end.

skip_reason(TestCase, Config) ->
    Root = ?config(project_root, Config),
    Dir = case TestCase of
        test_async_chat -> "examples/async_chat";
        test_channels_chat -> "examples/channels_chat";
        test_demo_realtime_chat -> "examples/demo/realtime_chat";
        test_erlang_integration -> "examples/erlang_integration";
        test_fastapi_app -> "examples/fastapi_app";
        test_hooks_lifespan -> "examples/hooks_lifespan";
        test_websocket_chat -> "examples/websocket_chat"
    end,
    case filelib:is_dir(filename:join(Root, Dir)) of
        false ->
            {skip, lists:flatten(io_lib:format("~s missing", [Dir]))};
        true ->
            python_dep_skip(TestCase)
    end.

python_dep_skip(TestCase) when TestCase =:= test_demo_realtime_chat;
                              TestCase =:= test_fastapi_app ->
    case py:exec(<<"import fastapi">>) of
        ok -> ok;
        _ -> {skip, "fastapi not installed"}
    end;
python_dep_skip(_) ->
    ok.

end_per_testcase(_TestCase, _Config) ->
    catch hornbeam:stop(),
    %% Wait for the cowboy listener to actually release its socket and for
    %% any in-flight lifespan task to drain. Without this, the next test's
    %% start can race the prior listener's shutdown.
    timer:sleep(800),
    ok.

%%% ============================================================================
%%% Tests
%%% ============================================================================

test_async_chat(Config) ->
    start_asgi(Config, "examples/async_chat", "app:application", #{}),
    assert_get_200(Config, "/").

test_channels_chat(Config) ->
    Root = ?config(project_root, Config),
    PrivPath = filename:join(Root, "priv"),
    start_asgi(Config, "examples/channels_chat", "app:app", #{
        extra_pythonpath => [list_to_binary(PrivPath)]
    }),
    %% channels_chat serves index.html at /
    assert_get_200(Config, "/").

test_demo_realtime_chat(Config) ->
    start_asgi(Config, "examples/demo/realtime_chat", "app:app", #{}),
    assert_get_200(Config, "/").

test_erlang_integration(Config) ->
    %% erlang_integration's app.py uses `from hornbeam_erlang import call`,
    %% which routes through hornbeam_callbacks. Register stubs for the
    %% callbacks the / handler invokes (log_request) so the smoke GET
    %% doesn't blow up before the help banner is returned.
    register_erlang_integration_callbacks(),
    start_wsgi(Config, "examples/erlang_integration", "app:application", #{}),
    assert_get_200(Config, "/").

test_fastapi_app(Config) ->
    start_asgi(Config, "examples/fastapi_app", "app:app", #{lifespan => on}),
    assert_get_200(Config, "/").

test_hooks_lifespan(Config) ->
    start_asgi(Config, "examples/hooks_lifespan", "app:app", #{lifespan => on}),
    assert_get_200(Config, "/").

test_websocket_chat(Config) ->
    start_asgi(Config, "examples/websocket_chat", "app:app", #{}),
    %% websocket_chat exposes /health for HTTP smoke
    assert_get_200(Config, "/health").

%%% ============================================================================
%%% Helpers
%%% ============================================================================

start_asgi(Config, RelPath, AppSpec, Opts) ->
    do_start(Config, RelPath, AppSpec, Opts#{worker_class => asgi}).

start_wsgi(Config, RelPath, AppSpec, Opts) ->
    do_start(Config, RelPath, AppSpec, Opts#{worker_class => wsgi}).

do_start(Config, RelPath, AppSpec, Opts0) ->
    Root = ?config(project_root, Config),
    Port = ?config(port, Config),
    AppDir = filename:join(Root, RelPath),
    Bind = list_to_binary(io_lib:format("~s:~p", [?HOST, Port])),
    BasePath = list_to_binary(AppDir),
    ExtraPaths = maps:get(extra_pythonpath, Opts0, []),
    Opts1 = maps:remove(extra_pythonpath, Opts0),
    PythonPath = [BasePath | ExtraPaths],
    Opts = Opts1#{bind => Bind, pythonpath => PythonPath},
    %% Every example ships its own `app.py`; evict cached ones in every
    %% context so the new pythonpath wins.
    evict_app_modules(),
    ok = hornbeam:start(AppSpec, Opts),
    timer:sleep(500).

evict_app_modules() ->
    %% Worker-mode contexts share sys.modules and sys.path via the main
    %% interpreter, so any `app` / example dir from a prior test sticks
    %% around. Evict aggressively across every context: drop cached
    %% modules, drop sys.path entries that point at examples/, and clear
    %% hornbeam_lifespan_runner state.
    Code = <<"import sys\n"
             "_drop = []\n"
             "for _m in list(sys.modules):\n"
             "    if _m == 'app' or _m.startswith('app.') or _m.startswith('examples.'):\n"
             "        _drop.append(_m)\n"
             "for _m in _drop:\n"
             "    sys.modules.pop(_m, None)\n"
             "sys.path[:] = [p for p in sys.path if '/examples/' not in p]\n"
             "_lr = sys.modules.get('hornbeam_lifespan_runner')\n"
             "if _lr is not None:\n"
             "    if hasattr(_lr, '_lifespan_states'):\n"
             "        _lr._lifespan_states.clear()\n"
             "    if hasattr(_lr, '_lifespan_tasks'):\n"
             "        _lr._lifespan_tasks.clear()\n">>,
    Contexts = try py_context_router:contexts() catch _:_ -> [] end,
    lists:foreach(fun(Ctx) ->
        Ref = py_context:get_nif_ref(Ctx),
        catch py_nif:context_exec(Ref, Code)
    end, Contexts),
    ok.

assert_get_200(Config, Path) ->
    Url = url(Config, Path),
    {ok, {{_, Status, _}, _Headers, _Body}} =
        httpc:request(get, {Url, []}, [{timeout, 10000}], []),
    ?assertEqual(200, Status).

url(Config, Path) ->
    Port = ?config(port, Config),
    lists:flatten(io_lib:format("http://~s:~p~s", [?HOST, Port, Path])).

pick_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    Port.

register_erlang_integration_callbacks() ->
    %% The example uses `from hornbeam_erlang import call`, which routes to
    %% hornbeam_callbacks. Register stubs covering the / handler's call sites.
    catch hornbeam_callbacks:register(log_request, fun([_M, _P]) -> ok end),
    catch hornbeam_callbacks:register(get_config, fun([]) -> #{} end),
    catch hornbeam_callbacks:register(lookup_user, fun([_Id]) -> #{} end),
    catch hornbeam_callbacks:register(spawn_task, fun([_Data]) -> <<"task_0">> end),
    ok.

project_root() ->
    HornbeamBeam = code:which(hornbeam),
    EbinDir = filename:dirname(HornbeamBeam),
    LibDir = filename:dirname(EbinDir),
    SrcLink = filename:join(LibDir, "src"),
    case file:read_link(SrcLink) of
        {ok, RelPath} ->
            ActualSrc = filename:join(LibDir, RelPath),
            filename:dirname(filename:absname(ActualSrc));
        {error, _} ->
            Parts = filename:split(LibDir),
            find_before_build(Parts, [])
    end.

find_before_build([], Acc) ->
    filename:join(lists:reverse(Acc));
find_before_build(["_build" | _], Acc) ->
    filename:join(lists:reverse(Acc));
find_before_build([H | T], Acc) ->
    find_before_build(T, [H | Acc]).
