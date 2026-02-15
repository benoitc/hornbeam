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

%%% @doc Embedding Chat Application.
%%%
%%% Demonstrates:
%%% - Erlang-Python binding for sentence-transformers
%%% - FastAPI ASGI app calling Erlang hooks
%%% - Pure Erlang WebSocket handler
%%%
%%% Start with:
%%% ```
%%% application:ensure_all_started(embedding_chat).
%%% '''
-module(embedding_chat_app).

-behaviour(application).

-export([start/2, stop/1]).

%%% ============================================================================
%%% Application callbacks
%%% ============================================================================

start(_StartType, _StartArgs) ->
    %% Get configuration
    {ok, ModelName} = application:get_env(embedding_chat, model_name),
    {ok, Port} = application:get_env(embedding_chat, port),
    {ok, Bind} = application:get_env(embedding_chat, bind),

    %% Start supervisor (which initializes Python and model)
    case embedding_chat_sup:start_link(ModelName) of
        {ok, Pid} ->
            %% Register embedding hook
            ok = hornbeam_hooks:reg(<<"embeddings">>,
                                    embedding_chat_embeddings, handle, 3),

            %% Start hornbeam HTTP server
            BindAddr = iolist_to_binary([Bind, ":", integer_to_list(Port)]),
            VenvSitePackages = filename:join([source_dir(), "venv/lib/python3.14/site-packages"]),
            ok = hornbeam:start(<<"embedding_chat.app:app">>, #{
                worker_class => asgi,
                bind => BindAddr,
                pythonpath => [priv_dir(), VenvSitePackages],
                %% /ws handled by Erlang, rest by FastAPI
                routes => [
                    {"/ws", embedding_chat_ws, #{}}
                ]
            }),

            io:format("~n"),
            io:format("Embedding Chat started on http://~s:~p~n", [Bind, Port]),
            io:format("  POST /embed      - Get embeddings~n"),
            io:format("  POST /similarity - Compute similarity~n"),
            io:format("  GET  /chat       - Chat UI~n"),
            io:format("  WS   /ws         - WebSocket echo (Erlang)~n"),
            io:format("~n"),

            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    hornbeam:stop(),
    ok.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

priv_dir() ->
    case code:priv_dir(embedding_chat) of
        {error, _} ->
            %% Development mode
            filename:join(filename:dirname(code:which(?MODULE)), "../priv");
        Dir ->
            Dir
    end.

%% Find the source directory (not _build) for venv lookup
source_dir() ->
    case code:which(?MODULE) of
        non_existing -> ".";
        ModPath ->
            find_source_root(filename:dirname(ModPath))
    end.

find_source_root(Dir) ->
    RebarConfig = filename:join(Dir, "rebar.config"),
    case filelib:is_file(RebarConfig) of
        true -> Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> ".";
                _ -> find_source_root(Parent)
            end
    end.
