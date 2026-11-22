# Start a private server and count its panes

Create one session, capture the server state and count the panes. The program
prints this after the private server stops and its socket is removed.

<!-- example-output: quickstart -->

```json
{"panes":1}
```

In an empty directory, save the Hex dependency from [Install](../README.md#install)
as `rebar.config`. [Set up Erlang and Rebar3](installation.md#set-up-erlang-and-rebar3)
and put tmux on `PATH`.

```console
$ rebar3 compile
```

Save this as `quickstart.erl`. `tmux_server:with_owned/2` starts a daemon on
its own socket and retires it when the callback finishes.

<!-- example: examples/quickstart.erl -->

```erlang
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
```

Compile and run the example from the same directory.

```console
$ erl -noshell \
    -pa _build/default/lib/libtmux_erlang/ebin \
    -eval '{ok, quickstart} = c:c("quickstart.erl"),
        quickstart:main(), halt().'
```

[Inspect an existing socket](installation.md#inspect-an-existing-server) to
count panes on a server you already run.
