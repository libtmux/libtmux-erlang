# Install the core application

The core OTP application is `libtmux_erlang`. It lives in an umbrella, so a
Rebar3 source dependency must use `git_subdir` with `apps/libtmux_erlang`.
Using the repository root as an ordinary single-app Git dependency does not
select the core application.

The [README](../README.md#install) contains the dependency declaration tested
in an isolated Rebar3 consumer. Rebar3 resolves the branch to a commit in
`rebar.lock`; commit that file. To choose a reviewed commit directly, use
Rebar3's `{ref, Commit}` form instead of `{branch, "master"}`.

Add `libtmux_erlang` to your application's `applications` list in its
`.app.src`. For an interactive consumer, compile and start the Rebar3 shell:

```console
$ rebar3 compile
```

```console
$ rebar3 shell
```

## Inspect an existing server

`open/1` borrows an existing daemon. It does not start tmux or create a session.
From a shell attached to the server you intend to inspect, obtain its socket:

```console
$ export LIBTMUX_SOCKET="$(tmux display-message -p '#{socket_path}')"
```

Save this module as `src/inspect_demo.erl` in the consumer application:

<!-- example: examples/inspect_demo.erl -->

```erlang
-module(inspect_demo).
-moduledoc "Inspect an existing tmux socket without changing its sessions.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Result} = tmux_server:with_server(Endpoint, fun(Server) ->
        {ok, Snapshot} = tmux_server:snapshot(Server),
        #{sessions => length(tmux_snapshot:sessions(Snapshot)),
          windows => length(tmux_snapshot:windows(Snapshot)),
          panes => length(tmux_snapshot:panes(Snapshot))}
    end),
    Result.
```

Run it through the consumer's Rebar shell. The executable path comes from PATH;
the socket must be the absolute path selected above:

```console
$ rebar3 shell \
    --eval '
        Socket = list_to_binary(os:getenv("LIBTMUX_SOCKET")),
        Tmux = list_to_binary(os:find_executable("tmux")),
        io:format("~p~n", [inspect_demo:run(Socket, Tmux)]),
        halt().'
```

The returned map counts physical objects in one captured view. Closing the
library handle preserves the borrowed daemon and its sessions. This module
also runs against the installed archive in the outer check. The private-server
[README program](../README.md#create-capture-and-query) adds creation, native
record patterns, graph traversal and a fresh query.

Direct native-record construction needs `tmux_model` loaded first; its
constructors load normally and validate observations. Do not distribute record
headers or serialize record internals as a wire format.

## Requirements

| Component | Current requirement |
| --- | --- |
| Erlang/OTP | Exactly the qualified latest-stable baseline, 29.1.2 |
| Build tool | Rebar3 3.28.0 |
| tmux | 3.3a–3.8, including intermediate releases; CI tests both endpoints |
| Runtime platform | Linux x86_64 and arm64 qualification cells |
| Native build | C11 compiler, libc headers and make |
| Core dependencies | OTP kernel, stdlib and crypto; no JSON package or NIF |
| Checkout example runner | Python 3.12+ for owned-server readiness observation |

The helper builds from its packaged C source. Installation must fail if that
build fails; there is no runtime executable download. The helper's original
license is retained separately from the project's MIT license.

There is no published Hex package or release artifact for this checkout.
[API docs](api.md) describe the local browser build. [Compatibility](compatibility.md)
separates current checks from the remaining suite and delivery gates.
