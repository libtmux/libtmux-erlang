# Install the core application

The core OTP application is
[`libtmux_erlang`](https://hex.pm/packages/libtmux_erlang) on Hex.

The [README](../README.md#install) has the dependency declaration. Pin an exact
version while the API develops, and commit `rebar.lock` to keep the resolved
package checksum.

Add `libtmux_erlang` to your application's `applications` list in its
`.app.src`. To try it interactively, compile and start the Rebar3 shell:

```console
$ rebar3 compile
```

```console
$ rebar3 shell
```

## Install a source checkout

The repository is an umbrella. Use `git_subdir` to select
`apps/libtmux_erlang`:

<!-- erlang-term -->

```erlang
{deps, [
    {libtmux_erlang, {git_subdir,
        "https://github.com/libtmux/libtmux-erlang.git",
        {branch, "master"}, "apps/libtmux_erlang"}}
]}.
```

- Rebar3 records the branch's resolved commit in `rebar.lock`.
- To pin a reviewed commit, use `{ref, Commit}` instead of
  `{branch, "master"}`.

## Inspect an existing server

`open/1` borrows an existing daemon. It starts no tmux and creates no session.
The library needs the socket's absolute path. From a shell attached to the
server you want to inspect, get it:

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

Run it through the consumer's Rebar shell. The tmux executable comes from
`PATH`. The socket must be the absolute path above:

```console
$ rebar3 shell \
    --eval '
        Socket = list_to_binary(os:getenv("LIBTMUX_SOCKET")),
        Tmux = list_to_binary(os:find_executable("tmux")),
        io:format("~p~n", [inspect_demo:run(Socket, Tmux)]),
        halt().'
```

- The returned map counts physical objects in one captured view.
- Closing the library handle leaves the borrowed daemon and its sessions.
- The [README program](../README.md#create-capture-and-query) starts its own
  private server. It adds creation, native record patterns, graph traversal
  and a fresh query.
- To build a native record yourself, load `tmux_model` first. Its constructors
  load normally and validate observations.
- Do not distribute record headers or serialize record internals as a wire
  format.

## Requirements

| Component | Requirement |
| --- | --- |
| Erlang/OTP | 29 |
| Build tool | Rebar3 |
| tmux | 3.3a or newer |
| Platform | Linux, including WSL |
| Native build | C11 compiler, libc headers and make |
| Core dependencies | OTP kernel, stdlib and crypto; no JSON package or NIF |
| Checkout example runner | Python 3.12 or newer |

- The helper builds from its packaged C source. Installation fails if that
  build fails. Nothing is downloaded at runtime.
- The helper's original license is kept apart from the project's MIT license.
- Hex serves the core. HexDocs is not published. The
  [API reference](https://libtmux.org/en/erlang/latest/reference/) lives on the
  [shared documentation site](https://libtmux.org/en/erlang/), and
  [API docs](api.md) describe the local build.

[Compatibility](compatibility.md) lists the tested cells and the open gaps.
