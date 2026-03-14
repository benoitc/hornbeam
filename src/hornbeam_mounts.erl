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

%%% @doc ETS-based mount registry for multi-app support.
%%%
%%% Provides longest-prefix matching for routing requests to different
%%% WSGI/ASGI applications based on URL prefixes.
%%%
%%% == Example ==
%%% ```
%%% %% Register mounts
%%% hornbeam_mounts:register([
%%%     #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
%%%       worker_class => asgi, workers => 4, timeout => 30000},
%%%     #{prefix => <<"/">>, app_module => <<"frontend">>, app_callable => <<"app">>,
%%%       worker_class => wsgi, workers => 2, timeout => 30000}
%%% ]).
%%%
%%% %% Lookup a path
%%% {ok, Mount, PathInfo} = hornbeam_mounts:lookup(<<"/api/users">>).
%%% %% Mount contains mount config, PathInfo = <<"/users">>
%%% '''
-module(hornbeam_mounts).

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    register/1,
    lookup/1,
    list/0,
    clear/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, hornbeam_mounts).
-define(SERVER, ?MODULE).

-type mount() :: #{
    prefix := binary(),
    app_module := binary(),
    app_callable := binary(),
    worker_class := wsgi | asgi,
    workers := pos_integer(),
    timeout := pos_integer(),
    mount_id => binary(),           %% 6-char random ID for pool routing
    pool_enabled => boolean()       %% Enable persistent worker pool
}.

-export_type([mount/0]).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the mount registry.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register a list of mounts.
%% Mounts should be sorted by prefix length descending for correct matching.
-spec register([mount()]) -> ok.
register(Mounts) ->
    gen_server:call(?SERVER, {register, Mounts}).

%% @doc Lookup a path and return the matching mount and stripped path info.
%% Uses longest-prefix matching.
-spec lookup(Path :: binary()) -> {ok, mount(), PathInfo :: binary()} | {error, no_match}.
lookup(Path) ->
    %% Get sorted mounts (longest first)
    case ets:lookup(?TABLE, sorted_mounts) of
        [{sorted_mounts, Mounts}] ->
            find_matching_mount(Path, Mounts);
        [] ->
            {error, no_match}
    end.

%% @doc List all registered mounts.
-spec list() -> [mount()].
list() ->
    case ets:lookup(?TABLE, sorted_mounts) of
        [{sorted_mounts, Mounts}] -> Mounts;
        [] -> []
    end.

%% @doc Clear all registered mounts.
-spec clear() -> ok.
clear() ->
    gen_server:call(?SERVER, clear).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Create ETS table for mount storage
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({register, Mounts}, _From, State) ->
    %% Generate mount_id for each mount and sort by prefix length
    MountsWithIds = lists:map(fun(Mount) ->
        MountId = case maps:get(mount_id, Mount, undefined) of
            undefined -> generate_mount_id();
            Existing -> Existing
        end,
        Mount#{mount_id => MountId}
    end, Mounts),

    %% Sort mounts by prefix length descending (longest first)
    SortedMounts = lists:sort(
        fun(#{prefix := P1}, #{prefix := P2}) ->
            byte_size(P1) >= byte_size(P2)
        end,
        MountsWithIds
    ),
    ets:insert(?TABLE, {sorted_mounts, SortedMounts}),

    {reply, ok, State};

handle_call(clear, _From, State) ->
    ets:delete_all_objects(?TABLE),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

%% @private
%% Find the first mount whose prefix matches the path.
%% Since mounts are sorted by length descending, this implements longest-prefix matching.
find_matching_mount(_Path, []) ->
    {error, no_match};
find_matching_mount(Path, [Mount | Rest]) ->
    Prefix = maps:get(prefix, Mount),
    case matches_prefix(Path, Prefix) of
        true ->
            PathInfo = strip_prefix(Path, Prefix),
            {ok, Mount, PathInfo};
        false ->
            find_matching_mount(Path, Rest)
    end.

%% @private
%% Check if path starts with the given prefix.
matches_prefix(Path, Prefix) ->
    PrefixLen = byte_size(Prefix),
    case Prefix of
        <<"/">> ->
            %% Root prefix matches everything
            true;
        _ ->
            case Path of
                <<Prefix:PrefixLen/binary>> ->
                    %% Exact match (e.g., /api matches /api)
                    true;
                <<Prefix:PrefixLen/binary, $/, _/binary>> ->
                    %% Prefix followed by slash (e.g., /api matches /api/users)
                    true;
                <<Prefix:PrefixLen/binary, Rest/binary>> when Rest =:= <<>> ->
                    %% Exact match (redundant but explicit)
                    true;
                _ ->
                    false
            end
    end.

%% @private
%% Strip the mount prefix from the path to get PATH_INFO.
%% For WSGI/ASGI, PATH_INFO should be the path after SCRIPT_NAME.
strip_prefix(Path, Prefix) ->
    case Prefix of
        <<"/">> ->
            %% Root mount - keep full path
            Path;
        _ ->
            PrefixLen = byte_size(Prefix),
            case Path of
                <<Prefix:PrefixLen/binary>> ->
                    %% Exact match - PATH_INFO is /
                    <<"/">>;
                <<Prefix:PrefixLen/binary, Rest/binary>> ->
                    %% Has suffix - Rest should start with /
                    case Rest of
                        <<"/", _/binary>> -> Rest;
                        <<>> -> <<"/">>;
                        _ -> <<"/", Rest/binary>>
                    end
            end
    end.

%% @private
%% Generate a 6-character URL-safe random ID for mount routing.
%% Uses 3 random bytes encoded as URL-safe base64 (no padding).
generate_mount_id() ->
    Bytes = crypto:strong_rand_bytes(3),
    %% URL-safe base64 encoding (replaces + with - and / with _)
    B64 = base64:encode(Bytes),
    %% Replace unsafe characters and remove padding
    binary:replace(binary:replace(B64, <<"+">>, <<"-">>), <<"/">>, <<"_">>).
