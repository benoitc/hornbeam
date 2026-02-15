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

%%% @doc Async task spawning for Python apps.
%%%
%%% This module lets Python web apps spawn background Erlang tasks.
%%% Each task runs in its own Erlang process, providing:
%%% - Non-blocking execution (return immediately to Python)
%%% - Fault isolation (task crash doesn't affect web request)
%%% - Supervision (tasks are supervised, can be monitored)
%%%
%%% Use cases:
%%% - Background order processing
%%% - Sending emails/notifications
%%% - ML inference jobs
%%% - Any slow operation that shouldn't block the response
-module(hornbeam_tasks).

-behaviour(gen_server).

%% Avoid clash with BIF spawn/3
-compile({no_auto_import,[spawn/3]}).

-export([
    start_link/0,
    spawn/2,
    spawn/3,
    status/1,
    result/1,
    await/2,
    cancel/1,
    list/0,
    register_handler/2,
    unregister_handler/1
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
-define(TABLE, hornbeam_tasks_table).

-record(state, {
    handlers = #{} :: map()  % name => fun
}).

-record(task, {
    id :: binary(),
    name :: atom() | binary(),
    args :: list(),
    pid :: pid() | undefined,
    status :: pending | running | completed | failed | cancelled,
    result :: term(),
    created_at :: integer(),
    started_at :: integer() | undefined,
    completed_at :: integer() | undefined
}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the task manager.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Spawn a new async task.
%% Returns the task ID immediately.
-spec spawn(Name :: atom() | binary(), Args :: list()) -> {ok, TaskId :: binary()}.
spawn(Name, Args) ->
    spawn(Name, Args, #{}).

%% @doc Spawn a task with options.
%% Options:
%% - timeout: Max execution time in ms (default: infinity)
-spec spawn(Name :: atom() | binary(), Args :: list(), Opts :: map()) ->
    {ok, TaskId :: binary()}.
spawn(Name, Args, Opts) ->
    gen_server:call(?SERVER, {spawn, Name, Args, Opts}).

%% @doc Get task status.
%% Returns: pending | running | completed | failed | cancelled | not_found
-spec status(TaskId :: binary()) -> atom().
status(TaskId) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, Task}] -> Task#task.status;
        [] -> not_found
    end.

%% @doc Get task result (non-blocking).
%% Returns {ok, Result} | {error, Reason} | pending | not_found
-spec result(TaskId :: binary()) -> {ok, term()} | {error, term()} | pending | not_found.
result(TaskId) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, #task{status = completed, result = Result}}] ->
            {ok, Result};
        [{_, #task{status = failed, result = Reason}}] ->
            {error, Reason};
        [{_, #task{status = cancelled}}] ->
            {error, cancelled};
        [{_, _Task}] ->
            pending;
        [] ->
            not_found
    end.

%% @doc Wait for task completion with timeout.
%% Returns {ok, Result} | {error, Reason} | {error, timeout}
-spec await(TaskId :: binary(), Timeout :: pos_integer()) ->
    {ok, term()} | {error, term()}.
await(TaskId, Timeout) ->
    gen_server:call(?SERVER, {await, TaskId, Timeout}, Timeout + 1000).

%% @doc Cancel a task.
-spec cancel(TaskId :: binary()) -> ok | {error, term()}.
cancel(TaskId) ->
    gen_server:call(?SERVER, {cancel, TaskId}).

%% @doc List all tasks.
-spec list() -> [map()].
list() ->
    ets:foldl(fun({_, Task}, Acc) ->
        [task_to_map(Task) | Acc]
    end, [], ?TABLE).

%% @doc Register a task handler function.
%% The function should accept a list of args and return a result.
-spec register_handler(Name :: atom(), Handler :: fun((list()) -> term())) -> ok.
register_handler(Name, Handler) when is_function(Handler, 1) ->
    gen_server:call(?SERVER, {register_handler, Name, Handler}).

%% @doc Unregister a task handler.
-spec unregister_handler(Name :: atom()) -> ok.
unregister_handler(Name) ->
    gen_server:call(?SERVER, {unregister_handler, Name}).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Create ETS table for tasks
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        {keypos, 1},
        {read_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call({spawn, Name, Args, Opts}, _From, #state{handlers = Handlers} = State) ->
    %% Generate task ID
    TaskId = generate_task_id(),

    %% Create task record
    Task = #task{
        id = TaskId,
        name = Name,
        args = Args,
        status = pending,
        created_at = erlang:system_time(millisecond)
    },

    %% Store task
    ets:insert(?TABLE, {TaskId, Task}),

    %% Start the task
    case maps:get(Name, Handlers, undefined) of
        undefined ->
            %% Try registered Erlang function
            case py:get_registered_function(Name) of
                undefined ->
                    %% No handler found, mark as failed
                    ets:update_element(?TABLE, TaskId,
                                       [{#task.status + 1, failed},
                                        {#task.result + 1, {error, handler_not_found}}]),
                    {reply, {error, handler_not_found}, State};
                Handler ->
                    start_task(TaskId, Handler, Args, Opts),
                    {reply, {ok, TaskId}, State}
            end;
        Handler ->
            start_task(TaskId, Handler, Args, Opts),
            {reply, {ok, TaskId}, State}
    end;

handle_call({await, TaskId, Timeout}, From, State) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, #task{status = completed, result = Result}}] ->
            {reply, {ok, Result}, State};
        [{_, #task{status = failed, result = Reason}}] ->
            {reply, {error, Reason}, State};
        [{_, #task{status = cancelled}}] ->
            {reply, {error, cancelled}, State};
        [{_, _Task}] ->
            %% Task still running, set up a monitor
            spawn(fun() ->
                Result = await_task(TaskId, Timeout),
                gen_server:reply(From, Result)
            end),
            {noreply, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({cancel, TaskId}, _From, State) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, #task{pid = Pid, status = running}}] when is_pid(Pid) ->
            exit(Pid, cancelled),
            ets:update_element(?TABLE, TaskId, [{#task.status + 1, cancelled}]),
            {reply, ok, State};
        [{_, #task{status = pending}}] ->
            ets:update_element(?TABLE, TaskId, [{#task.status + 1, cancelled}]),
            {reply, ok, State};
        [{_, _}] ->
            {reply, {error, already_completed}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({register_handler, Name, Handler}, _From, #state{handlers = Handlers} = State) ->
    {reply, ok, State#state{handlers = Handlers#{Name => Handler}}};

handle_call({unregister_handler, Name}, _From, #state{handlers = Handlers} = State) ->
    {reply, ok, State#state{handlers = maps:remove(Name, Handlers)}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _MonRef, process, Pid, Reason}, State) ->
    %% Find and update the task for this process
    case find_task_by_pid(Pid) of
        {ok, TaskId} ->
            case Reason of
                normal ->
                    ok;  % Result already set
                cancelled ->
                    ets:update_element(?TABLE, TaskId,
                                       [{#task.status + 1, cancelled},
                                        {#task.completed_at + 1, erlang:system_time(millisecond)}]);
                _ ->
                    ets:update_element(?TABLE, TaskId,
                                       [{#task.status + 1, failed},
                                        {#task.result + 1, Reason},
                                        {#task.completed_at + 1, erlang:system_time(millisecond)}])
            end;
        not_found ->
            ok
    end,
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

generate_task_id() ->
    Bytes = crypto:strong_rand_bytes(12),
    base64:encode(Bytes).

start_task(TaskId, Handler, Args, _Opts) ->
    Self = self(),
    Pid = erlang:spawn_link(fun() ->
        try
            %% Update status to running
            ets:update_element(?TABLE, TaskId,
                               [{#task.status + 1, running},
                                {#task.pid + 1, self()},
                                {#task.started_at + 1, erlang:system_time(millisecond)}]),

            %% Execute handler
            Result = Handler(Args),

            %% Update with result
            ets:update_element(?TABLE, TaskId,
                               [{#task.status + 1, completed},
                                {#task.result + 1, Result},
                                {#task.completed_at + 1, erlang:system_time(millisecond)}])
        catch
            Class:Reason:Stack ->
                ets:update_element(?TABLE, TaskId,
                                   [{#task.status + 1, failed},
                                    {#task.result + 1, {Class, Reason, Stack}},
                                    {#task.completed_at + 1, erlang:system_time(millisecond)}])
        end,
        %% Notify parent
        Self ! {task_done, TaskId}
    end),
    erlang:monitor(process, Pid),
    ok.

find_task_by_pid(Pid) ->
    Result = ets:foldl(fun
        ({TaskId, #task{pid = P}}, not_found) when P =:= Pid ->
            {ok, TaskId};
        (_, Acc) ->
            Acc
    end, not_found, ?TABLE),
    Result.

await_task(TaskId, Timeout) ->
    EndTime = erlang:system_time(millisecond) + Timeout,
    await_task_loop(TaskId, EndTime).

await_task_loop(TaskId, EndTime) ->
    Now = erlang:system_time(millisecond),
    if
        Now >= EndTime ->
            {error, timeout};
        true ->
            case ets:lookup(?TABLE, TaskId) of
                [{_, #task{status = completed, result = Result}}] ->
                    {ok, Result};
                [{_, #task{status = failed, result = Reason}}] ->
                    {error, Reason};
                [{_, #task{status = cancelled}}] ->
                    {error, cancelled};
                [{_, _}] ->
                    timer:sleep(10),
                    await_task_loop(TaskId, EndTime);
                [] ->
                    {error, not_found}
            end
    end.

task_to_map(#task{id = Id, name = Name, status = Status,
                  created_at = Created, started_at = Started,
                  completed_at = Completed}) ->
    #{
        id => Id,
        name => Name,
        status => Status,
        created_at => Created,
        started_at => Started,
        completed_at => Completed
    }.
