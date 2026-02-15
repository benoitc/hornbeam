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

%%% @doc Shared state ETS for Python apps.
%%%
%%% This module provides a high-performance, concurrent-safe shared state
%%% store backed by ETS. Python apps can use this for:
%%% - Caching (ML model results, API responses)
%%% - Counters (request counts, rate limiting)
%%% - Session data
%%% - Any data that needs to be shared across requests
%%%
%%% ETS provides:
%%% - Millions of concurrent reads without blocking
%%% - Atomic updates (counters, compare-and-swap)
%%% - No GIL limitations (unlike Python dicts)
-module(hornbeam_state).

-behaviour(gen_server).

-export([
    start_link/0,
    get/1,
    set/2,
    delete/1,
    incr/2,
    decr/2,
    get_multi/1,
    set_multi/1,
    keys/0,
    keys/1,
    clear/0,
    size/0
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
-define(TABLE, hornbeam_state_table).

-record(state, {}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the shared state manager.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Get a value by key.
%% Returns the value or undefined if not found.
-spec get(Key :: term()) -> term() | undefined.
get(Key) ->
    case ets:lookup(?TABLE, Key) of
        [{_, Value}] -> Value;
        [] -> undefined
    end.

%% @doc Set a key-value pair.
-spec set(Key :: term(), Value :: term()) -> ok.
set(Key, Value) ->
    ets:insert(?TABLE, {Key, Value}),
    ok.

%% @doc Delete a key.
-spec delete(Key :: term()) -> ok.
delete(Key) ->
    ets:delete(?TABLE, Key),
    ok.

%% @doc Atomically increment a counter.
%% If the key doesn't exist, it's initialized to Delta.
%% Returns the new value.
-spec incr(Key :: term(), Delta :: integer()) -> integer().
incr(Key, Delta) ->
    try
        ets:update_counter(?TABLE, Key, Delta)
    catch
        error:badarg ->
            %% Key doesn't exist, initialize it
            ets:insert_new(?TABLE, {Key, 0}),
            ets:update_counter(?TABLE, Key, Delta)
    end.

%% @doc Atomically decrement a counter.
-spec decr(Key :: term(), Delta :: integer()) -> integer().
decr(Key, Delta) ->
    incr(Key, -Delta).

%% @doc Get multiple keys at once.
%% Returns a map of key => value for keys that exist.
-spec get_multi(Keys :: [term()]) -> map().
get_multi(Keys) ->
    lists:foldl(fun(Key, Acc) ->
        case ets:lookup(?TABLE, Key) of
            [{_, Value}] -> Acc#{Key => Value};
            [] -> Acc
        end
    end, #{}, Keys).

%% @doc Set multiple key-value pairs at once.
-spec set_multi([{Key :: term(), Value :: term()}]) -> ok.
set_multi(Pairs) ->
    ets:insert(?TABLE, Pairs),
    ok.

%% @doc Get all keys in the state store.
-spec keys() -> [term()].
keys() ->
    ets:foldl(fun({Key, _Value}, Acc) -> [Key | Acc] end, [], ?TABLE).

%% @doc Get keys matching a prefix (binary keys only).
-spec keys(Prefix :: binary()) -> [binary()].
keys(Prefix) when is_binary(Prefix) ->
    PrefixLen = byte_size(Prefix),
    ets:foldl(fun
        ({Key, _Value}, Acc) when is_binary(Key) ->
            case Key of
                <<Prefix:PrefixLen/binary, _/binary>> -> [Key | Acc];
                _ -> Acc
            end;
        (_, Acc) -> Acc
    end, [], ?TABLE).

%% @doc Clear all state.
-spec clear() -> ok.
clear() ->
    ets:delete_all_objects(?TABLE),
    ok.

%% @doc Get the number of entries.
-spec size() -> non_neg_integer().
size() ->
    ets:info(?TABLE, size).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Create ETS table with public access and write_concurrency
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #state{}}.

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
