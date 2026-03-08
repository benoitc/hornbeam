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

%%% @doc Tests for PROXY protocol v2 encoder.
-module(hornbeam_proxy_protocol_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    encode_v2_ipv4_test/1,
    encode_v2_ipv6_test/1,
    encode_v2_local_test/1,
    signature_test/1,
    roundtrip_encoding_test/1
]).

%% PROXY protocol v2 signature
-define(PP_V2_SIGNATURE, <<13,10,13,10,0,13,10,81,85,73,84,10>>).

all() ->
    [
        encode_v2_ipv4_test,
        encode_v2_ipv6_test,
        encode_v2_local_test,
        signature_test,
        roundtrip_encoding_test
    ].

groups() ->
    [].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%%% ============================================================================
%%% Test Cases
%%% ============================================================================

encode_v2_ipv4_test(_Config) ->
    Info = #{
        peer => {{192, 168, 1, 100}, 54321},
        server => {{10, 0, 0, 1}, 80}
    },
    Encoded = hornbeam_proxy_protocol:encode_v2(Info),

    %% Verify signature
    <<Signature:12/binary, Rest/binary>> = Encoded,
    ?assertEqual(?PP_V2_SIGNATURE, Signature),

    %% Verify version and command
    <<VerCmd:8, FamProto:8, AddrLen:16/big, AddrData/binary>> = Rest,
    Version = (VerCmd band 16#F0) bsr 4,
    Command = VerCmd band 16#0F,
    Family = (FamProto band 16#F0) bsr 4,
    Protocol = FamProto band 16#0F,

    ?assertEqual(2, Version),      %% Version 2
    ?assertEqual(1, Command),      %% PROXY command
    ?assertEqual(1, Family),       %% AF_INET (IPv4)
    ?assertEqual(1, Protocol),     %% STREAM (TCP)
    ?assertEqual(12, AddrLen),     %% 4+4+2+2 bytes

    %% Verify addresses
    <<SrcIp:4/binary, DstIp:4/binary, SrcPort:16/big, DstPort:16/big>> = AddrData,
    ?assertEqual(<<192, 168, 1, 100>>, SrcIp),
    ?assertEqual(<<10, 0, 0, 1>>, DstIp),
    ?assertEqual(54321, SrcPort),
    ?assertEqual(80, DstPort),

    ok.

encode_v2_ipv6_test(_Config) ->
    Info = #{
        peer => {{8193, 3512, 0, 0, 0, 0, 0, 1}, 54321},  %% 2001:db8::1
        server => {{8193, 3512, 0, 0, 0, 0, 0, 2}, 80}    %% 2001:db8::2
    },
    Encoded = hornbeam_proxy_protocol:encode_v2(Info),

    %% Verify signature
    <<Signature:12/binary, Rest/binary>> = Encoded,
    ?assertEqual(?PP_V2_SIGNATURE, Signature),

    %% Verify header
    <<VerCmd:8, FamProto:8, AddrLen:16/big, _AddrData/binary>> = Rest,
    Family = (FamProto band 16#F0) bsr 4,

    ?assertEqual(2, Family),       %% AF_INET6 (IPv6)
    ?assertEqual(36, AddrLen),     %% 16+16+2+2 bytes

    ok.

encode_v2_local_test(_Config) ->
    Encoded = hornbeam_proxy_protocol:encode_v2_local(),

    %% Verify signature
    <<Signature:12/binary, Rest/binary>> = Encoded,
    ?assertEqual(?PP_V2_SIGNATURE, Signature),

    %% Verify LOCAL command
    <<VerCmd:8, FamProto:8, AddrLen:16/big>> = Rest,
    Command = VerCmd band 16#0F,
    Family = (FamProto band 16#F0) bsr 4,

    ?assertEqual(0, Command),      %% LOCAL command
    ?assertEqual(0, Family),       %% UNSPEC
    ?assertEqual(0, AddrLen),      %% No address data

    ok.

signature_test(_Config) ->
    Signature = hornbeam_proxy_protocol:signature(),
    ?assertEqual(?PP_V2_SIGNATURE, Signature),
    ?assertEqual(12, byte_size(Signature)),
    ok.

roundtrip_encoding_test(_Config) ->
    %% Test that encoded data can be decoded by Python parser
    %% This is a basic sanity check - full roundtrip would require Python
    Info = #{peer => {{127, 0, 0, 1}, 12345}},
    Encoded = hornbeam_proxy_protocol:encode_v2(Info),

    %% Should be at least signature + 4 byte header
    ?assert(byte_size(Encoded) >= 16),

    %% Should start with signature
    ?assertEqual(?PP_V2_SIGNATURE, binary:part(Encoded, 0, 12)),

    ok.
