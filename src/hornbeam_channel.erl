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

%%% @doc Per-connection channel process.
%%%
%%% Manages channels for a single WebSocket connection.
%%% Handles the channel protocol message format:
%%% `[join_ref, ref, topic, event, payload]'
%%%
%%% Reserved events:
%%% - hb_join: Join a channel topic
%%% - hb_leave: Leave a channel topic
%%% - hb_reply: Reply to a client push
%%% - presence_state: Full presence state
%%% - presence_diff: Presence diff (joins/leaves)
%%% - heartbeat: Keep-alive
-module(hornbeam_channel).

-behaviour(gen_server).

-export([
    start_link/2,
    handle_message/2,
    push/4,
    reply/5,
    broadcast/3,
    broadcast_from/4,
    get_socket/1,
    assign/3,
    get_assigns/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    socket_pid :: pid(),               % WebSocket process
    session_id :: binary(),            % Session identifier
    assigns = #{} :: map(),            % User-defined socket assigns
    joined_topics = #{} :: map(),      % topic => {join_ref, handler_state}
    pending_refs = #{} :: map(),       % ref => {join_ref, topic, from}
    ref_counter = 0 :: non_neg_integer()
}).

-record(socket, {
    channel_pid :: pid(),
    session_id :: binary(),
    topic :: binary() | undefined,
    join_ref :: binary() | undefined,
    assigns :: map()
}).

-define(HEARTBEAT_EVENT, <<"heartbeat">>).
-define(HB_JOIN, <<"hb_join">>).
-define(HB_LEAVE, <<"hb_leave">>).
-define(HB_REPLY, <<"hb_reply">>).
-define(HB_ERROR, <<"hb_error">>).
-define(HB_CLOSE, <<"hb_close">>).
-define(PRESENCE_STATE, <<"presence_state">>).
-define(PRESENCE_DIFF, <<"presence_diff">>).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start a channel process for a WebSocket connection.
-spec start_link(pid(), binary()) -> {ok, pid()} | {error, term()}.
start_link(SocketPid, SessionId) ->
    gen_server:start_link(?MODULE, [SocketPid, SessionId], []).

%% @doc Handle an incoming channel protocol message.
%% Message format: [join_ref, ref, topic, event, payload]
-spec handle_message(pid(), list() | map()) -> ok.
handle_message(Pid, Message) ->
    gen_server:cast(Pid, {message, Message}).

%% @doc Push a message to the client.
-spec push(pid(), binary(), binary(), map()) -> ok.
push(Pid, Topic, Event, Payload) ->
    gen_server:cast(Pid, {push, Topic, Event, Payload}).

%% @doc Send a reply to a client push.
-spec reply(pid(), binary(), binary(), binary(), map()) -> ok.
reply(Pid, JoinRef, Ref, Topic, Response) ->
    gen_server:cast(Pid, {reply, JoinRef, Ref, Topic, Response}).

%% @doc Broadcast a message to all subscribers of a topic.
-spec broadcast(binary(), binary(), map()) -> ok.
broadcast(Topic, Event, Payload) ->
    hornbeam_pubsub:publish(Topic, {channel_broadcast, Event, Payload}),
    ok.

%% @doc Broadcast a message to all subscribers except the sender.
-spec broadcast_from(pid(), binary(), binary(), map()) -> ok.
broadcast_from(SenderPid, Topic, Event, Payload) ->
    hornbeam_pubsub:publish(Topic, {channel_broadcast_from, SenderPid, Event, Payload}),
    ok.

%% @doc Get the socket record for a channel.
-spec get_socket(pid()) -> #socket{}.
get_socket(Pid) ->
    gen_server:call(Pid, get_socket).

%% @doc Assign a value to the socket.
-spec assign(pid(), term(), term()) -> ok.
assign(Pid, Key, Value) ->
    gen_server:cast(Pid, {assign, Key, Value}).

%% @doc Get all assigns from the socket.
-spec get_assigns(pid()) -> map().
get_assigns(Pid) ->
    gen_server:call(Pid, get_assigns).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([SocketPid, SessionId]) ->
    %% Monitor the WebSocket process
    erlang:monitor(process, SocketPid),
    {ok, #state{
        socket_pid = SocketPid,
        session_id = SessionId
    }}.

handle_call(get_socket, _From, State) ->
    Socket = make_socket(State, undefined, undefined),
    {reply, Socket, State};

handle_call(get_assigns, _From, #state{assigns = Assigns} = State) ->
    {reply, Assigns, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({message, Message}, State) ->
    NewState = do_handle_message(Message, State),
    {noreply, NewState};

handle_cast({push, Topic, Event, Payload}, State) ->
    do_push(State, null, null, Topic, Event, Payload),
    {noreply, State};

handle_cast({reply, JoinRef, Ref, Topic, Response}, State) ->
    do_reply(State, JoinRef, Ref, Topic, Response),
    {noreply, State};

handle_cast({assign, Key, Value}, #state{assigns = Assigns} = State) ->
    {noreply, State#state{assigns = Assigns#{Key => Value}}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({pubsub, Topic, {channel_broadcast, Event, Payload}}, State) ->
    %% Received a broadcast - forward to client if joined
    case maps:is_key(Topic, State#state.joined_topics) of
        true ->
            do_push(State, null, null, Topic, Event, Payload);
        false ->
            ok
    end,
    {noreply, State};

handle_info({pubsub, Topic, {channel_broadcast_from, SenderChannelPid, Event, Payload}},
            State) ->
    %% Received a broadcast_from - forward only if not the sender
    case SenderChannelPid =:= self() of
        true ->
            ok;  % Don't send to ourselves
        false ->
            case maps:is_key(Topic, State#state.joined_topics) of
                true ->
                    do_push(State, null, null, Topic, Event, Payload);
                false ->
                    ok
            end
    end,
    {noreply, State};

handle_info({pubsub, Topic, {presence_state, PresenceState}}, State) ->
    case maps:is_key(Topic, State#state.joined_topics) of
        true ->
            do_push(State, null, null, Topic, ?PRESENCE_STATE, PresenceState);
        false ->
            ok
    end,
    {noreply, State};

handle_info({pubsub, Topic, {presence_diff, Diff}}, State) ->
    case maps:is_key(Topic, State#state.joined_topics) of
        true ->
            do_push(State, null, null, Topic, ?PRESENCE_DIFF, Diff);
        false ->
            ok
    end,
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{socket_pid = Pid} = State) ->
    %% WebSocket died, clean up
    _ = cleanup_joins(State),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = cleanup_joins(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

do_handle_message(Message, State) when is_list(Message), length(Message) =:= 5 ->
    [JoinRef, Ref, Topic, Event, Payload] = Message,
    handle_event(JoinRef, Ref, Topic, Event, Payload, State);
do_handle_message(Message, State) when is_map(Message) ->
    %% Also support map format for flexibility
    JoinRef = maps:get(<<"join_ref">>, Message, null),
    Ref = maps:get(<<"ref">>, Message, null),
    Topic = maps:get(<<"topic">>, Message, <<>>),
    Event = maps:get(<<"event">>, Message, <<>>),
    Payload = maps:get(<<"payload">>, Message, #{}),
    handle_event(JoinRef, Ref, Topic, Event, Payload, State);
do_handle_message(_Message, State) ->
    %% Invalid message format
    State.

handle_event(_JoinRef, Ref, <<"hornbeam">>, ?HEARTBEAT_EVENT, _Payload, State) ->
    %% Heartbeat - reply immediately
    do_reply(State, null, Ref, <<"hornbeam">>, #{<<"status">> => <<"ok">>, <<"response">> => #{}}),
    State;

handle_event(JoinRef, Ref, Topic, ?HB_JOIN, Payload, State) ->
    handle_join(JoinRef, Ref, Topic, Payload, State);

handle_event(JoinRef, Ref, Topic, ?HB_LEAVE, _Payload, State) ->
    handle_leave(JoinRef, Ref, Topic, State);

handle_event(_JoinRef, Ref, Topic, Event, Payload, State) ->
    %% Regular event - dispatch to handler
    handle_incoming(Ref, Topic, Event, Payload, State).

handle_join(JoinRef, Ref, Topic, Payload, #state{joined_topics = Joined} = State) ->
    case maps:is_key(Topic, Joined) of
        true ->
            %% Already joined this topic
            do_reply(State, JoinRef, Ref, Topic, #{
                <<"status">> => <<"error">>,
                <<"response">> => #{<<"reason">> => <<"already joined">>}
            }),
            State;
        false ->
            %% Find handler for this topic
            case hornbeam_channel_registry:find_handler(Topic) of
                {ok, HandlerInfo} ->
                    Socket = make_socket(State, Topic, JoinRef),
                    case call_join_handler(HandlerInfo, Topic, Payload, Socket) of
                        {ok, Response, NewSocket} ->
                            %% Subscribe to topic for broadcasts
                            hornbeam_pubsub:subscribe(Topic, self()),
                            %% Send success reply
                            do_reply(State, JoinRef, Ref, Topic, #{
                                <<"status">> => <<"ok">>,
                                <<"response">> => Response
                            }),
                            %% Send initial presence state to the new joiner
                            hornbeam_presence:push_state(Topic, self()),
                            %% Update state
                            HandlerState = #{
                                handler => HandlerInfo,
                                socket => NewSocket
                            },
                            NewJoined = Joined#{Topic => {JoinRef, HandlerState}},
                            State#state{
                                joined_topics = NewJoined,
                                assigns = NewSocket#socket.assigns
                            };
                        {error, Reason} ->
                            do_reply(State, JoinRef, Ref, Topic, #{
                                <<"status">> => <<"error">>,
                                <<"response">> => Reason
                            }),
                            State
                    end;
                {error, no_handler} ->
                    do_reply(State, JoinRef, Ref, Topic, #{
                        <<"status">> => <<"error">>,
                        <<"response">> => #{<<"reason">> => <<"no handler for topic">>}
                    }),
                    State
            end
    end.

handle_leave(JoinRef, Ref, Topic, #state{joined_topics = Joined} = State) ->
    case maps:get(Topic, Joined, undefined) of
        undefined ->
            %% Not joined
            do_reply(State, JoinRef, Ref, Topic, #{
                <<"status">> => <<"error">>,
                <<"response">> => #{<<"reason">> => <<"not joined">>}
            }),
            State;
        {_StoredJoinRef, HandlerState} ->
            %% Call leave handler
            #{handler := HandlerInfo, socket := Socket} = HandlerState,
            call_leave_handler(HandlerInfo, Topic, Socket),
            %% Unsubscribe from topic
            hornbeam_pubsub:unsubscribe(Topic, self()),
            %% Notify presence if tracked
            hornbeam_presence:untrack_all(Topic, self()),
            %% Send reply
            do_reply(State, JoinRef, Ref, Topic, #{
                <<"status">> => <<"ok">>,
                <<"response">> => #{}
            }),
            State#state{joined_topics = maps:remove(Topic, Joined)}
    end.

handle_incoming(Ref, Topic, Event, Payload, #state{joined_topics = Joined} = State) ->
    case maps:get(Topic, Joined, undefined) of
        undefined ->
            %% Not joined - ignore
            State;
        {JoinRef, HandlerState} ->
            #{handler := HandlerInfo, socket := Socket} = HandlerState,
            case call_event_handler(HandlerInfo, Event, Payload, Socket) of
                {reply, Response, NewSocket} ->
                    do_reply(State, JoinRef, Ref, Topic, #{
                        <<"status">> => <<"ok">>,
                        <<"response">> => Response
                    }),
                    update_handler_state(Topic, JoinRef, HandlerInfo, NewSocket, State);
                {noreply, NewSocket} ->
                    update_handler_state(Topic, JoinRef, HandlerInfo, NewSocket, State);
                {stop, Reason, NewSocket} ->
                    %% Stop the channel for this topic
                    do_reply(State, JoinRef, Ref, Topic, #{
                        <<"status">> => <<"error">>,
                        <<"response">> => #{<<"reason">> => Reason}
                    }),
                    hornbeam_pubsub:unsubscribe(Topic, self()),
                    hornbeam_presence:untrack_all(Topic, self()),
                    State#state{
                        joined_topics = maps:remove(Topic, State#state.joined_topics),
                        assigns = NewSocket#socket.assigns
                    }
            end
    end.

update_handler_state(Topic, JoinRef, HandlerInfo, NewSocket, State) ->
    NewHandlerState = #{
        handler => HandlerInfo,
        socket => NewSocket
    },
    NewJoined = (State#state.joined_topics)#{Topic => {JoinRef, NewHandlerState}},
    State#state{
        joined_topics = NewJoined,
        assigns = NewSocket#socket.assigns
    }.

call_join_handler(HandlerInfo, Topic, Payload, Socket) ->
    %% Parse topic params (e.g., "room:123" -> #{<<"room_id">> => <<"123">>})
    TopicParams = hornbeam_channel_registry:parse_topic_params(HandlerInfo, Topic),
    %% Convert socket to map for Python compatibility
    SocketData = socket_to_map(Socket),
    case hornbeam_channel_registry:call_handler(HandlerInfo, join, [Topic, TopicParams, Payload, SocketData]) of
        %% Atom results (from Erlang handlers)
        {ok, Response, RetSocketMap} when is_map(RetSocketMap) ->
            {ok, Response, map_to_socket(RetSocketMap, Socket)};
        {ok, Response} ->
            {ok, Response, Socket};
        {error, Reason} ->
            {error, Reason};
        %% Binary results (from Python handlers) - with presence ops
        {<<"ok">>, Response, RetSocketMap, PresenceOps} when is_map(RetSocketMap), is_list(PresenceOps) ->
            process_presence_ops(Topic, PresenceOps),
            {ok, Response, map_to_socket(RetSocketMap, Socket)};
        %% Binary results (from Python handlers) - without presence ops (legacy)
        {<<"ok">>, Response, RetSocketMap} when is_map(RetSocketMap) ->
            {ok, Response, map_to_socket(RetSocketMap, Socket)};
        {<<"ok">>, Response} ->
            {ok, Response, Socket};
        {<<"error">>, Reason} ->
            {error, Reason};
        Error ->
            {error, #{<<"reason">> => iolist_to_binary(io_lib:format("~p", [Error]))}}
    end.

call_leave_handler(HandlerInfo, Topic, Socket) ->
    catch hornbeam_channel_registry:call_handler(HandlerInfo, leave, [Topic, Socket]),
    ok.

call_event_handler(HandlerInfo, Event, Payload, Socket) ->
    %% Convert socket to map for Python compatibility
    SocketData = socket_to_map(Socket),
    Result = hornbeam_channel_registry:call_handler(HandlerInfo, event, [Event, Payload, SocketData]),
    case Result of
        %% Atom results (from Erlang handlers)
        {reply, Response, RetSocketMap} when is_map(RetSocketMap) ->
            {reply, Response, map_to_socket(RetSocketMap, Socket)};
        {reply, Response} ->
            {reply, Response, Socket};
        {noreply, RetSocketMap} when is_map(RetSocketMap) ->
            {noreply, map_to_socket(RetSocketMap, Socket)};
        noreply ->
            {noreply, Socket};
        {stop, Reason, RetSocketMap} when is_map(RetSocketMap) ->
            {stop, Reason, map_to_socket(RetSocketMap, Socket)};
        {stop, Reason} ->
            {stop, Reason, Socket};
        %% Binary results (from Python handlers) - with broadcasts list
        {<<"reply">>, Response, RetSocketMap, Broadcasts} when is_map(RetSocketMap), is_list(Broadcasts) ->
            process_broadcasts(Broadcasts),
            {reply, Response, map_to_socket(RetSocketMap, Socket)};
        {<<"noreply">>, RetSocketMap, Broadcasts} when is_map(RetSocketMap), is_list(Broadcasts) ->
            process_broadcasts(Broadcasts),
            {noreply, map_to_socket(RetSocketMap, Socket)};
        {<<"stop">>, Reason, RetSocketMap, Broadcasts} when is_map(RetSocketMap), is_list(Broadcasts) ->
            process_broadcasts(Broadcasts),
            {stop, Reason, map_to_socket(RetSocketMap, Socket)};
        %% Binary results (from Python handlers) - without broadcasts (legacy)
        {<<"reply">>, Response, RetSocketMap} when is_map(RetSocketMap) ->
            {reply, Response, map_to_socket(RetSocketMap, Socket)};
        {<<"reply">>, Response} ->
            {reply, Response, Socket};
        {<<"noreply">>, RetSocketMap} when is_map(RetSocketMap) ->
            {noreply, map_to_socket(RetSocketMap, Socket)};
        <<"noreply">> ->
            {noreply, Socket};
        {<<"stop">>, Reason, RetSocketMap} when is_map(RetSocketMap) ->
            {stop, Reason, map_to_socket(RetSocketMap, Socket)};
        {<<"stop">>, Reason} ->
            {stop, Reason, Socket};
        _ ->
            {noreply, Socket}
    end.

%% @doc Process broadcasts returned by Python handlers.
%% Erlang executes these after the Python call returns to avoid erlport re-entrancy.
process_broadcasts([]) ->
    ok;
process_broadcasts([Broadcast | Rest]) ->
    process_broadcast(Broadcast),
    process_broadcasts(Rest).

process_broadcast(#{<<"type">> := <<"broadcast">>, <<"topic">> := Topic,
                    <<"event">> := Event, <<"payload">> := Payload}) ->
    broadcast(Topic, Event, Payload);
process_broadcast(#{<<"type">> := <<"broadcast_from">>, <<"topic">> := Topic,
                    <<"event">> := Event, <<"payload">> := Payload}) ->
    %% Use self() as sender - the current channel process
    broadcast_from(self(), Topic, Event, Payload);
process_broadcast(_) ->
    ok.

%% @doc Process presence operations returned by Python handlers.
%% Erlang executes these after the Python call returns to avoid erlport re-entrancy.
process_presence_ops(_Topic, []) ->
    ok;
process_presence_ops(Topic, [Op | Rest]) ->
    _ = process_presence_op(Topic, Op),
    process_presence_ops(Topic, Rest).

process_presence_op(Topic, #{<<"op">> := <<"track">>, <<"key">> := Key, <<"meta">> := Meta}) ->
    %% Track presence using current channel process (self()) as the pid
    hornbeam_presence:track(Topic, self(), Key, Meta);
process_presence_op(Topic, #{<<"op">> := <<"untrack">>, <<"key">> := Key}) ->
    hornbeam_presence:untrack(Topic, self(), Key);
process_presence_op(_Topic, _) ->
    ok.

map_to_socket(Map, BaseSocket) when is_map(Map) ->
    Assigns = maps:get(<<"assigns">>, Map, maps:get(assigns, Map, BaseSocket#socket.assigns)),
    BaseSocket#socket{assigns = Assigns}.

make_socket(#state{session_id = SessionId, assigns = Assigns}, Topic, JoinRef) ->
    #socket{
        channel_pid = self(),
        session_id = SessionId,
        topic = Topic,
        join_ref = JoinRef,
        assigns = Assigns
    }.

socket_to_map(#socket{channel_pid = Pid, session_id = SessionId,
                      topic = Topic, join_ref = JoinRef, assigns = Assigns}) ->
    #{
        <<"channel_pid">> => Pid,
        <<"session_id">> => SessionId,
        <<"topic">> => Topic,
        <<"join_ref">> => JoinRef,
        <<"assigns">> => Assigns
    }.

do_push(#state{socket_pid = SocketPid}, JoinRef, Ref, Topic, Event, Payload) ->
    Message = [JoinRef, Ref, Topic, Event, Payload],
    Json = json:encode(Message),
    SocketPid ! {websocket_send, text, Json},
    ok.

do_reply(State, JoinRef, Ref, Topic, Response) ->
    do_push(State, JoinRef, Ref, Topic, ?HB_REPLY, Response).

cleanup_joins(#state{joined_topics = Joined} = State) ->
    maps:foreach(fun(Topic, {_JoinRef, HandlerState}) ->
        %% Call leave handler
        #{handler := HandlerInfo, socket := Socket} = HandlerState,
        catch call_leave_handler(HandlerInfo, Topic, Socket),
        %% Unsubscribe
        hornbeam_pubsub:unsubscribe(Topic, self()),
        %% Untrack presence
        catch hornbeam_presence:untrack_all(Topic, self())
    end, Joined),
    State#state{joined_topics = #{}}.
