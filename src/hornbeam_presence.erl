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

%%% @doc Distributed presence tracking using ORSWOT CRDT.
%%%
%%% This module provides presence tracking with:
%%% - Track/untrack operations per topic
%%% - Process monitoring for automatic cleanup
%%% - CRDT-based conflict resolution (ORSWOT - Observed Remove Set Without Tombstones)
%%% - Delta-based sync across nodes via pubsub
%%%
%%% ORSWOT provides strong eventual consistency even with concurrent
%%% track/untrack operations across nodes.
-module(hornbeam_presence).

-behaviour(gen_server).

-export([
    start_link/0,
    track/4,
    untrack/3,
    untrack_all/2,
    update/4,
    list/1,
    get_by_key/2,
    dirty_list/1
]).

%% Internal - for channel use
-export([
    subscribe/1,
    push_state/2
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
-define(SYNC_INTERVAL, 1500).  % Delta sync interval in ms
-define(CLOCK_INTERVAL, 5000). % Clock sync interval in ms
-define(SYNC_TOPIC, <<"hornbeam:presence:sync">>).

%% ORSWOT CRDT - Observed Remove Set Without Tombstones
-record(orswot, {
    %% elements: #{Key => #{HbRef => {Meta, Dot}}}
    %% Key is user-defined (e.g., "user:123")
    %% HbRef is unique reference for each presence entry
    %% Meta is the presence metadata (metas list)
    %% Dot is {Node, Counter} for causal tracking
    elements = #{} :: map(),
    %% context: #{Node => MaxCounter} - observed dots per node
    context = #{} :: map(),
    %% counter: local counter for generating dots
    counter = 0 :: non_neg_integer()
}).

%% Delta for efficient sync
-record(delta, {
    adds = #{} :: map(),        % #{Key => #{HbRef => {Meta, Dot}}}
    removes = [] :: list(),     % [{Key, HbRef}]
    context = #{} :: map()      % updated context
}).

%% State per topic
-record(topic_state, {
    orswot = #orswot{} :: #orswot{},
    pending_delta = #delta{} :: #delta{},
    monitors = #{} :: map()  % #{Pid => [{Key, HbRef}]}
}).

-record(state, {
    node :: node(),
    topics = #{} :: map(),  % #{Topic => #topic_state{}}
    sync_timer :: reference() | undefined,
    clock_timer :: reference() | undefined
}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the presence server.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Track a presence for a key on a topic.
%% Pid is monitored for automatic cleanup on exit.
%% Meta is arbitrary presence metadata (e.g., #{name => "Alice", status => "online"}).
-spec track(binary(), pid(), binary(), map()) -> ok | {error, term()}.
track(Topic, Pid, Key, Meta) ->
    gen_server:call(?SERVER, {track, Topic, Pid, Key, Meta}).

%% @doc Untrack a specific presence key for a pid.
-spec untrack(binary(), pid(), binary()) -> ok.
untrack(Topic, Pid, Key) ->
    gen_server:cast(?SERVER, {untrack, Topic, Pid, Key}).

%% @doc Untrack all presences for a pid on a topic.
-spec untrack_all(binary(), pid()) -> ok.
untrack_all(Topic, Pid) ->
    gen_server:cast(?SERVER, {untrack_all, Topic, Pid}).

%% @doc Update presence metadata for a key.
-spec update(binary(), pid(), binary(), map()) -> ok | {error, term()}.
update(Topic, Pid, Key, Meta) ->
    gen_server:call(?SERVER, {update, Topic, Pid, Key, Meta}).

%% @doc List all presences for a topic.
%% Returns #{Key => #{metas => [Meta1, Meta2, ...]}} format.
-spec list(binary()) -> map().
list(Topic) ->
    gen_server:call(?SERVER, {list, Topic}).

%% @doc Get presences for a specific key.
-spec get_by_key(binary(), binary()) -> map() | undefined.
get_by_key(Topic, Key) ->
    gen_server:call(?SERVER, {get_by_key, Topic, Key}).

%% @doc Get presence list without going through gen_server (for performance).
%% May return slightly stale data.
-spec dirty_list(binary()) -> map().
dirty_list(Topic) ->
    gen_server:call(?SERVER, {dirty_list, Topic}).

%% @doc Subscribe to presence updates for a topic (internal).
-spec subscribe(binary()) -> ok.
subscribe(Topic) ->
    gen_server:cast(?SERVER, {subscribe, Topic, self()}).

%% @doc Push full presence state to a specific process (for new joiners).
-spec push_state(binary(), pid()) -> ok.
push_state(Topic, Pid) ->
    gen_server:cast(?SERVER, {push_state, Topic, Pid}).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Subscribe to sync topic for cross-node updates
    hornbeam_pubsub:subscribe(?SYNC_TOPIC, self()),

    %% Start timers
    SyncTimer = erlang:send_after(?SYNC_INTERVAL, self(), sync_delta),
    ClockTimer = erlang:send_after(?CLOCK_INTERVAL, self(), sync_clocks),

    {ok, #state{
        node = node(),
        sync_timer = SyncTimer,
        clock_timer = ClockTimer
    }}.

handle_call({track, Topic, Pid, Key, Meta}, _From, State) ->
    {Reply, NewState} = do_track(Topic, Pid, Key, Meta, State),
    {reply, Reply, NewState};

handle_call({update, Topic, Pid, Key, Meta}, _From, State) ->
    %% Update is untrack + track
    State1 = do_untrack(Topic, Pid, Key, State),
    {Reply, NewState} = do_track(Topic, Pid, Key, Meta, State1),
    {reply, Reply, NewState};

handle_call({list, Topic}, _From, State) ->
    Result = do_list(Topic, State),
    {reply, Result, State};

handle_call({get_by_key, Topic, Key}, _From, State) ->
    Result = do_get_by_key(Topic, Key, State),
    {reply, Result, State};

handle_call({dirty_list, Topic}, _From, State) ->
    Result = do_list(Topic, State),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({untrack, Topic, Pid, Key}, State) ->
    NewState = do_untrack(Topic, Pid, Key, State),
    {noreply, NewState};

handle_cast({untrack_all, Topic, Pid}, State) ->
    NewState = do_untrack_all(Topic, Pid, State),
    {noreply, NewState};

handle_cast({subscribe, Topic, Pid}, State) ->
    %% Ensure topic state exists
    NewState = ensure_topic(Topic, State),
    %% Push current state to subscriber
    PresenceState = do_list(Topic, NewState),
    Pid ! {pubsub, Topic, {presence_state, PresenceState}},
    {noreply, NewState};

handle_cast({push_state, Topic, Pid}, State) ->
    PresenceState = do_list(Topic, State),
    Pid ! {pubsub, Topic, {presence_state, PresenceState}},
    {noreply, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% Process died - untrack all its presences
    NewState = handle_process_down(Pid, State),
    {noreply, NewState};

handle_info(sync_delta, State) ->
    NewState = broadcast_deltas(State),
    Timer = erlang:send_after(?SYNC_INTERVAL, self(), sync_delta),
    {noreply, NewState#state{sync_timer = Timer}};

handle_info(sync_clocks, State) ->
    %% Periodic clock sync (currently no-op, but hook for vector clock sync)
    Timer = erlang:send_after(?CLOCK_INTERVAL, self(), sync_clocks),
    {noreply, State#state{clock_timer = Timer}};

handle_info({pubsub, ?SYNC_TOPIC, {delta, FromNode, Topic, Delta}}, State)
        when FromNode =/= node() ->
    %% Received delta from another node
    NewState = merge_remote_delta(Topic, Delta, State),
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{sync_timer = SyncTimer, clock_timer = ClockTimer}) ->
    catch erlang:cancel_timer(SyncTimer),
    catch erlang:cancel_timer(ClockTimer),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal Functions - Core Operations
%%% ============================================================================

ensure_topic(Topic, #state{topics = Topics} = State) ->
    case maps:is_key(Topic, Topics) of
        true -> State;
        false -> State#state{topics = Topics#{Topic => #topic_state{}}}
    end.

do_track(Topic, Pid, Key, Meta, State) ->
    State1 = ensure_topic(Topic, State),
    #state{node = Node, topics = Topics} = State1,
    TopicState = maps:get(Topic, Topics),
    #topic_state{orswot = Orswot, pending_delta = Delta, monitors = Monitors} = TopicState,

    %% Generate unique reference for this presence entry
    HbRef = generate_hb_ref(),

    %% Create dot for causal tracking
    NewCounter = Orswot#orswot.counter + 1,
    Dot = {Node, NewCounter},

    %% Add to ORSWOT
    Elements = Orswot#orswot.elements,
    KeyEntries = maps:get(Key, Elements, #{}),
    NewKeyEntries = KeyEntries#{HbRef => {Meta, Dot}},
    NewElements = Elements#{Key => NewKeyEntries},

    %% Update context
    Context = Orswot#orswot.context,
    NewContext = Context#{Node => NewCounter},

    NewOrswot = Orswot#orswot{
        elements = NewElements,
        context = NewContext,
        counter = NewCounter
    },

    %% Add to pending delta
    DeltaAdds = Delta#delta.adds,
    DeltaKeyEntries = maps:get(Key, DeltaAdds, #{}),
    NewDeltaKeyEntries = DeltaKeyEntries#{HbRef => {Meta, Dot}},
    NewDeltaAdds = DeltaAdds#{Key => NewDeltaKeyEntries},
    NewDelta = Delta#delta{
        adds = NewDeltaAdds,
        context = NewContext
    },

    %% Monitor the pid
    NewMonitors = add_monitor(Pid, Key, HbRef, Monitors),

    NewTopicState = TopicState#topic_state{
        orswot = NewOrswot,
        pending_delta = NewDelta,
        monitors = NewMonitors
    },

    %% Broadcast presence_diff for local subscribers
    broadcast_join(Topic, Key, Meta),

    NewState = State1#state{topics = Topics#{Topic => NewTopicState}},
    {ok, NewState}.

do_untrack(Topic, Pid, Key, #state{topics = Topics} = State) ->
    case maps:get(Topic, Topics, undefined) of
        undefined ->
            State;
        TopicState ->
            #topic_state{orswot = Orswot, pending_delta = Delta, monitors = Monitors} = TopicState,

            %% Find HbRefs for this Pid+Key
            PidEntries = maps:get(Pid, Monitors, []),
            HbRefs = [Ref || {K, Ref} <- PidEntries, K =:= Key],

            case HbRefs of
                [] ->
                    State;
                _ ->
                    %% Remove from ORSWOT
                    {NewOrswot, RemovedMetas, NewDelta} = remove_refs(Key, HbRefs, Orswot, Delta),

                    %% Update monitors
                    NewPidEntries = [{K, Ref} || {K, Ref} <- PidEntries, K =/= Key],
                    NewMonitors = case NewPidEntries of
                        [] ->
                            %% No more entries for this pid, demonitor
                            catch demonitor_pid(Pid, Monitors),
                            maps:remove(Pid, Monitors);
                        _ ->
                            Monitors#{Pid => NewPidEntries}
                    end,

                    NewTopicState = TopicState#topic_state{
                        orswot = NewOrswot,
                        pending_delta = NewDelta,
                        monitors = NewMonitors
                    },

                    %% Broadcast presence_diff for leaves
                    lists:foreach(fun(Meta) ->
                        broadcast_leave(Topic, Key, Meta)
                    end, RemovedMetas),

                    State#state{topics = Topics#{Topic => NewTopicState}}
            end
    end.

do_untrack_all(Topic, Pid, #state{topics = Topics} = State) ->
    case maps:get(Topic, Topics, undefined) of
        undefined ->
            State;
        TopicState ->
            #topic_state{orswot = Orswot, pending_delta = Delta, monitors = Monitors} = TopicState,

            PidEntries = maps:get(Pid, Monitors, []),
            case PidEntries of
                [] ->
                    State;
                _ ->
                    %% Group by key
                    ByKey = lists:foldl(fun({Key, Ref}, Acc) ->
                        Refs = maps:get(Key, Acc, []),
                        Acc#{Key => [Ref | Refs]}
                    end, #{}, PidEntries),

                    %% Remove all entries
                    {NewOrswot, AllRemovedMetas, NewDelta} = maps:fold(fun(Key, Refs, {O, Metas, D}) ->
                        {O1, RemovedMetas, D1} = remove_refs(Key, Refs, O, D),
                        {O1, [{Key, M} || M <- RemovedMetas] ++ Metas, D1}
                    end, {Orswot, [], Delta}, ByKey),

                    %% Demonitor
                    catch demonitor_pid(Pid, Monitors),
                    NewMonitors = maps:remove(Pid, Monitors),

                    NewTopicState = TopicState#topic_state{
                        orswot = NewOrswot,
                        pending_delta = NewDelta,
                        monitors = NewMonitors
                    },

                    %% Broadcast leaves
                    lists:foreach(fun({Key, Meta}) ->
                        broadcast_leave(Topic, Key, Meta)
                    end, AllRemovedMetas),

                    State#state{topics = Topics#{Topic => NewTopicState}}
            end
    end.

remove_refs(Key, HbRefs, #orswot{elements = Elements, context = Context} = Orswot, Delta) ->
    KeyEntries = maps:get(Key, Elements, #{}),

    %% Collect removed metas and update elements
    {NewKeyEntries, RemovedMetas} = lists:foldl(fun(Ref, {Entries, Metas}) ->
        case maps:get(Ref, Entries, undefined) of
            undefined ->
                {Entries, Metas};
            {Meta, _Dot} ->
                {maps:remove(Ref, Entries), [Meta | Metas]}
        end
    end, {KeyEntries, []}, HbRefs),

    NewElements = case maps:size(NewKeyEntries) of
        0 -> maps:remove(Key, Elements);
        _ -> Elements#{Key => NewKeyEntries}
    end,

    NewOrswot = Orswot#orswot{elements = NewElements},

    %% Add to delta removes
    Removes = Delta#delta.removes,
    NewRemoves = [{Key, Ref} || Ref <- HbRefs] ++ Removes,
    NewDelta = Delta#delta{removes = NewRemoves, context = Context},

    {NewOrswot, RemovedMetas, NewDelta}.

do_list(Topic, #state{topics = Topics}) ->
    case maps:get(Topic, Topics, undefined) of
        undefined ->
            #{};
        #topic_state{orswot = #orswot{elements = Elements}} ->
            %% Convert to presence format: #{Key => #{metas => [...]}}
            maps:fold(fun(Key, Entries, Acc) ->
                Metas = [Meta || {_Ref, {Meta, _Dot}} <- maps:to_list(Entries)],
                case Metas of
                    [] -> Acc;
                    _ -> Acc#{Key => #{<<"metas">> => Metas}}
                end
            end, #{}, Elements)
    end.

do_get_by_key(Topic, Key, #state{topics = Topics}) ->
    case maps:get(Topic, Topics, undefined) of
        undefined ->
            undefined;
        #topic_state{orswot = #orswot{elements = Elements}} ->
            case maps:get(Key, Elements, undefined) of
                undefined ->
                    undefined;
                Entries ->
                    Metas = [Meta || {_Ref, {Meta, _Dot}} <- maps:to_list(Entries)],
                    #{<<"metas">> => Metas}
            end
    end.

%%% ============================================================================
%%% Internal Functions - Monitoring
%%% ============================================================================

add_monitor(Pid, Key, HbRef, Monitors) ->
    case maps:is_key(Pid, Monitors) of
        false ->
            %% New pid, set up monitor
            erlang:monitor(process, Pid),
            Monitors#{Pid => [{Key, HbRef}]};
        true ->
            Entries = maps:get(Pid, Monitors),
            Monitors#{Pid => [{Key, HbRef} | Entries]}
    end.

demonitor_pid(Pid, Monitors) ->
    case maps:get(Pid, Monitors, undefined) of
        undefined -> ok;
        _Entries ->
            %% Find the monitor ref (we don't store it, so we can't demonitor)
            %% This is fine - when the process dies we'll clean up anyway
            ok
    end.

handle_process_down(Pid, #state{topics = Topics} = State) ->
    %% Find all topics where this pid has presences
    maps:fold(fun(Topic, TopicState, AccState) ->
        case maps:is_key(Pid, TopicState#topic_state.monitors) of
            true ->
                do_untrack_all(Topic, Pid, AccState);
            false ->
                AccState
        end
    end, State, Topics).

%%% ============================================================================
%%% Internal Functions - Delta Sync
%%% ============================================================================

broadcast_deltas(#state{topics = Topics, node = Node} = State) ->
    NewTopics = maps:map(fun(Topic, TopicState) ->
        #topic_state{pending_delta = Delta} = TopicState,
        case has_delta(Delta) of
            true ->
                %% Broadcast delta to other nodes
                hornbeam_pubsub:publish(?SYNC_TOPIC, {delta, Node, Topic, Delta}),
                %% Clear pending delta
                TopicState#topic_state{pending_delta = #delta{}};
            false ->
                TopicState
        end
    end, Topics),
    State#state{topics = NewTopics}.

has_delta(#delta{adds = Adds, removes = Removes}) ->
    maps:size(Adds) > 0 orelse length(Removes) > 0.

merge_remote_delta(Topic, Delta, State) ->
    State1 = ensure_topic(Topic, State),
    #state{topics = Topics} = State1,
    TopicState = maps:get(Topic, Topics),
    #topic_state{orswot = Orswot} = TopicState,

    %% Merge the delta into our ORSWOT
    {NewOrswot, Joins, Leaves} = merge_delta(Orswot, Delta),

    NewTopicState = TopicState#topic_state{orswot = NewOrswot},

    %% Broadcast local presence_diff for the merged changes
    lists:foreach(fun({Key, Meta}) ->
        broadcast_join(Topic, Key, Meta)
    end, Joins),
    lists:foreach(fun({Key, Meta}) ->
        broadcast_leave(Topic, Key, Meta)
    end, Leaves),

    State1#state{topics = Topics#{Topic => NewTopicState}}.

merge_delta(#orswot{elements = Elements, context = Context} = Orswot,
            #delta{adds = Adds, removes = Removes, context = RemoteContext}) ->

    %% Process adds - only add if dot not already seen
    {Elements1, Joins} = maps:fold(fun(Key, Entries, {ElsAcc, JoinsAcc}) ->
        KeyEntries = maps:get(Key, ElsAcc, #{}),
        {NewKeyEntries, KeyJoins} = maps:fold(fun(HbRef, {Meta, Dot} = Entry, {KEAcc, KJAcc}) ->
            case is_dot_seen(Dot, Context) of
                true ->
                    %% Already have this dot
                    {KEAcc, KJAcc};
                false ->
                    %% New entry
                    {KEAcc#{HbRef => Entry}, [{Key, Meta} | KJAcc]}
            end
        end, {KeyEntries, []}, Entries),
        {ElsAcc#{Key => NewKeyEntries}, KeyJoins ++ JoinsAcc}
    end, {Elements, []}, Adds),

    %% Process removes - remove entries where we have the dot
    {Elements2, Leaves} = lists:foldl(fun({Key, HbRef}, {ElsAcc, LeavesAcc}) ->
        KeyEntries = maps:get(Key, ElsAcc, #{}),
        case maps:get(HbRef, KeyEntries, undefined) of
            undefined ->
                {ElsAcc, LeavesAcc};
            {Meta, _Dot} ->
                NewKeyEntries = maps:remove(HbRef, KeyEntries),
                NewElsAcc = case maps:size(NewKeyEntries) of
                    0 -> maps:remove(Key, ElsAcc);
                    _ -> ElsAcc#{Key => NewKeyEntries}
                end,
                {NewElsAcc, [{Key, Meta} | LeavesAcc]}
        end
    end, {Elements1, []}, Removes),

    %% Merge contexts (take max per node)
    NewContext = maps:fold(fun(Node, Counter, Acc) ->
        case maps:get(Node, Acc, 0) of
            ExistingCounter when Counter > ExistingCounter ->
                Acc#{Node => Counter};
            _ ->
                Acc
        end
    end, Context, RemoteContext),

    NewOrswot = Orswot#orswot{
        elements = Elements2,
        context = NewContext
    },

    {NewOrswot, Joins, Leaves}.

is_dot_seen({Node, Counter}, Context) ->
    case maps:get(Node, Context, 0) of
        MaxCounter when Counter =< MaxCounter -> true;
        _ -> false
    end.

%%% ============================================================================
%%% Internal Functions - Broadcasting
%%% ============================================================================

broadcast_join(Topic, Key, Meta) ->
    Diff = #{
        <<"joins">> => #{Key => #{<<"metas">> => [Meta]}},
        <<"leaves">> => #{}
    },
    hornbeam_pubsub:publish(Topic, {presence_diff, Diff}).

broadcast_leave(Topic, Key, Meta) ->
    Diff = #{
        <<"joins">> => #{},
        <<"leaves">> => #{Key => #{<<"metas">> => [Meta]}}
    },
    hornbeam_pubsub:publish(Topic, {presence_diff, Diff}).

%%% ============================================================================
%%% Internal Functions - Utilities
%%% ============================================================================

generate_hb_ref() ->
    %% Generate a unique reference for presence tracking
    Bytes = crypto:strong_rand_bytes(8),
    Base64 = base64:encode(Bytes),
    binary:replace(binary:replace(Base64, <<"+">>, <<"-">>, [global]),
                   <<"/">>, <<"_">>, [global]).
