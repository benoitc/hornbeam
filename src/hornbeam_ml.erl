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

%%% @doc ML utilities for hornbeam.
%%%
%%% This module provides Erlang-side ML utilities:
%%% - Cache management for ML results
%%% - Batch request collection
%%% - Cache statistics
-module(hornbeam_ml).

-export([
    get_cached/2,
    set_cached/3,
    clear_cache/1,
    cache_stats/0,
    cache_hit/0,
    cache_miss/0
]).

%% @doc Get a cached ML result.
-spec get_cached(Prefix :: binary(), Key :: binary()) -> term() | undefined.
get_cached(Prefix, Key) ->
    CacheKey = make_cache_key(Prefix, Key),
    hornbeam_state:get(CacheKey).

%% @doc Store an ML result in cache.
-spec set_cached(Prefix :: binary(), Key :: binary(), Value :: term()) -> ok.
set_cached(Prefix, Key, Value) ->
    CacheKey = make_cache_key(Prefix, Key),
    hornbeam_state:set(CacheKey, Value).

%% @doc Clear all cached entries with a given prefix.
-spec clear_cache(Prefix :: binary()) -> non_neg_integer().
clear_cache(Prefix) ->
    %% Get all keys matching prefix
    Keys = hornbeam_state:keys(<<"ml_", Prefix/binary, ":">>),
    lists:foreach(fun(Key) ->
        hornbeam_state:delete(Key)
    end, Keys),
    length(Keys).

%% @doc Get cache statistics.
-spec cache_stats() -> map().
cache_stats() ->
    Hits = case hornbeam_state:get(<<"ml_cache_hits">>) of
        undefined -> 0;
        H -> H
    end,
    Misses = case hornbeam_state:get(<<"ml_cache_misses">>) of
        undefined -> 0;
        M -> M
    end,
    Total = Hits + Misses,
    HitRate = case Total of
        0 -> 0.0;
        _ -> Hits / Total
    end,
    #{
        hits => Hits,
        misses => Misses,
        total => Total,
        hit_rate => HitRate
    }.

%% @doc Record a cache hit.
-spec cache_hit() -> integer().
cache_hit() ->
    hornbeam_state:incr(<<"ml_cache_hits">>, 1).

%% @doc Record a cache miss.
-spec cache_miss() -> integer().
cache_miss() ->
    hornbeam_state:incr(<<"ml_cache_misses">>, 1).

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

make_cache_key(Prefix, Key) ->
    <<"ml_", Prefix/binary, ":", Key/binary>>.
