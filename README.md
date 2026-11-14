<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-512.png" width="128" height="128" alt="libtmux for Erlang">
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
  <a href="https://github.com/libtmux/libtmux-erlang/actions/workflows/ci.yml"><img src="https://github.com/libtmux/libtmux-erlang/actions/workflows/ci.yml/badge.svg" alt="Erlang checks"></a>
  <a href="https://hex.pm/packages/libtmux_erlang"><img src="https://img.shields.io/hexpm/v/libtmux_erlang?label=libtmux_erlang" alt="libtmux_erlang"></a>
  <a href="https://libtmux.org/en/erlang/"><img src="https://img.shields.io/badge/docs-libtmux.org-0b7285" alt="libtmux.org"></a>
  <a href="https://github.com/libtmux/libtmux-erlang/blob/master/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="license"></a>
</p>

</div>

Drive tmux from Erlang: create [sessions][tmux-session],
[windows][tmux-window] and [panes][tmux-pane], capture the
[object graph][tmux-snapshot] as immutable data, filter it, ask tmux again.

[Install](#install) ·
[Create, capture and query](#create-capture-and-query) ·
[Find and filter](#find-and-filter) ·
[Own a server](#own-a-server-and-wait-for-work) ·
[Packages](#packages) ·
[Core package](apps/libtmux_erlang/README.md) ·
[Support](#support-and-status) ·
[Changelog](CHANGELOG.md)

## Install

It needs:

- Erlang/OTP 29 and Rebar3.
- tmux 3.3a or newer, on Linux (including WSL).
- `make` and a C11 compiler, to build the bundled helper.

Add the core from [Hex](https://hex.pm/packages/libtmux_erlang) to your
`rebar.config`:

<!-- erlang-term -->

```erlang
{deps, [{libtmux_erlang, "0.0.1"}]}.
```

The API is still developing. Pin an exact version and commit `rebar.lock`.

More: [installation guide](docs/installation.md).

## Create, capture and query

### [`tmux_server:with_owned/2`][api-with-owned]: create a private tmux graph

The example below uses four modules:

- [`tmux_server`][tmux-server]: owns the connection and the server's lifetime.
- [`tmux_snapshot`][tmux-snapshot]: holds captured rows.
- [`tmux_select`][tmux-select]: filters those rows locally.
- [`tmux_query`][tmux-query]: asks tmux again when fetched.

From a checkout of this repository, compile it:

```console
$ mise exec -- rebar3 compile
```

Run it on a private tmux server:

```console
$ mise exec -- escript tools/run_examples.escript readme
```

It starts an empty daemon on its own socket, then stops that daemon and its
clients. Your existing sessions are untouched. To reuse the program, save it as
`readme_demo.erl`.

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

It returns:

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

- Captured rows keep their values after the rename. Actions and `fetch` do I/O.
- `with_owned/2` returns after verified cleanup. If cleanup fails, the error
  keeps the callback's outcome and the ownership token.

More: [Daemon ownership](docs/ownership.md).

## Find and filter

### [`tmux_snapshot:related/3`][api-related]: follow shared windows

A window can be linked more than once in a session, and into several sessions.
Physical windows and panes stay unique; each link keeps its session and index.

More: [Linked windows and relationship queries](docs/graph.md).

### [`tmux_select:where/2`][api-where]: filter captured rows

Filtering runs locally on captured rows and never calls tmux. Criteria are
maps or Boolean functions, with quantifiers and portable JSON.

More: [Local filters and source queries](docs/querying.md) ·
[Fields and operators](docs/fields.md).

### [`tmux_query:fetch/1`][api-fetch]: read tmux again

A query asks tmux when you fetch it and returns a new immutable selection.
Rows you already hold keep their values.

More: [Local filters and source queries](docs/querying.md).

## Own a server and wait for work

### [`tmux_server:with_server/2`][api-with-server]: borrow an existing server

Closing the handle leaves the borrowed server and its sessions alone.
[`tmux_server:with_owned/2`][api-with-owned] starts a private one instead.

More: [Daemon ownership](docs/ownership.md) ·
[Control attachments](docs/control.md).

### [`tmux_operation:await/2`][api-await]: wait for submitted work

Submit an operation without blocking, then await it, cancel it or hand it to
another process. Capture a job's exit status and output bytes.

More: [Run a job and capture its result](docs/jobs.md) ·
[Build command values](docs/commands.md).

## More examples

- [Scoped options](docs/options.md): local, inherited and sparse-array options.
- [Buffers and paste](docs/buffers.md): binary data and terminal delivery.
- [Rearrange panes](docs/panes.md): move a running job to its own window and
  back.
- [Apply configuration and await a signal](docs/configuration.md): load
  settings from stdin.
- [Pipe terminal output](docs/pipe.md): save a job's bytes to a log.
- [Hooks and completion](docs/hooks.md): register a split hook and remove it.
- [Key tables](docs/keys.md): add application bindings and remove them.
- [Native commands](docs/commands-reference.md): parser metadata and feature
  minimums for each tmux command.
- [API browser and source docs](docs/api.md): build the reference pages with
  specs, types and source links.

## Packages

| Package | What it is | Hex |
| --- | --- | --- |
| [`libtmux_erlang`](apps/libtmux_erlang/README.md) | The core OTP application: servers, sessions, windows, panes, snapshots and queries. | [![libtmux_erlang](https://img.shields.io/hexpm/v/libtmux_erlang?label=libtmux_erlang)](https://hex.pm/packages/libtmux_erlang) |

### [`libtmux_erlang`](https://github.com/libtmux/libtmux-erlang/tree/master/apps/libtmux_erlang): the core application

Servers, sessions, windows, panes, snapshots and queries, with a bundled C
helper for bounded tmux I/O.

[![libtmux_erlang](https://img.shields.io/hexpm/v/libtmux_erlang?label=libtmux_erlang)](https://hex.pm/packages/libtmux_erlang)
[API reference](https://libtmux.org/en/erlang/latest/reference/) ·
[Documentation](https://libtmux.org/en/erlang/) ·
[Hex.pm](https://hex.pm/packages/libtmux_erlang) ·
[Changelog](apps/libtmux_erlang/CHANGELOG.md)

More: [package README](apps/libtmux_erlang/README.md) inspects an existing
socket.

## Support and status

- **Status:** early. Any release may change the API.
- **Platform:** Linux, including WSL. macOS and native Windows are not
  advertised.
- **tmux:** 3.3a or newer.
- **Erlang/OTP:** 29 only. The application refuses to start on another release.
  Rows are native records, which OTP 29 marks experimental.
- **Dependencies:** OTP only. The helper is an external program, not a NIF.
- **Operations:** an await timeout abandons the wait; it does not cancel the
  operation. Cancelling after dispatch can leave the tmux outcome unknown.

More: [Support and gaps](docs/compatibility.md) ·
[Project policy](docs/project-policy.md).

## What it leaves out

- **Control command submission and output streams.** Control attachments
  verify their connection and clean up their client; commands still run
  through one-shot clients.

## Contribute

Run `mid` while you work and `outer` before a pull request:

```console
$ time python3 tools/check.py mid
```

```console
$ time python3 tools/check.py outer
```

- [Contributor setup](.github/CONTRIBUTING.md): prerequisites and test budgets.
- [CI](https://github.com/libtmux/libtmux-erlang/actions/workflows/ci.yml):
  results per commit.
- [Hex release instructions](.github/RELEASE.md), for maintainers.
- [Branding assets](docs/branding.md): logo, icons and social cards.
- [MIT license](LICENSE).

[tmux-session]: https://libtmux.org/en/erlang/latest/reference/tmux_session/
[tmux-window]: https://libtmux.org/en/erlang/latest/reference/tmux_window/
[tmux-pane]: https://libtmux.org/en/erlang/latest/reference/tmux_pane/
[tmux-server]: https://libtmux.org/en/erlang/latest/reference/tmux_server/
[tmux-snapshot]: https://libtmux.org/en/erlang/latest/reference/tmux_snapshot/
[tmux-select]: https://libtmux.org/en/erlang/latest/reference/tmux_select/
[tmux-query]: https://libtmux.org/en/erlang/latest/reference/tmux_query/
[api-with-owned]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_owned-2/
[api-related]: https://libtmux.org/en/erlang/latest/reference/tmux_snapshot-related-3/
[api-where]: https://libtmux.org/en/erlang/latest/reference/tmux_select-where-2/
[api-fetch]: https://libtmux.org/en/erlang/latest/reference/tmux_query-fetch-1/
[api-with-server]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_server-2/
[api-await]: https://libtmux.org/en/erlang/latest/reference/tmux_operation-await-2/
