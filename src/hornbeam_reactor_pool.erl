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

%%% @doc Pool of Python reactor contexts for hornbeam.
%%%
%%% Manages a pool of py_reactor_context processes for handling
%%% FD-based HTTP protocol processing. Provides load balancing
%%% across multiple Python contexts.
%%%
%%% == Usage ==
%%%
%%% ```
%%% %% Get a context for handling a request
%%% {ok, ContextPid} = hornbeam_reactor_pool:get_context(),
%%% ContextPid ! {fd_handoff, PythonFd, ClientInfo}.
%%% '''
-module(hornbeam_reactor_pool).

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    start_link/1,
    get_context/0,
    get_context/1,
    stats/0,
    stop/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    contexts :: [{pid(), integer()}],  %% [{Pid, ActiveConnections}]
    context_refs :: #{reference() => pid()},
    num_contexts :: pos_integer(),
    max_connections_per_context :: pos_integer(),
    app_module :: binary() | undefined,
    app_callable :: binary() | undefined,
    next_index :: pos_integer()
}).

-define(DEFAULT_NUM_CONTEXTS, 4).
-define(DEFAULT_MAX_CONNECTIONS, 100).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the reactor pool with default settings.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

%% @doc Start the reactor pool with options.
%%
%% Options:
%% - num_contexts: Number of reactor contexts (default: 4)
%% - max_connections_per_context: Max connections per context (default: 100)
%% - app_module: Python app module
%% - app_callable: Python app callable name
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% @doc Get a reactor context for handling a request.
%%
%% Returns the least-loaded context pid.
-spec get_context() -> {ok, pid()} | {error, term()}.
get_context() ->
    gen_server:call(?MODULE, get_context).

%% @doc Get a reactor context with specified affinity.
%%
%% Affinity can be used to route requests to specific contexts
%% (e.g., for session affinity).
-spec get_context(term()) -> {ok, pid()} | {error, term()}.
get_context(Affinity) ->
    gen_server:call(?MODULE, {get_context, Affinity}).

%% @doc Get pool statistics.
-spec stats() -> map().
stats() ->
    gen_server:call(?MODULE, stats).

%% @doc Stop the reactor pool.
-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init(Opts) ->
    process_flag(trap_exit, true),

    NumContexts = maps:get(num_contexts, Opts, ?DEFAULT_NUM_CONTEXTS),
    MaxConns = maps:get(max_connections_per_context, Opts, ?DEFAULT_MAX_CONNECTIONS),
    AppModule = maps:get(app_module, Opts, undefined),
    AppCallable = maps:get(app_callable, Opts, undefined),

    %% Start reactor contexts
    ContextOpts = #{
        max_connections => MaxConns,
        app_module => AppModule,
        app_callable => AppCallable
    },

    {Contexts, Refs} = start_contexts(NumContexts, ContextOpts),

    State = #state{
        contexts = Contexts,
        context_refs = Refs,
        num_contexts = NumContexts,
        max_connections_per_context = MaxConns,
        app_module = AppModule,
        app_callable = AppCallable,
        next_index = 1
    },

    {ok, State}.

handle_call(get_context, _From, State) ->
    %% Round-robin selection
    #state{contexts = Contexts, next_index = Index} = State,
    Len = length(Contexts),
    {Pid, _} = lists:nth(((Index - 1) rem Len) + 1, Contexts),
    NewState = State#state{next_index = Index + 1},
    {reply, {ok, Pid}, NewState};

handle_call({get_context, Affinity}, _From, State) ->
    %% Affinity-based selection (consistent hashing)
    #state{contexts = Contexts} = State,
    Len = length(Contexts),
    Index = (erlang:phash2(Affinity) rem Len) + 1,
    {Pid, _} = lists:nth(Index, Contexts),
    {reply, {ok, Pid}, State};

handle_call(stats, _From, State) ->
    #state{contexts = Contexts, num_contexts = Num, max_connections_per_context = Max} = State,
    ContextStats = lists:map(fun({Pid, ActiveConns}) ->
        #{pid => Pid, active_connections => ActiveConns}
    end, Contexts),
    Stats = #{
        num_contexts => Num,
        max_connections_per_context => Max,
        contexts => ContextStats
    },
    {reply, Stats, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
    #state{contexts = Contexts, context_refs = Refs} = State,
    case maps:get(Ref, Refs, undefined) of
        undefined ->
            {noreply, State};
        Pid ->
            error_logger:warning_msg("Reactor context ~p died: ~p~n", [Pid, Reason]),
            %% Remove dead context and restart
            NewContexts = lists:keydelete(Pid, 1, Contexts),
            NewRefs = maps:remove(Ref, Refs),

            %% Restart a new context
            ContextOpts = #{
                max_connections => State#state.max_connections_per_context,
                app_module => State#state.app_module,
                app_callable => State#state.app_callable
            },
            case start_context(length(NewContexts) + 1, ContextOpts) of
                {ok, NewPid, NewRef} ->
                    {noreply, State#state{
                        contexts = [{NewPid, 0} | NewContexts],
                        context_refs = NewRefs#{NewRef => NewPid}
                    }};
                {error, _} ->
                    {noreply, State#state{
                        contexts = NewContexts,
                        context_refs = NewRefs
                    }}
            end
    end;

handle_info({'EXIT', Pid, Reason}, State) ->
    error_logger:warning_msg("Linked process ~p exited: ~p~n", [Pid, Reason]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{contexts = Contexts}) ->
    %% Stop all contexts
    lists:foreach(fun({Pid, _}) ->
        catch py_reactor_context:stop(Pid)
    end, Contexts),
    ok.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

%% @private
start_contexts(Num, Opts) ->
    start_contexts(Num, Opts, [], #{}).

start_contexts(0, _Opts, Contexts, Refs) ->
    {lists:reverse(Contexts), Refs};
start_contexts(N, Opts, Contexts, Refs) ->
    case start_context(N, Opts) of
        {ok, Pid, Ref} ->
            start_contexts(N - 1, Opts, [{Pid, 0} | Contexts], Refs#{Ref => Pid});
        {error, Reason} ->
            error_logger:error_msg("Failed to start reactor context ~p: ~p~n", [N, Reason]),
            start_contexts(N - 1, Opts, Contexts, Refs)
    end.

%% @private
start_context(Id, Opts) ->
    case py_reactor_context:start_link(Id, auto, Opts) of
        {ok, Pid} ->
            Ref = erlang:monitor(process, Pid),
            {ok, Pid, Ref};
        {error, _} = Error ->
            Error
    end.
