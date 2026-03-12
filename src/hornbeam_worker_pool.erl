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

%%% @doc Top-level supervisor for persistent worker pools.
%%%
%%% This supervisor manages hornbeam_worker_arbiter processes, one per mount
%%% with pool_enabled = true. Each arbiter manages N persistent Python workers.
%%%
%%% Architecture:
%%% ```
%%% hornbeam_worker_pool (supervisor, one_for_one)
%%% +-- hornbeam_worker_arbiter (mount: "abc123")
%%% |   +-- manages N Python workers via channels
%%% +-- hornbeam_worker_arbiter (mount: "def456")
%%%     +-- manages N Python workers via channels
%%% '''
-module(hornbeam_worker_pool).

-behaviour(supervisor).

-export([
    start_link/0,
    start_mount_pool/2,
    stop_mount_pool/1,
    get_channel/2,
    list_pools/0
]).

-export([init/1]).

-define(SERVER, ?MODULE).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the worker pool supervisor.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Start a worker pool for a mount.
%%
%% Config should contain:
%% - app_module: Python module name
%% - app_callable: Python callable name
%% - worker_class: wsgi | asgi
%% - workers: Number of workers (default: schedulers count)
%% - heartbeat_interval: Heartbeat check interval in ms (default: 5000)
%% - heartbeat_timeout: Max time without heartbeat in ms (default: 15000)
-spec start_mount_pool(MountId :: binary(), Config :: map()) ->
    {ok, pid()} | {error, term()}.
start_mount_pool(MountId, Config) ->
    ChildSpec = #{
        id => {hornbeam_worker_arbiter, MountId},
        start => {hornbeam_worker_arbiter, start_link, [MountId, Config]},
        restart => permanent,
        shutdown => 10000,
        type => worker,
        modules => [hornbeam_worker_arbiter]
    },
    supervisor:start_child(?SERVER, ChildSpec).

%% @doc Stop a worker pool for a mount.
-spec stop_mount_pool(MountId :: binary()) -> ok | {error, term()}.
stop_mount_pool(MountId) ->
    ChildId = {hornbeam_worker_arbiter, MountId},
    case supervisor:terminate_child(?SERVER, ChildId) of
        ok ->
            supervisor:delete_child(?SERVER, ChildId);
        {error, not_found} ->
            {error, not_found};
        Error ->
            Error
    end.

%% @doc Get channel for a worker in a mount's pool.
%%
%% Uses scheduler affinity: the scheduler ID selects a worker via
%% modulo on the channels tuple size.
-spec get_channel(MountId :: binary(), SchedId :: pos_integer()) -> term().
get_channel(MountId, SchedId) ->
    Channels = hornbeam_worker_arbiter:get_channels(MountId),
    element((SchedId rem tuple_size(Channels)) + 1, Channels).

%% @doc List all active worker pools.
-spec list_pools() -> [#{mount_id := binary(), pid := pid()}].
list_pools() ->
    Children = supervisor:which_children(?SERVER),
    lists:filtermap(fun
        ({{hornbeam_worker_arbiter, MountId}, Pid, worker, _}) when is_pid(Pid) ->
            {true, #{mount_id => MountId, pid => Pid}};
        (_) ->
            false
    end, Children).

%%% ============================================================================
%%% supervisor callbacks
%%% ============================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    %% Start with no children - mounts are added dynamically
    {ok, {SupFlags, []}}.
