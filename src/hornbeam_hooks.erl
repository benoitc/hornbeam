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

%%% @doc Dirty execution API for hornbeam.
%%%
%%% Provides a hooks-style API for executing registered handlers.
%%% Uses gen_server for safe registration and persistent_term for fast lookups.
%%%
%%% == Usage ==
%%%
%%% ```erlang
%%% %% Register a handler (MFA or fun)
%%% hornbeam_hooks:reg(<<"myapp.ml:MLApp">>, my_module, my_fun, 3).
%%% hornbeam_hooks:reg(<<"myapp.ml:MLApp">>, fun(Action, Args, Kwargs) -> ... end).
%%%
%%% %% Execute
%%% {ok, Result} = hornbeam_hooks:execute(<<"myapp.ml:MLApp">>, <<"action">>, Args, Kwargs).
%%% '''
%%%
%%% From Python:
%%% ```python
%%% from hornbeam_erlang import execute, stream
%%%
%%% result = execute("myapp.ml:MLApp", "inference", [data], {"model": "gpt-4"})
%%%
%%% for chunk in stream("myapp.llm:LLMApp", "generate", [prompt]):
%%%     yield chunk
%%% '''
-module(hornbeam_hooks).

-behaviour(gen_server).

-export([
    start_link/0,
    reg/2,
    reg/4,
    reg_python/1,
    unreg/1,
    execute/4,
    execute_async/4,
    await_result/2,
    stream/4,
    stream_next_ref/1,
    find/1,
    all/0
]).

%% Response helpers
-export([
    ok/1,
    error/1,
    stream_from_list/1,
    stream_from_fun/1,
    stream_chunk/1,
    stream_done/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(HOOK_KEY(AppPath), {hornbeam_hooks, AppPath}).
-define(HOOKS_LIST, hornbeam_hooks_list).

-record(state, {
    tasks = #{} :: map(),      % TaskRef => {running, Pid} | {completed, Result} | {waiting, From}
    generators = #{} :: map()  % GenRef => GeneratorFun
}).

%%% ============================================================================
%%% API
%%% ============================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register a handler function for an app path.
-spec reg(AppPath :: binary(), Handler :: fun((binary(), list(), map()) -> term())) -> ok.
reg(AppPath, Handler) when is_binary(AppPath), is_function(Handler, 3) ->
    gen_server:call(?SERVER, {reg, AppPath, {fun_handler, Handler}}).

%% @doc Register a module:function as handler.
-spec reg(AppPath :: binary(), Module :: atom(), Function :: atom(), Arity :: 3) -> ok.
reg(AppPath, Module, Function, 3) when is_binary(AppPath), is_atom(Module), is_atom(Function) ->
    gen_server:call(?SERVER, {reg, AppPath, {mfa, Module, Function}}).

%% @doc Register a Python handler for an app path.
%% The actual handler is stored in Python; this just marks it for callback.
-spec reg_python(AppPath :: binary()) -> ok.
reg_python(AppPath) when is_binary(AppPath) ->
    gen_server:call(?SERVER, {reg, AppPath, {python_handler}}).

%% @doc Unregister a handler.
-spec unreg(AppPath :: binary()) -> ok.
unreg(AppPath) when is_binary(AppPath) ->
    gen_server:call(?SERVER, {unreg, AppPath}).

%% @doc Find handler for an app path (fast lookup via persistent_term).
-spec find(AppPath :: binary()) -> {ok, term()} | not_found.
find(AppPath) when is_binary(AppPath) ->
    case persistent_term:get(?HOOK_KEY(AppPath), not_found) of
        not_found -> not_found;
        Handler -> {ok, Handler}
    end.

%% @doc List all registered app paths.
-spec all() -> [binary()].
all() ->
    persistent_term:get(?HOOKS_LIST, []).

%% @doc Execute an action on a registered app.
%% If no handler is registered, calls Python directly.
-spec execute(AppPath :: binary(), Action :: binary(), Args :: list(), Kwargs :: map()) ->
    {ok, term()} | {error, term()}.
execute(AppPath, Action, Args, Kwargs) when is_binary(AppPath), is_binary(Action) ->
    case find(AppPath) of
        not_found ->
            execute_python(AppPath, Action, Args, Kwargs);
        {ok, {fun_handler, Handler}} ->
            execute_fun(Handler, Action, Args, Kwargs);
        {ok, {mfa, Module, Function}} ->
            execute_mfa(Module, Function, Action, Args, Kwargs);
        {ok, {python_handler}} ->
            execute_python_registered(AppPath, Action, Args, Kwargs)
    end.

%% @doc Execute async - returns task ID (binary for Python round-trip compatibility).
-spec execute_async(AppPath :: binary(), Action :: binary(), Args :: list(), Kwargs :: map()) ->
    {ok, binary()} | {error, term()}.
execute_async(AppPath, Action, Args, Kwargs) when is_binary(AppPath), is_binary(Action) ->
    gen_server:call(?SERVER, {execute_async, AppPath, Action, Args, Kwargs}).

%% @doc Wait for async task result.
-spec await_result(TaskId :: binary(), Timeout :: integer()) ->
    {ok, term()} | {error, term()}.
await_result(TaskId, Timeout) ->
    gen_server:call(?SERVER, {await_result, TaskId, Timeout}, infinity).

%% @doc Stream execution - returns a generator function.
%% Call the returned function repeatedly until it returns 'done'.
-spec stream(AppPath :: binary(), Action :: binary(), Args :: list(), Kwargs :: map()) ->
    {ok, fun(() -> {value, term()} | done | {error, term()})} | {error, term()}.
stream(AppPath, Action, Args, Kwargs) when is_binary(AppPath), is_binary(Action) ->
    case find(AppPath) of
        not_found ->
            %% No Erlang handler, use Python streaming
            stream_python(AppPath, Action, Args, Kwargs);
        {ok, {fun_handler, Handler}} ->
            stream_fun(Handler, Action, Args, Kwargs);
        {ok, {mfa, Module, Function}} ->
            stream_mfa(Module, Function, Action, Args, Kwargs);
        {ok, {python_handler}} ->
            %% Registered Python handler, use Python streaming
            stream_python_registered(AppPath, Action, Args, Kwargs)
    end.

%% @doc Call next on a stored generator ref.
-spec stream_next_ref(GenRef :: reference()) -> {value, term()} | done | {error, term()}.
stream_next_ref(GenRef) ->
    gen_server:call(?SERVER, {stream_next_ref, GenRef}, infinity).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Initialize the hooks list
    persistent_term:put(?HOOKS_LIST, []),
    {ok, #state{}}.

handle_call({reg, AppPath, Handler}, _From, State) ->
    %% Store in persistent_term for fast lookup
    persistent_term:put(?HOOK_KEY(AppPath), Handler),
    %% Update hooks list
    List = persistent_term:get(?HOOKS_LIST, []),
    NewList = case lists:member(AppPath, List) of
        true -> List;
        false -> [AppPath | List]
    end,
    persistent_term:put(?HOOKS_LIST, NewList),
    {reply, ok, State};

handle_call({unreg, AppPath}, _From, State) ->
    %% Remove from persistent_term
    persistent_term:erase(?HOOK_KEY(AppPath)),
    %% Update hooks list
    List = persistent_term:get(?HOOKS_LIST, []),
    NewList = lists:delete(AppPath, List),
    persistent_term:put(?HOOKS_LIST, NewList),
    {reply, ok, State};

handle_call({execute_async, AppPath, Action, Args, Kwargs}, _From,
            #state{tasks = Tasks} = State) ->
    %% Use binary task ID for Python round-trip compatibility
    TaskId = list_to_binary(erlang:ref_to_list(make_ref())),
    Self = self(),
    _Pid = spawn_link(fun() ->
        Result = execute(AppPath, Action, Args, Kwargs),
        Self ! {task_result, TaskId, Result}
    end),
    NewTasks = Tasks#{TaskId => running},
    {reply, {ok, TaskId}, State#state{tasks = NewTasks}};

handle_call({await_result, TaskRef, Timeout}, From, #state{tasks = Tasks} = State) ->
    case maps:get(TaskRef, Tasks, undefined) of
        undefined ->
            {reply, {error, task_not_found}, State};
        {completed, Result} ->
            {reply, Result, State#state{tasks = maps:remove(TaskRef, Tasks)}};
        running ->
            NewTasks = Tasks#{TaskRef => {waiting, From}},
            erlang:send_after(Timeout, self(), {task_timeout, TaskRef}),
            {noreply, State#state{tasks = NewTasks}}
    end;

handle_call({stream_next_ref, GenRef}, _From, #state{generators = Gens} = State) ->
    case maps:get(GenRef, Gens, undefined) of
        undefined ->
            {reply, {error, generator_not_found}, State};
        GenFun ->
            case GenFun() of
                done ->
                    {reply, done, State#state{generators = maps:remove(GenRef, Gens)}};
                {value, Value} ->
                    {reply, {value, Value}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State#state{generators = maps:remove(GenRef, Gens)}}
            end
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({task_result, TaskRef, Result}, #state{tasks = Tasks} = State) ->
    case maps:get(TaskRef, Tasks, undefined) of
        undefined ->
            {noreply, State};
        {waiting, From} ->
            gen_server:reply(From, Result),
            {noreply, State#state{tasks = maps:remove(TaskRef, Tasks)}};
        running ->
            NewTasks = Tasks#{TaskRef => {completed, Result}},
            {noreply, State#state{tasks = NewTasks}}
    end;

handle_info({task_timeout, TaskRef}, #state{tasks = Tasks} = State) ->
    case maps:get(TaskRef, Tasks, undefined) of
        {waiting, From} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, State#state{tasks = maps:remove(TaskRef, Tasks)}};
        _ ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

execute_fun(Handler, Action, Args, Kwargs) ->
    try
        Result = Handler(Action, Args, Kwargs),
        {ok, Result}
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, Reason};
        exit:Reason -> {error, {exit, Reason}}
    end.

execute_mfa(Module, Function, Action, Args, Kwargs) ->
    try
        Result = Module:Function(Action, Args, Kwargs),
        {ok, Result}
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, Reason};
        exit:Reason -> {error, {exit, Reason}}
    end.

execute_python(AppPath, Action, Args, Kwargs) ->
    try
        py:call(hornbeam_hooks_runner, execute, [AppPath, Action, Args, Kwargs])
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, Reason};
        exit:Reason -> {error, {exit, Reason}}
    end.

execute_python_registered(AppPath, Action, Args, Kwargs) ->
    try
        Result = py:call(hornbeam_hooks_runner, execute_registered, [AppPath, Action, Args, Kwargs]),
        {ok, Result}
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, Reason};
        exit:Reason -> {error, {exit, Reason}}
    end.

stream_fun(Handler, Action, Args, Kwargs) ->
    try
        %% Handler should return {ok, GeneratorFun} or {error, Reason}
        Handler(stream, Action, Args, Kwargs)
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, Reason};
        exit:Reason -> {error, {exit, Reason}}
    end.

stream_mfa(Module, Function, Action, Args, Kwargs) ->
    try
        Module:Function(stream, Action, Args, Kwargs)
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, Reason};
        exit:Reason -> {error, {exit, Reason}}
    end.

stream_python(AppPath, Action, Args, Kwargs) ->
    %% Start Python generator
    case py:call(hornbeam_hooks_runner, stream_start, [AppPath, Action, Args, Kwargs]) of
        {ok, GenId} ->
            %% Return a generator function
            GenFun = fun() ->
                case py:call(hornbeam_hooks_runner, stream_next, [GenId]) of
                    {ok, Value} -> {value, Value};
                    done -> done;
                    {error, Reason} -> {error, Reason}
                end
            end,
            {ok, GenFun};
        {error, Reason} ->
            {error, Reason}
    end.

stream_python_registered(AppPath, Action, Args, Kwargs) ->
    %% Start Python generator for registered handler
    case py:call(hornbeam_hooks_runner, stream_registered_start, [AppPath, Action, Args, Kwargs]) of
        {ok, GenId} ->
            %% Return a generator function
            GenFun = fun() ->
                case py:call(hornbeam_hooks_runner, stream_next, [GenId]) of
                    {ok, Value} -> {value, Value};
                    done -> done;
                    {error, Reason} -> {error, Reason}
                end
            end,
            {ok, GenFun};
        {error, Reason} ->
            {error, Reason}
    end.

%%% ============================================================================
%%% Response Helpers
%%% ============================================================================

%% @doc Wrap a successful result.
-spec ok(term()) -> {ok, term()}.
ok(Result) ->
    {ok, Result}.

%% @doc Wrap an error.
-spec error(term()) -> {error, term()}.
error(Reason) ->
    {error, Reason}.

%% @doc Create a stream generator from a list.
%% Returns {ok, GeneratorFun} for use in stream handlers.
%%
%% Example:
%% ```erlang
%% handler(stream, <<"generate">>, Args, _Kwargs) ->
%%     Chunks = ["Hello", " ", "World"],
%%     hornbeam_hooks:stream_from_list(Chunks).
%% '''
-spec stream_from_list(list()) -> {ok, fun(() -> {value, term()} | done)}.
stream_from_list(List) when is_list(List) ->
    Ref = make_ref(),
    put(Ref, List),
    GenFun = fun() ->
        case get(Ref) of
            [] ->
                erase(Ref),
                done;
            [H | T] ->
                put(Ref, T),
                {value, H}
        end
    end,
    {ok, GenFun}.

%% @doc Create a stream generator from a function.
%% The function should return {value, Chunk} or done.
%%
%% Example:
%% ```erlang
%% handler(stream, <<"count">>, [Max], _Kwargs) ->
%%     Ref = make_ref(),
%%     put(Ref, 0),
%%     hornbeam_hooks:stream_from_fun(fun() ->
%%         N = get(Ref),
%%         if N >= Max ->
%%             erase(Ref),
%%             done;
%%         true ->
%%             put(Ref, N + 1),
%%             {value, N}
%%         end
%%     end).
%% '''
-spec stream_from_fun(fun(() -> {value, term()} | done)) -> {ok, fun()}.
stream_from_fun(Fun) when is_function(Fun, 0) ->
    {ok, Fun}.

%% @doc Return a stream chunk (for use in generator functions).
-spec stream_chunk(term()) -> {value, term()}.
stream_chunk(Value) ->
    {value, Value}.

%% @doc Signal end of stream (for use in generator functions).
-spec stream_done() -> done.
stream_done() ->
    done.
