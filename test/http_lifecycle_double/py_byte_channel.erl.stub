%% Test double only. Compile into an isolated temporary test code path.
-module(py_byte_channel).
-export([send/2, info/1, close/1]).

send(_Channel, Data) ->
    put(http_body_attempts, [Data | get_attempts()]),
    case get(http_body_send_results) of
        [Result | Rest] -> put(http_body_send_results, Rest), Result;
        _ -> busy
    end.

get_attempts() ->
    case get(http_body_attempts) of undefined -> []; Values -> Values end.

info(_Channel) -> #{closed => get(http_body_closed) =:= true}.
close(_Channel) -> put(http_body_closed, true), ok.
