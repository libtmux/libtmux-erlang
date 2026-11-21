-module(quickstart).
-moduledoc "Count panes on a private tmux server.".
-export([main/0, run/1]).

-spec main() -> ok.
main() ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    io:format("~ts~n", [json:encode(run(#{}))]).

-spec run(tmux_server:owned_options()) -> #{panes := non_neg_integer()}.
run(Options) ->
    {ok, Counts} = tmux_server:with_owned(Options, fun(Server) ->
        {ok, _} = tmux_session:create(Server,
            #{name => <<"demo">>, launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        #{panes => length(tmux_snapshot:panes(Snapshot))}
    end),
    Counts.
