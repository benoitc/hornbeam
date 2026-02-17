%% Copyright 2026 Benoit Chesneau
%% Licensed under the Apache License, Version 2.0

%%% @doc Fake inference module for distributed RPC demo.
%%%
%%% This module simulates ML inference by returning generated text.
%%% In a real deployment, this would call a Python ML model.
-module(inference).

-export([generate/2]).

%% @doc Generate a response for a prompt.
%% Returns a simulated response that includes the node name.
-spec generate(Model :: binary() | atom(), Prompt :: binary()) -> binary().
generate(_Model, Prompt) when is_binary(Prompt) ->
    Node = atom_to_binary(node(), utf8),
    <<"[", Node/binary, "] Response for: ", Prompt/binary>>;
generate(Model, Prompt) when is_list(Prompt) ->
    generate(Model, list_to_binary(Prompt));
generate(Model, Prompt) when is_atom(Prompt) ->
    generate(Model, atom_to_binary(Prompt, utf8)).
