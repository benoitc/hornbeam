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

%%% @doc HTTP helper for the test suites.
%%%
%%% Exists only so the suites do not rebuild a client at every call site.
%%% The result is `livery_client''s own response, so suites match on
%%% `#{status := _, headers := _, body := {full, _}}' directly; response
%%% headers keep their wire case, and `livery_client:header/2,3' looks
%%% them up case-insensitively.
-module(hornbeam_test_http).

-export([request/2, request/3, request/4]).

-spec request(atom(), iodata()) -> livery_client:result().
request(Method, Url) ->
    request(Method, Url, #{}, #{}).

-spec request(atom(), iodata(), map()) -> livery_client:result().
request(Method, Url, ReqOpts) ->
    request(Method, Url, ReqOpts, #{}).

%% @doc `ClientOpts' reaches `livery_client:new/1' (adapter, layer stack,
%% TLS options); `ReqOpts' reaches the request (headers, body, timeout).
-spec request(atom(), iodata(), map(), map()) -> livery_client:result().
request(Method, Url, ReqOpts, ClientOpts) ->
    Client = livery_client:new(unpooled(ClientOpts)),
    livery_client:request(Client, Method, iolist_to_binary(Url), ReqOpts).

%% @private
%% Every request gets a fresh connection. The suites stop and start the
%% server between groups, and a pooled keep-alive connection held across a
%% restart fails the next request on it - intermittently, and as whatever
%% hackney makes of the dead socket rather than as anything the test is
%% about. Pooling is the client's business, not what these suites check.
unpooled(ClientOpts) ->
    AdapterOpts = maps:get(adapter_opts, ClientOpts, #{}),
    Hackney = maps:get(hackney, AdapterOpts, []),
    ClientOpts#{adapter_opts =>
        AdapterOpts#{hackney => [{pool, false} | Hackney]}}.
