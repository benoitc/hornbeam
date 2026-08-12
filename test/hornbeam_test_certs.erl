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

%%% @doc Self-signed certificate for the TLS suites.
%%%
%%% Generated into the suite's `priv_dir' at setup rather than vendored,
%%% so nothing long-lived sits in the repo and the cert cannot expire.
-module(hornbeam_test_certs).

-export([generate/1]).

%% @doc Write `cert.pem' and `key.pem' under `Dir', returning their paths.
%%
%% Returns `{error, no_openssl}' when openssl is not on PATH, so a suite
%% can skip rather than fail on a machine without it.
-spec generate(file:filename()) ->
    {ok, file:filename(), file:filename()} | {error, term()}.
generate(Dir) ->
    CertFile = filename:join(Dir, "cert.pem"),
    KeyFile = filename:join(Dir, "key.pem"),
    case os:find_executable("openssl") of
        false ->
            {error, no_openssl};
        OpenSsl ->
            Cmd = lists:flatten(io_lib:format(
                "~s req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes "
                "-keyout ~s -out ~s -subj /CN=localhost "
                "-addext subjectAltName=DNS:localhost,IP:127.0.0.1 2>&1",
                [OpenSsl, KeyFile, CertFile])),
            Output = os:cmd(Cmd),
            case {filelib:is_regular(CertFile), filelib:is_regular(KeyFile)} of
                {true, true} -> {ok, CertFile, KeyFile};
                _ -> {error, {openssl_failed, Output}}
            end
    end.
