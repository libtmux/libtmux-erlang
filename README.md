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

</div>

Create tmux sessions, windows and panes from Erlang. Capture their object graph,
filter it as immutable data, and execute source queries and owned operations
explicitly.

## Install

Use Erlang/OTP **29.1.2**, Rebar3 **3.28.0**, Linux, tmux **3.3 or newer**, and
`make` with a C11 compiler. Native records are experimental in OTP 29. The core
uses OTP libraries and a compiled external helper, with no NIF or third-party
runtime packages.

This checkout is unreleased. Add its core application to your `rebar.config`:

<!-- erlang-term -->

```erlang
{deps, [
    {libtmux_erlang, {git_subdir,
        "https://github.com/libtmux/libtmux-erlang.git",
        {branch, "master"}, "apps/libtmux_erlang"}}
]}.
```

Commit `rebar.lock` to keep the resolved commit. The
[installation guide](docs/installation.md) covers application startup and
building a consumer. No Hex release is advertised.

## Create, capture and query

From this checkout, compile with the pinned tools:

```console
$ mise exec -- rebar3 compile
```

Run the complete program below on a private tmux server:

```console
$ mise exec -- escript tools/run_examples.escript readme
```

The runner needs Python 3.12+ for its readiness watcher. It allocates a unique
socket, verifies the example's assertions, and retires its owned server and
clients. It leaves your existing tmux sessions alone. The Erlang program uses
only public core APIs; the archive check also runs it outside this checkout.
Save it as `readme_demo.erl` when reusing it in an application.

<!-- example: examples/readme_demo.erl -->

```erlang
-module(readme_demo).
-moduledoc "Create a workspace, query its graph and preserve captured values.".
-export([run/2]).
-import_record(tmux_model, [pane]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    try
        {ok, Session} = tmux_session:create(Server, #{name => <<"workspace">>,
            window_name => <<"editor">>, width => 120, height => 30,
            launch => #{argv => [<<"/bin/cat">>]}}),
        try
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
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
```

The result includes this checked output. Captured rows keep their original
values after a rename; actions and `fetch` perform explicit I/O.

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

A window can have several links in one session and belong to more than one
session. Physical windows and panes remain unique; window links retain each
session/index membership.

- [Linked windows and relationship queries](docs/graph.md): build two sessions,
  link a shared window twice, and verify physical and membership counts.
- [Run a job and capture its result](docs/jobs.md): wait for a pane's completion
  event, check its exit status, capture bytes, and cancel a separate operation.
- [Local filters and source queries](docs/querying.md): Boolean criteria,
  quantifiers, portable JSON, cardinality, coverage and execution plans.
- [Fields and operators](docs/fields.md): generated from the runtime schema.
- [Scoped options](docs/options.md): local ownership markers, explicit
  inheritance and sparse arrays, with a source-pinned option catalogue.
- [Buffers and paste](docs/buffers.md): preserve binary artifacts, inspect
  names and control terminal delivery.
- [Rearrange panes](docs/panes.md): isolate a running job in a window and join
  it back, preserving its process and the original snapshot.
- [Apply configuration and await a signal](docs/configuration.md): load settings
  from stdin, observe the event and verify parse-only behavior.
- [API browser and source docs](docs/api.md): build searchable native reference
  pages with specs, types and links to the exact source revision.

## Decide whether it fits

The current path uses bounded one-shot tmux clients. Operations support
non-blocking submission, explicit waits, cancellation and ownership transfer.
An await timeout abandons that wait; it does not cancel the operation.
Cancellation after dispatch can leave the tmux outcome unknown.

Persistent control mode, output streams and the workspace CLI remain
implementation work. The [support and gaps](docs/compatibility.md) page lists
what is exercised, what remains open, and the required Linux/tmux matrix.
There is no control-versus-streaming performance claim.

The [project policy](docs/project-policy.md) keeps core and workspace in
separate OTP applications with OTP runtime dependencies. MCP is excluded from
this port's scope.

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

[Branding assets](docs/branding.md) include the logo, icons, and social cards.
