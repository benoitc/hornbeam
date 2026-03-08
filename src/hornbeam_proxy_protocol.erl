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

%%% @doc PROXY protocol v2 encoder for hornbeam.
%%%
%%% Encodes client information into PROXY protocol v2 binary format
%%% for transmission to Python reactor over socketpair.
%%%
%%% PROXY protocol v2 header format:
%%% - 12 bytes: signature
%%% - 1 byte: version (4 bits) + command (4 bits)
%%% - 1 byte: address family (4 bits) + transport protocol (4 bits)
%%% - 2 bytes: address length (big endian)
%%% - N bytes: addresses
%%%
%%% @see https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt
-module(hornbeam_proxy_protocol).

-export([
    encode_v2/1,
    encode_v2_local/0,
    signature/0
]).

%% PROXY protocol v2 signature (12 bytes)
-define(PP_V2_SIGNATURE, <<13,10,13,10,0,13,10,81,85,73,84,10>>).

%% Version and Command
-define(PP_VERSION_2, 2).
-define(PP_CMD_LOCAL, 0).
-define(PP_CMD_PROXY, 1).

%% Address Family
-define(PP_AF_UNSPEC, 0).
-define(PP_AF_INET, 1).    %% IPv4
-define(PP_AF_INET6, 2).   %% IPv6
-define(PP_AF_UNIX, 3).

%% Transport Protocol
-define(PP_PROTO_UNSPEC, 0).
-define(PP_PROTO_STREAM, 1).  %% TCP
-define(PP_PROTO_DGRAM, 2).   %% UDP

%% @doc Get the PROXY protocol v2 signature.
-spec signature() -> binary().
signature() ->
    ?PP_V2_SIGNATURE.

%% @doc Encode client info to PROXY protocol v2 format.
%%
%% ClientInfo is a map containing:
%% - peer: {IP, Port} tuple for client address
%% - server: {IP, Port} tuple for server address (optional)
%% - protocol: tcp | udp (default: tcp)
%%
%% Returns binary PROXY protocol v2 header.
-spec encode_v2(map()) -> binary().
encode_v2(#{peer := {ClientIp, ClientPort}} = Info) ->
    %% Get server address (default to 0.0.0.0:0)
    {ServerIp, ServerPort} = maps:get(server, Info, {{0,0,0,0}, 0}),

    %% Determine address family and encode addresses
    {Family, AddrData} = encode_addresses(ClientIp, ClientPort, ServerIp, ServerPort),

    %% Build header
    VerCmd = (?PP_VERSION_2 bsl 4) bor ?PP_CMD_PROXY,
    FamProto = (Family bsl 4) bor ?PP_PROTO_STREAM,
    AddrLen = byte_size(AddrData),

    <<?PP_V2_SIGNATURE/binary,
      VerCmd:8,
      FamProto:8,
      AddrLen:16/big,
      AddrData/binary>>;

encode_v2(#{client := {ClientIp, ClientPort}} = Info) ->
    %% Alias 'client' to 'peer' for flexibility
    encode_v2(Info#{peer => {ClientIp, ClientPort}}).

%% @doc Encode LOCAL command (health checks, etc).
%%
%% LOCAL command indicates connection should not be logged
%% and no address information is provided.
-spec encode_v2_local() -> binary().
encode_v2_local() ->
    VerCmd = (?PP_VERSION_2 bsl 4) bor ?PP_CMD_LOCAL,
    FamProto = (?PP_AF_UNSPEC bsl 4) bor ?PP_PROTO_UNSPEC,
    <<?PP_V2_SIGNATURE/binary,
      VerCmd:8,
      FamProto:8,
      0:16/big>>.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

%% @private
%% Encode addresses based on IP version
encode_addresses({A,B,C,D}, SrcPort, {E,F,G,H}, DstPort) when
        A >= 0, A =< 255, B >= 0, B =< 255,
        C >= 0, C =< 255, D >= 0, D =< 255,
        E >= 0, E =< 255, F >= 0, F =< 255,
        G >= 0, G =< 255, H >= 0, H =< 255 ->
    %% IPv4
    AddrData = <<A:8, B:8, C:8, D:8,       %% src addr (4 bytes)
                 E:8, F:8, G:8, H:8,        %% dst addr (4 bytes)
                 SrcPort:16/big,             %% src port (2 bytes)
                 DstPort:16/big>>,           %% dst port (2 bytes)
    {?PP_AF_INET, AddrData};

encode_addresses(SrcIp, SrcPort, DstIp, DstPort) when
        tuple_size(SrcIp) =:= 8, tuple_size(DstIp) =:= 8 ->
    %% IPv6
    {S1,S2,S3,S4,S5,S6,S7,S8} = SrcIp,
    {D1,D2,D3,D4,D5,D6,D7,D8} = DstIp,
    AddrData = <<S1:16/big, S2:16/big, S3:16/big, S4:16/big,
                 S5:16/big, S6:16/big, S7:16/big, S8:16/big,  %% src (16 bytes)
                 D1:16/big, D2:16/big, D3:16/big, D4:16/big,
                 D5:16/big, D6:16/big, D7:16/big, D8:16/big,  %% dst (16 bytes)
                 SrcPort:16/big,                               %% src port
                 DstPort:16/big>>,                             %% dst port
    {?PP_AF_INET6, AddrData};

encode_addresses(_, _, _, _) ->
    %% Unknown address family - use UNSPEC
    {?PP_AF_UNSPEC, <<>>}.
