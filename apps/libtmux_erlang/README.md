<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-512.png" width="128" height="128" alt="libtmux for Erlang">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

<h1>libtmux for Erlang</h1>

<p>
  <a href="https://hex.pm/packages/libtmux_erlang">Hex.pm</a> ·
  <a href="https://libtmux.org/en/erlang/">Documentation</a> ·
  <a href="https://libtmux.org/en/erlang/latest/reference/">API reference</a> ·
  <a href="https://github.com/libtmux/libtmux-erlang/tree/master/examples">Examples</a>
</p>

<p>
  <a href="https://hex.pm/packages/libtmux_erlang"><img src="https://img.shields.io/hexpm/v/libtmux_erlang?label=libtmux_erlang" alt="libtmux_erlang"></a>
  <a href="https://libtmux.org/en/erlang/"><img src="https://img.shields.io/badge/docs-libtmux.org-0b7285" alt="libtmux.org"></a>
</p>

</div>

Drive tmux from Erlang: create [sessions][tmux-session],
[windows][tmux-window] and [panes][tmux-pane], capture the
[object graph][tmux-snapshot] as immutable data, filter it, ask tmux again.

[Install](#install) ·
[Inspect a captured graph](#inspect-a-captured-graph) ·
[Server API][tmux-server] ·
[Support](#support-and-status) ·
[Changelog](CHANGELOG.md)

## Install

It needs:

- Erlang/OTP 29 and Rebar3.
- tmux 3.3a or newer, on Linux (including WSL).
- `make` and a C11 compiler, to build the bundled helper.

Add the published application to `rebar.config`:

<!-- erlang-term -->

```erlang
{deps, [{libtmux_erlang, "0.0.1"}]}.
```

Commit `rebar.lock` and add `libtmux_erlang` to your application's
`applications` list.

More: [installation guide](../../docs/installation.md).

## Inspect a captured graph

### [`tmux_server:with_server/2`][api-with-server]: inspect an existing socket

Count the sessions, windows and panes on a server you did not start. Closing
the handle leaves that server and its sessions alone.

- [`tmux_server`][tmux-server]: owns the endpoint and observes the server.
- [`tmux_snapshot`][tmux-snapshot]: holds physical rows, session memberships
  and relationship coverage.

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

From the repository root, compile:

```console
$ mise exec -- rebar3 compile
```

Run it against a temporary server that the example runner starts:

```console
$ mise exec -- escript tools/run_examples.escript inspect
```

It returns a map with the `sessions`, `windows` and `panes` counts.

## Create, query and act

### [`tmux_query:fetch/1`][api-fetch]: read tmux again

[`tmux_query`][tmux-query] asks tmux only when you fetch. Selections never do.

- [Create and query a workspace](../../README.md#create-capture-and-query):
  three panes, a rename, a fresh query.
- [Traverse linked windows](../../docs/graph.md): physical windows versus
  session links.
- [Filter captured data](../../docs/querying.md): map criteria, Boolean
  functions, quantifiers and source queries.
- [Submit and cancel work](../../docs/jobs.md): await completion, exit status
  and output bytes.
- [Build the API browser](../../docs/api.md): module, function and type docs
  with source links.

## Support and status

- **Status:** early. Any release may change the API; pin an exact version.
- **Platform:** Linux, including WSL. Erlang/OTP 29 only.
- **tmux:** 3.3a or newer. A release newer than the tested ones returns
  `unsupported_option_catalogue` for built-in options and hooks.
- **Dependencies:** OTP only. The helper is an external program, not a NIF.
- **Stored results:** a selection keeps its captured graph. Convert to plain
  rows to store only the data.
- **Actions:** a target can vanish, or the outcome can be uncertain.

More: [Support and gaps](../../docs/compatibility.md) ·
[Daemon ownership](../../docs/ownership.md) ·
[Project policy](../../docs/project-policy.md).

## What it leaves out

- **Control command submission and output streams.** Not built yet.

## Contribute

See [contributor checks](../../.github/CONTRIBUTING.md). The core is under the
[MIT license](LICENSE).

[tmux-session]: https://libtmux.org/en/erlang/latest/reference/tmux_session/
[tmux-window]: https://libtmux.org/en/erlang/latest/reference/tmux_window/
[tmux-pane]: https://libtmux.org/en/erlang/latest/reference/tmux_pane/
[tmux-server]: https://libtmux.org/en/erlang/latest/reference/tmux_server/
[tmux-snapshot]: https://libtmux.org/en/erlang/latest/reference/tmux_snapshot/
[tmux-query]: https://libtmux.org/en/erlang/latest/reference/tmux_query/
[api-with-server]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_server-2/
[api-fetch]: https://libtmux.org/en/erlang/latest/reference/tmux_query-fetch-1/
