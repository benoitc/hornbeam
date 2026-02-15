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

%%% @doc Embedding hook handler.
%%%
%%% Registered with hornbeam_hooks to handle embedding actions.
%%% Called via hornbeam_hooks:execute(<<"embeddings">>, Action, Args, Kwargs).
%%%
%%% Actions:
%%% - <<"embed">> [Texts] -> List of embeddings
%%% - <<"embed_one">> [Text] -> Single embedding
%%% - <<"similarity">> [Text1, Text2] -> Cosine similarity score
%%% - <<"find_similar">> [Query, Candidates] -> {Index, Score, Match}
-module(embedding_chat_embeddings).

-export([handle/3]).

%% @doc Hook handler for embedding operations.
-spec handle(Action :: binary(), Args :: list(), Kwargs :: map()) -> term().
handle(<<"embed">>, [Texts], _Kwargs) when is_list(Texts) ->
    Model = persistent_term:get(embedding_model),
    py:call(embedding_chat_model, encode, [Model, Texts]);

handle(<<"embed_one">>, [Text], _Kwargs) when is_binary(Text) ->
    Model = persistent_term:get(embedding_model),
    [Embedding] = py:call(embedding_chat_model, encode, [Model, [Text]]),
    Embedding;

handle(<<"similarity">>, [Text1, Text2], _Kwargs) ->
    Model = persistent_term:get(embedding_model),
    py:call(embedding_chat_model, similarity, [Model, Text1, Text2]);

handle(<<"find_similar">>, [Query, Candidates], _Kwargs) when is_list(Candidates) ->
    Model = persistent_term:get(embedding_model),
    py:call(embedding_chat_model, find_most_similar, [Model, Query, Candidates]);

handle(Action, Args, _Kwargs) ->
    error({unknown_action, Action, Args}).
