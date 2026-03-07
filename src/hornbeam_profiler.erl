%%% @doc No-op request profiler stub.
%%% Provides the profiling API used by hornbeam_handler without
%%% collecting any data. Replace with a real implementation to
%%% enable request-level performance profiling.
-module(hornbeam_profiler).

-export([start_link/0, start_request/0, mark/2, end_request/1]).

start_link() ->
    ignore.

start_request() ->
    undefined.

mark(_Label, Prof) ->
    Prof.

end_request(_Prof) ->
    ok.
