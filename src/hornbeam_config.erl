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

%%% @doc Hornbeam configuration management.
-module(hornbeam_config).

-behaviour(gen_server).

-export([
    start_link/0,
    get_config/0,
    get_config/1,
    set_config/1,
    set_config/2
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
-define(TABLE, hornbeam_config_table).

-record(state, {}).

%%% ============================================================================
%%% API
%%% ============================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Get all configuration.
-spec get_config() -> map().
get_config() ->
    case ets:lookup(?TABLE, config) of
        [{config, Config}] -> Config;
        [] -> #{}
    end.

%% @doc Get a configuration value.
-spec get_config(atom()) -> term().
get_config(Key) ->
    Config = get_config(),
    maps:get(Key, Config, undefined).

%% @doc Set the entire configuration.
-spec set_config(map()) -> ok.
set_config(Config) when is_map(Config) ->
    gen_server:call(?SERVER, {set_config, Config}).

%% @doc Set a configuration value.
-spec set_config(atom(), term()) -> ok.
set_config(Key, Value) ->
    gen_server:call(?SERVER, {set_config_key, Key, Value}).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Create ETS table for configuration
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        {read_concurrency, true}
    ]),

    %% Load default configuration from application env
    Defaults = load_app_env(),
    ets:insert(?TABLE, {config, Defaults}),

    {ok, #state{}}.

handle_call({set_config, Config}, _From, State) ->
    ets:insert(?TABLE, {config, Config}),
    {reply, ok, State};

handle_call({set_config_key, Key, Value}, _From, State) ->
    Config = get_config(),
    NewConfig = Config#{Key => Value},
    ets:insert(?TABLE, {config, NewConfig}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

load_app_env() ->
    Keys = [bind, workers, worker_class, timeout, keepalive,
            max_requests, preload_app, pythonpath],
    lists:foldl(fun(Key, Acc) ->
        case application:get_env(hornbeam, Key) of
            {ok, Value} -> Acc#{Key => Value};
            undefined -> Acc
        end
    end, #{}, Keys).
