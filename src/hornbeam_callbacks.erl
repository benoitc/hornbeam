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

%%% @doc Erlang callback registry for Python apps.
%%%
%%% This module manages callbacks that Python apps can invoke.
%%% It wraps the erlang-python function registration with additional
%%% features like validation and logging.
-module(hornbeam_callbacks).

-behaviour(gen_server).

-export([
    start_link/0,
    register/2,
    register/3,
    unregister/1,
    call/2,
    cast/2,
    list/0
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

-record(state, {
    callbacks = #{} :: map()
}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the callback manager.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register a callback function.
%% The function should accept a list of arguments.
-spec register(Name :: atom() | binary(), Fun :: fun((list()) -> term())) -> ok.
register(Name, Fun) when is_function(Fun, 1) ->
    gen_server:call(?SERVER, {register, Name, Fun}).

%% @doc Register a module:function as a callback.
-spec register(Name :: atom() | binary(), Module :: atom(), Function :: atom()) -> ok.
register(Name, Module, Function) ->
    gen_server:call(?SERVER, {register_mf, Name, Module, Function}).

%% @doc Unregister a callback.
-spec unregister(Name :: atom() | binary()) -> ok.
unregister(Name) ->
    gen_server:call(?SERVER, {unregister, Name}).

%% @doc Call a registered callback synchronously.
-spec call(Name :: atom() | binary(), Args :: list()) -> {ok, term()} | {error, term()}.
call(Name, Args) ->
    gen_server:call(?SERVER, {call, Name, Args}).

%% @doc Call a registered callback asynchronously (fire and forget).
-spec cast(Name :: atom() | binary(), Args :: list()) -> ok.
cast(Name, Args) ->
    gen_server:cast(?SERVER, {cast, Name, Args}).

%% @doc List all registered callbacks.
-spec list() -> [atom() | binary()].
list() ->
    gen_server:call(?SERVER, list).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    {ok, #state{}}.

handle_call({register, Name, Fun}, _From, #state{callbacks = Callbacks} = State) ->
    %% Also register with erlang-python
    py:register_function(Name, Fun),
    {reply, ok, State#state{callbacks = Callbacks#{Name => {fun_wrapper, Fun}}}};

handle_call({register_mf, Name, Module, Function}, _From, #state{callbacks = Callbacks} = State) ->
    %% Also register with erlang-python
    py:register_function(Name, Module, Function),
    {reply, ok, State#state{callbacks = Callbacks#{Name => {mf, Module, Function}}}};

handle_call({unregister, Name}, _From, #state{callbacks = Callbacks} = State) ->
    %% Also unregister from erlang-python
    py:unregister_function(Name),
    {reply, ok, State#state{callbacks = maps:remove(Name, Callbacks)}};

handle_call({call, Name, Args}, _From, #state{callbacks = Callbacks} = State) ->
    Result = case maps:get(Name, Callbacks, undefined) of
        undefined ->
            {error, not_found};
        {fun_wrapper, Fun} ->
            try
                {ok, Fun(Args)}
            catch
                Class:Reason ->
                    {error, {Class, Reason}}
            end;
        {mf, Module, Function} ->
            try
                {ok, apply(Module, Function, Args)}
            catch
                Class:Reason ->
                    {error, {Class, Reason}}
            end
    end,
    {reply, Result, State};

handle_call(list, _From, #state{callbacks = Callbacks} = State) ->
    {reply, maps:keys(Callbacks), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({cast, Name, Args}, #state{callbacks = Callbacks} = State) ->
    case maps:get(Name, Callbacks, undefined) of
        undefined ->
            ok;
        {fun_wrapper, Fun} ->
            spawn(fun() -> catch Fun(Args) end);
        {mf, Module, Function} ->
            spawn(fun() -> catch apply(Module, Function, Args) end)
    end,
    {noreply, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
