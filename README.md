<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-512.png" width="128" height="128" alt="libtmux for Erlang">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Erlang

[Hex.pm](https://hex.pm/packages/libtmux_erlang) ·
[Documentation](https://libtmux.org/en/erlang/) ·
[API reference](https://libtmux.org/en/erlang/latest/reference/) ·
[Examples](https://github.com/libtmux/libtmux-erlang/tree/master/examples)

[![Erlang checks](https://github.com/libtmux/libtmux-erlang/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-erlang/actions/workflows/ci.yml)
[![libtmux_erlang](https://img.shields.io/hexpm/v/libtmux_erlang?label=libtmux_erlang)](https://hex.pm/packages/libtmux_erlang)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/erlang/)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-erlang/blob/master/LICENSE)

</div>

libtmux for Erlang is a tmux client library. Create
[sessions](https://libtmux.org/en/erlang/latest/reference/tmux_session/),
[windows](https://libtmux.org/en/erlang/latest/reference/tmux_window/) and
[panes](https://libtmux.org/en/erlang/latest/reference/tmux_pane/), capture their
[object graph](https://libtmux.org/en/erlang/latest/reference/tmux_snapshot/),
filter it as immutable data, and execute source queries and owned operations
explicitly.

[Create, capture and query](#create-capture-and-query) ·
[Packages](#packages) ·
[Core package](apps/libtmux_erlang/README.md) ·
[Changelog](CHANGELOG.md)

## Install

Use Erlang/OTP **29.1.2**, Rebar3 **3.28.0**, Linux, tmux **3.3a–3.8**, and
`make` with a C11 compiler. Native records are experimental in OTP 29. The core
uses OTP libraries and a compiled external helper, with no NIF or third-party
runtime packages.

Add the published core application from [Hex](https://hex.pm/packages/libtmux_erlang)
to your `rebar.config`:

<!-- erlang-term -->

```erlang
{deps, [{libtmux_erlang, "0.0.1"}]}.
```

The API is still developing; pin an exact version and commit `rebar.lock`.
The
[installation guide](docs/installation.md) covers application startup and
building a consumer from Hex or a source checkout.

## Create, capture and query

### [`tmux_server:with_owned/2`][api-with-owned]: create a private tmux graph

From this checkout, compile with the pinned tools:

```console
$ mise exec -- rebar3 compile
```

Run the complete program below on a private tmux server:

```console
$ mise exec -- escript tools/run_examples.escript readme
```

The program starts an empty daemon on a unique private socket, verifies its
assertions, and retires the owned server and clients. It leaves your existing
tmux sessions alone. It uses only public core APIs and OTP runtime libraries;
the archive check also runs it outside this checkout.
Save it as `readme_demo.erl` when reusing it in an application.

[`tmux_server`](https://libtmux.org/en/erlang/latest/reference/tmux_server/)
owns the connection and scoped server lifetime.
[`tmux_snapshot`](https://libtmux.org/en/erlang/latest/reference/tmux_snapshot/)
holds captured rows;
[`tmux_select`](https://libtmux.org/en/erlang/latest/reference/tmux_select/)
filters those rows locally. A
[`tmux_query`](https://libtmux.org/en/erlang/latest/reference/tmux_query/)
executes a new observation when fetched.

<!-- example: examples/readme_demo.erl -->

```erlang
-module(readme_demo).
-moduledoc "Create a workspace, query its graph and preserve captured values.".
-export([run/1]).
-import_record(tmux_model, [pane]).

-spec run(binary()) -> map().
run(Executable) ->
    Options = #{executable => Executable},
    {ok, Result} = tmux_server:with_owned(Options, fun(Server) ->
        {ok, Session} = tmux_session:create(Server, #{name => <<"workspace">>,
            window_name => <<"editor">>, width => 120, height => 30,
            launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Worker} = tmux_window:create(Session,
            #{name => <<"workers">>,
              launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Right} = tmux_pane:split(Worker, #{direction => horizontal,
            launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, _} = tmux_window:select_layout(Worker, even_horizontal),
        {ok, _} = tmux_pane:resize(Right, #{width => 40}),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        Windows = tmux_select:windows(Snapshot),
        Workers = #{name => <<"workers">>, panes => #{count => 2,
            every => #{current_command => <<"cat">>}}},
        {ok, Captured} = tmux_select:one(Workers, Windows),
        {ok, Children} = tmux_snapshot:related(panes, Captured, Snapshot),
        Ids = [Id || #pane{id = Id} <:- Children],
        2 = length(Ids),
        Criteria = #{width => #{gte => 20},
            window => #{is => #{name => <<"workers">>}}},
        Query = tmux_query:where(Criteria, tmux_query:panes(Server)),
        {ok, Fetched} = tmux_query:fetch(Query),
        2 = tmux_select:size(Fetched),
        {ok, _} = tmux_window:rename(Worker, <<"finished">>),
        <<"workers">> = tmux_model:get(name, Captured),
        {ok, Fresh} = tmux_query:fetch(tmux_query:where(
            #{name => <<"finished">>}, tmux_query:windows(Server))),
        {ok, Renamed} = tmux_select:one(Fresh),
        <<"finished">> = tmux_model:get(name, Renamed),
        1 = length(tmux_snapshot:sessions(Snapshot)),
        2 = length(tmux_snapshot:windows(Snapshot)),
        3 = length(tmux_snapshot:panes(Snapshot)),
        #{sessions => 1, windows => 2, panes => 3, matched_panes => 2,
          captured_name => <<"workers">>, immutable => true}
    end),
    Result.
```

The result includes this checked output. Captured rows keep their original
values after a rename; actions and `fetch` perform explicit I/O.
`tmux_server:with_owned/2` returns success after verified daemon cleanup. If cleanup fails,
its error preserves the callback outcome and ownership token for recovery.

<!-- example-output: readme_demo -->

```json
{
  "sessions": 1,
  "windows": 2,
  "panes": 3,
  "matched_panes": 2,
  "captured_name": "workers",
  "immutable": true
}
```

## Follow the graph

### [`tmux_snapshot:related/3`][api-related]: follow shared windows

A window can have several links in one session and belong to more than one
session. Physical windows and panes remain unique; window links retain each
session/index membership.

- [Linked windows and relationship queries](docs/graph.md): build two sessions,
  link a shared window twice, and verify physical and membership counts.

### [`tmux_select:where/2`][api-where]: filter captured rows

- [Local filters and source queries](docs/querying.md): Boolean criteria,
  quantifiers, portable JSON, cardinality, coverage and execution plans.
- [Fields and operators](docs/fields.md): generated from the runtime schema.

### [`tmux_query:fetch/1`][api-fetch]: observe tmux explicitly

The [querying guide](docs/querying.md) follows a source query through planning,
execution and a new immutable selection. Local filtering preserves its
captured values; fetching performs I/O.

### [`tmux_server:with_server/2`][api-with-server]: borrow an existing server

- [Daemon ownership](docs/ownership.md): choose private startup or a borrowed
  socket, keep their lifetimes explicit and handle incomplete cleanup.
- [Control attachments](docs/control.md): verify connection identity, inspect
  attachment effects and retire the client explicitly.

### [`tmux_operation:await/2`][api-await]: wait for submitted work

- [Run a job and capture its result](docs/jobs.md): wait for a pane's completion
  event, check its exit status, capture bytes, and cancel a separate operation.
- [Build command values](docs/commands.md): prepare a rename and resize, submit
  them explicitly and inspect fresh state without changing captured rows.

## More examples

- [Scoped options](docs/options.md): local ownership markers, explicit
  inheritance and sparse arrays, with a source-pinned option catalogue.
- [Buffers and paste](docs/buffers.md): preserve binary artifacts, inspect
  names and control terminal delivery.
- [Rearrange panes](docs/panes.md): isolate a running job in a window and join
  it back, preserving its process and the original snapshot.
- [Apply configuration and await a signal](docs/configuration.md): load settings
  from stdin, observe the event and verify parse-only behavior.
- [Pipe terminal output](docs/pipe.md): save a job's bytes, await its consumer
  acknowledgement and verify the resulting log.
- [Hooks and completion](docs/hooks.md): register a split callback, await its
  acknowledgement and remove the local hook.
- [Key tables](docs/keys.md): register application bindings, inspect native
  listings and remove the owned table.
- [Native commands](docs/commands-reference.md): source-derived parser metadata
  and feature minimums, separate from library API and runtime qualification.
- [API browser and source docs](docs/api.md): build searchable native reference
  pages with specs, types and links to the exact source revision.

## Packages

| Package | What it is | Hex |
| --- | --- | --- |
| [`libtmux_erlang`](apps/libtmux_erlang/README.md) | The core OTP application: servers, sessions, windows, panes, snapshots and queries. | [![libtmux_erlang](https://img.shields.io/hexpm/v/libtmux_erlang?label=libtmux_erlang)](https://hex.pm/packages/libtmux_erlang) |

### [`libtmux_erlang`](https://github.com/libtmux/libtmux-erlang/tree/master/apps/libtmux_erlang): the core application

[`tmux_server`](https://libtmux.org/en/erlang/latest/reference/tmux_server/),
[`tmux_snapshot`](https://libtmux.org/en/erlang/latest/reference/tmux_snapshot/),
[`tmux_select`](https://libtmux.org/en/erlang/latest/reference/tmux_select/) and
[`tmux_query`](https://libtmux.org/en/erlang/latest/reference/tmux_query/), with
the compiled tmux helper built from packaged source.

[![libtmux_erlang](https://img.shields.io/hexpm/v/libtmux_erlang?label=libtmux_erlang)](https://hex.pm/packages/libtmux_erlang)
[API reference](https://libtmux.org/en/erlang/latest/reference/) ·
[Documentation](https://libtmux.org/en/erlang/) ·
[Hex.pm](https://hex.pm/packages/libtmux_erlang) ·
[Changelog](apps/libtmux_erlang/CHANGELOG.md)

The examples above are this package's.
[Its README](apps/libtmux_erlang/README.md) inspects an existing socket.

## Decide whether it fits

The current path uses bounded one-shot tmux clients. Operations support
non-blocking submission, explicit waits, cancellation and ownership transfer.
An await timeout abandons that wait; it does not cancel the operation.
Cancellation after dispatch can leave the tmux outcome unknown.

An explicit control attachment verifies identity on its persistent connection
and owns its client cleanup. Control command submission and output streams remain
implementation work. The
[support and gaps](docs/compatibility.md) page lists
what is exercised, what remains open, and the required Linux/tmux matrix.
There is no control-versus-streaming performance claim.

The [project policy](docs/project-policy.md) records the OTP application
boundary and runtime dependencies.

## Verify and contribute

```console
$ time python3 tools/check.py mid
```

```console
$ time python3 tools/check.py outer
```

The outer check owns its tmux fixtures and tests installed consumers. See
[contributor setup](.github/CONTRIBUTING.md) for prerequisites and test budgets,
[CI](https://github.com/libtmux/libtmux-erlang/actions/workflows/ci.yml) for
individual release/architecture results, and the [MIT license](LICENSE).
Maintainers can follow the [Hex release instructions](.github/RELEASE.md).

[Branding assets](docs/branding.md) include the logo, icons, and social cards.

[api-with-owned]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_owned-2/
[api-related]: https://libtmux.org/en/erlang/latest/reference/tmux_snapshot-related-3/
[api-where]: https://libtmux.org/en/erlang/latest/reference/tmux_select-where-2/
[api-fetch]: https://libtmux.org/en/erlang/latest/reference/tmux_query-fetch-1/
[api-with-server]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_server-2/
[api-await]: https://libtmux.org/en/erlang/latest/reference/tmux_operation-await-2/
