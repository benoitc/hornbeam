%% Regression tests for ASGI's byte fields before native conversion.
-module(hornbeam_http_bytes_tests).

-include_lib("eunit/include/eunit.hrl").

scope_bytes_test() ->
    Headers = [{<<"cookie">>, <<"probe=yes">>},
               {<<"x-repeat">>, <<"café"/utf8>>},
               {<<"x-repeat">>, <<255, 0, 128>>}],
    Req = livery_req:new(#{path => <<"/caf%C3%A9">>,
                           raw_query => <<"name=caf%C3%A9">>,
                           headers => Headers}),
    Scope = hornbeam_request:build_asgi_scope(Req, #{}),
    ?assertEqual({bytes, <<"/caf%C3%A9">>}, maps:get(raw_path, Scope)),
    ?assertEqual({bytes, <<"name=caf%C3%A9">>}, maps:get(query_string, Scope)),
    ?assertEqual([[{bytes, K}, {bytes, V}] || {K, V} <- Headers],
                 maps:get(headers, Scope)),
    ?assertEqual(<<"http">>, maps:get(type, Scope)),
    ?assertEqual(<<"/caf%C3%A9">>, maps:get(path, Scope)),
    ?assertEqual(<<>>, maps:get(root_path, Scope)).

mounted_raw_path_test() ->
    Req = livery_req:new(#{path => <<"/api/caf%C3%A9">>}),
    Scope = hornbeam_request:build_asgi_scope(Req,
        #{script_name => <<"/api">>, path_info => <<"/caf%C3%A9">>}),
    ?assertEqual({bytes, <<"/api/caf%C3%A9">>}, maps:get(raw_path, Scope)),
    ?assertEqual(<<"/caf%C3%A9">>, maps:get(path, Scope)),
    ?assertEqual(<<"/api">>, maps:get(root_path, Scope)).
