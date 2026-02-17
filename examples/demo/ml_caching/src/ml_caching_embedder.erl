%% Copyright 2026 Benoit Chesneau
%% Licensed under the Apache License, Version 2.0

%%% @doc ML Caching Embedder - Loads embedding model from Erlang.
%%%
%%% This GenServer loads the sentence_transformers model directly from Erlang
%%% via py:call(embedding_app, init_app, []).
%%%
%%% This works because erlang_python 1.3.2 added a callback name registry that
%%% prevents torch's module introspection from seeing erlang.Function objects.
-module(ml_caching_embedder).

-behaviour(gen_server).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%% ============================================================================
%%% API
%%% ============================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    io:format("ML Caching: Loading embedding model from Erlang...~n", []),

    %% Add priv directory to Python path
    PrivDir = code:priv_dir(ml_caching),
    io:format("ML Caching: Adding ~s to Python path~n", [PrivDir]),
    AddPath = iolist_to_binary(io_lib:format(
        "import sys; sys.path.insert(0, '~s')", [PrivDir])),
    ok = py:exec(AddPath),

    %% Load model directly from Erlang - this works now because erlang_python 1.3.2
    %% prevents torch introspection from seeing erlang.Function objects
    case py:call(embedding_app, init_app, []) of
        {ok, <<"ok">>} ->
            io:format("ML Caching: Model loaded successfully~n", []);
        {ok, _} ->
            io:format("ML Caching: Model loaded~n", []);
        {error, Reason} ->
            io:format("ML Caching: Failed to load model: ~p~n", [Reason]),
            error({model_load_failed, Reason})
    end,

    %% Register embeddings hook to route through embedding_app module
    hornbeam_hooks:reg(<<"embeddings">>, fun handle_embed/3),

    io:format("ML Caching: Embedder ready~n", []),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Cleanup Python app
    catch py:call(embedding_app, close_app, []),
    %% Unregister hook
    hornbeam_hooks:unreg(<<"embeddings">>),
    io:format("ML Caching: Embedder terminated~n", []),
    ok.

%%% ============================================================================
%%% Hook Handler
%%% ============================================================================

handle_embed(<<"embed">>, [Texts], _Kwargs) ->
    case py:call(embedding_app, embed, [Texts]) of
        {ok, Embeddings} -> Embeddings;
        {error, Reason} -> {error, Reason}
    end;
handle_embed(<<"similarity">>, [Text1, Text2], _Kwargs) ->
    case py:call(embedding_app, similarity, [Text1, Text2]) of
        {ok, Score} -> Score;
        {error, Reason} -> {error, Reason}
    end;
handle_embed(Action, Args, _Kwargs) ->
    {error, {unknown_action, Action, Args}}.
