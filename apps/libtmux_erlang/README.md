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

`libtmux_erlang` is an Erlang tmux client library. Create sessions, windows and
panes, capture their relationships, and filter the captured values locally.
Source queries and mutations execute explicitly through owned operations.

[Inspect a captured graph](#inspect-a-captured-graph) ·
[Server API](https://libtmux.org/en/erlang/latest/reference/tmux_server/) ·
[Changelog](CHANGELOG.md)

## Add the core application

Use Erlang/OTP 29.1.2, Rebar3 3.28.0, Linux x86_64 or arm64, tmux 3.3a–3.8,
and make with a C11 compiler. The helper builds from packaged source. BEAM
runtime dependencies are OTP libraries; native records are experimental in
OTP 29.

Add the published application to `rebar.config`:

<!-- erlang-term -->

```erlang
{deps, [{libtmux_erlang, "0.0.1"}]}.
```

Commit `rebar.lock` and add `libtmux_erlang` to your application's
`applications` list. The [installation guide](../../docs/installation.md)
walks through a separate Rebar3 consumer.

## Inspect a captured graph

### [`tmux_server:with_server/2`][api-with-server]: inspect an existing socket

This complete module counts physical sessions, windows and panes on an
explicitly selected existing socket. Closing the library endpoint preserves
the borrowed server and its sessions.

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

From the repository root, compile the applications:

```console
$ mise exec -- rebar3 compile
```

Run the module against a temporary server owned by the example runner:

```console
$ mise exec -- escript tools/run_examples.escript inspect
```

The runner checks its result and retires its server and clients. The installed
consumer check repeats the same program outside the umbrella.

The [server API](https://libtmux.org/en/erlang/latest/reference/tmux_server/)
documents endpoint ownership and observation. The
[snapshot API](https://libtmux.org/en/erlang/latest/reference/tmux_snapshot/)
documents physical rows, session memberships and relationship coverage.

## Create, query and act

### [`tmux_query:fetch/1`][api-fetch]: observe tmux explicitly

- [Create and query a workspace](../../README.md#create-capture-and-query):
  build three panes, query their windows, rename one and compare captured values.
- [Traverse linked windows](../../docs/graph.md): distinguish physical objects
  from session memberships and preserve counts and ordering.
- [Filter captured data](../../docs/querying.md): map criteria, native Boolean
  functions, relation quantifiers and explicit source-query execution.
- [Submit and cancel work](../../docs/jobs.md): wait for completion, check the
  exit status and capture output bytes.
- [Build the API browser](../../docs/api.md): native module, function and type
  documentation with checked links to captured source.

## Check support and ownership

Support covers tmux 3.3a–3.8; routine CI tests both endpoints on Ubuntu 24.04
x86_64 and arm64 with OTP 29.1.2. One-shot operations and explicit control
attachment are qualified. Control command submission and output streams remain
implementation work. See [support and gaps](../../docs/compatibility.md).

Selections retain their captured graph. Convert to ordinary rows when storing
results without that context. Actions can encounter a vanished target or an
uncertain outcome; the [ownership guide](../../docs/ownership.md) explains
endpoint lifetimes and cleanup evidence.

The core depends on OTP applications. See
[project policy](../../docs/project-policy.md),
[contributor checks](../../.github/CONTRIBUTING.md), and the [MIT license](LICENSE).

[api-with-server]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_server-2/
[api-fetch]: https://libtmux.org/en/erlang/latest/reference/tmux_query-fetch-1/
