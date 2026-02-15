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

%%% @doc Embedding Chat Supervisor.
%%%
%%% Initializes Python and loads the embedding model.
-module(embedding_chat_sup).

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link(ModelName) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [ModelName]).

init([ModelName]) ->
    %% Initialize Python and load model
    io:format("Loading sentence-transformers model: ~s~n", [ModelName]),
    ok = init_python(),
    ok = load_model(ModelName),
    io:format("Model loaded successfully~n"),

    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },

    %% No child processes needed - model is in persistent_term
    Children = [],

    {ok, {SupFlags, Children}}.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

init_python() ->
    %% Add priv directory to Python path
    PrivDir = priv_dir(),
    py:exec(io_lib:format(
        "import sys; sys.path.insert(0, '~s') if '~s' not in sys.path else None",
        [PrivDir, PrivDir]
    )),
    ok.

load_model(ModelName) ->
    %% Initialize the Python module
    py:call(embedding_chat_model, init, []),
    %% Load the model
    Model = py:call(embedding_chat_model, load_model, [list_to_binary(ModelName)]),
    %% Store in persistent_term for fast access
    persistent_term:put(embedding_model, Model),
    ok.

priv_dir() ->
    case code:priv_dir(embedding_chat) of
        {error, _} ->
            filename:join(filename:dirname(code:which(?MODULE)), "../priv");
        Dir ->
            Dir
    end.
