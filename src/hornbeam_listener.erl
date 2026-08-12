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

%%% @doc Supervised owner of the livery HTTP service.
%%%
%%% `livery:start_service/1' links the service to its caller, so the
%%% service must be started from a supervised process rather than from
%%% whichever process calls `hornbeam:start/2' (a shell or a test case).
%%% This gen_server owns the service pid and exposes start/stop/info.
-module(hornbeam_listener).

-behaviour(gen_server).

-export([start_link/0]).
-export([start_service/1, stop_service/0, info/0, is_running/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

%% @doc Start the livery service with the given service opts.
-spec start_service(map()) -> ok | {error, term()}.
start_service(ServiceOpts) ->
    gen_server:call(?SERVER, {start_service, ServiceOpts}, infinity).

%% @doc Stop the running livery service. Idempotent.
-spec stop_service() -> ok.
stop_service() ->
    gen_server:call(?SERVER, stop_service, infinity).

%% @doc Listener status: `#{running := boolean(), listeners := map()}'.
-spec info() -> #{running := boolean(), listeners := map()}.
info() ->
    gen_server:call(?SERVER, info).

-spec is_running() -> boolean().
is_running() ->
    maps:get(running, info()).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% gen_server callbacks

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{service => undefined}}.

handle_call({start_service, _Opts}, _From, #{service := Pid} = State)
        when is_pid(Pid) ->
    {reply, {error, already_started}, State};
handle_call({start_service, Opts}, _From, State) ->
    case livery:start_service(Opts) of
        {ok, Pid} ->
            {reply, ok, State#{service := Pid}};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(stop_service, _From, #{service := Pid} = State) when is_pid(Pid) ->
    ok = livery:stop_service(Pid),
    {reply, ok, State#{service := undefined}};
handle_call(stop_service, _From, State) ->
    {reply, ok, State};
handle_call(info, _From, #{service := Pid} = State) when is_pid(Pid) ->
    Listeners =
        try livery:which_listeners(Pid)
        catch _:_ -> #{}
        end,
    {reply, #{running => true, listeners => Listeners}, State};
handle_call(info, _From, State) ->
    {reply, #{running => false, listeners => #{}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #{service := Pid} = State) ->
    case Reason of
        normal -> ok;
        shutdown -> ok;
        _ ->
            error_logger:error_msg("hornbeam listener service exited: ~p~n",
                                   [Reason])
    end,
    {noreply, State#{service := undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

%% livery:stop_service/1 is synchronous (livery >= 0.7.0): it closes the
%% listen socket, the acceptors, and every accepted connection before
%% returning, so nothing is left serving the stopped service.
terminate(_Reason, #{service := Pid}) when is_pid(Pid) ->
    try livery:stop_service(Pid)
    catch _:_ -> ok
    end,
    ok;
terminate(_Reason, _State) ->
    ok.
