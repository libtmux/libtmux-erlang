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
[Plan and optimise](#plan-and-optimise-a-query) ·
[Batch commands](#run-commands-together) ·
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

### [`tmux_pane:send_text/2`][api-send-text] and [`tmux_pane:capture/2`][api-capture]: type into a pane and read it back

[`tmux_pane:send_keys/2`][api-send-keys] sends named keys such as Enter. A send
returns before the program reads it, so the shell signals a tmux channel and
the program awaits that signal before it captures:

```console
$ mise exec -- escript tools/run_examples.escript typing
```

<!-- example: examples/typing_demo.erl -->

```erlang
-module(typing_demo).
-moduledoc "Type a command into a shell pane, wait for it, read the screen.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            Shell = #{argv => [<<"/bin/sh">>]},
            {ok, _} = tmux_session:create(Server, #{name => <<"typing">>,
                width => 120, height => 30, launch => Shell}),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            [Pane] = tmux_snapshot:panes(Snapshot),
            % The shell signals a tmux channel once it has printed.
            {ok, Wait} = tmux_command:wait_for(<<"typed">>, wait),
            {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
            Signal = <<"'", Executable/binary, "' wait-for -S typed">>,
            Line = <<"echo hello; ", Signal/binary>>,
            {ok, _} = tmux_pane:send_text(Pane, Line),
            {ok, _} = tmux_pane:send_keys(Pane, [enter]),
            {ok, _} = tmux_operation:await(Operation, 2000),
            {ok, Screen} = tmux_pane:capture(Pane, #{}),
            Rows = binary:split(Screen, <<"\n">>, [global]),
            true = lists:member(<<"hello">>, Rows),
            #{typed => <<"echo hello">>, screen_row => <<"hello">>}
        end),
    Result.
```

It returns:

<!-- example-output: typing_demo -->

```json
{
  "typed": "echo hello",
  "screen_row": "hello"
}
```

- [`tmux_pane:kill/1`][api-kill-pane], [`tmux_window:kill/1`][api-kill-window]
  and [`tmux_session:kill/1`][api-kill-session] remove one target.
- [`tmux_option:set/3`][api-option-set] and [`tmux_option:get/3`][api-option-get]
  write and read options; [`tmux_hook:set/3`][api-hook-set] and
  [`tmux_hook:get/3`][api-hook-get] do the same for hooks.

More: [Wait for a terminal job, then capture its output](docs/jobs.md).

## Find and filter

### [`tmux_snapshot:related/3`][api-related]: follow shared windows

A window can be linked more than once in a session, and into several sessions.
Physical windows and panes stay unique; each link keeps its session and index.

More: [Linked windows and relationship queries](docs/graph.md).

### [`tmux_select:where/2`][api-where]: filter captured rows

Filtering runs locally on captured rows and never calls tmux.
[`tmux_filter`][tmux-filter] validates a filter and encodes it as portable
JSON. This program needs no tmux server:

```console
$ mise exec -- escript tools/run_examples.escript filter
```

<!-- example: examples/filter_demo.erl -->

```erlang
-module(filter_demo).
-moduledoc "Validate portable JSON and filter captured rows without tmux I/O.".
-export([run/0]).

-spec run() -> map().
run() ->
    {ok, Editor} = tmux_model:pane(#{id => <<"%1">>, active => true,
        width => 120, current_command => <<"nvim">>}),
    {ok, Shell} = tmux_model:pane(#{id => <<"%2">>, active => false,
        width => 80, current_command => <<"bash">>}),
    Panes = tmux_select:from_list(pane, [Editor, Shell]),
    Criteria = #{active => true, 'or' => [
        #{current_command => #{in => [<<"nvim">>, <<"vim">>]}},
        #{width => #{gte => 160}}
    ]},
    {ok, Filter} = tmux_filter:new(pane, Criteria),
    Encoded = iolist_to_binary(json:encode(tmux_filter:to_wire(Filter))),
    {ok, Document} = tmux_filter:decode_json(Encoded),
    {ok, RoundTrip} = tmux_filter:from_wire(pane, Document),
    {ok, Editor} = tmux_select:one(RoundTrip, Panes),
    [Editor] = tmux_select:to_list(tmux_select:where(Filter, Panes)),
    {error, #{code := duplicate_key}} = tmux_filter:decode_json(
        <<"{\"version\":1,\"version\":2}">>),
    Invalid = #{active => #{contains => <<"yes">>}},
    try tmux_select:where(Invalid, Panes) of
        _ -> error(expected_validation_error)
    catch
        error:{bad_filter, #{code := unsupported_operator} = Detail}:Stack ->
            [active, contains] = maps:get(path, Detail),
            Reason = {bad_filter, Detail},
            Message = erl_error:format_exception(error, Reason, Stack),
            Text = unicode:characters_to_binary(Message),
            {_, _} = binary:match(Text, <<"Allowed:">>)
    end,
    #{matched_ids => [tmux_model:get(id, Editor)],
      wire_round_trip => true, duplicate_keys_rejected => true}.
```

It returns:

<!-- example-output: filter_demo -->

```json
{
  "matched_ids": ["%1"],
  "wire_round_trip": true,
  "duplicate_keys_rejected": true
}
```

- Criteria are maps or Boolean functions, with quantifiers and portable JSON.
- An unknown field or operator fails before any row is read.

More: [Local filters and source queries](docs/querying.md) ·
[Fields and operators](docs/fields.md).

### [`tmux_query:fetch/1`][api-fetch]: read tmux again

A query asks tmux when you fetch it and returns a new immutable selection.
Rows you already hold keep their values.

More: [Local filters and source queries](docs/querying.md).

## Plan and optimise a query

### [`tmux_query:explain/1`][api-explain]: see what tmux runs

`explain/1` describes a query without calling tmux. This program explains one
query twice, then fetches it and checks that the rows agree:

```console
$ mise exec -- escript tools/run_examples.escript plan
```

<!-- example: examples/plan_demo.erl -->

```erlang
-module(plan_demo).
-moduledoc "Explain a query, let tmux exclude candidates, then fetch it.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            Cat = #{launch => #{argv => [<<"/bin/cat">>]}},
            Wide = Cat#{name => <<"plan">>, width => 120, height => 30},
            {ok, Session} = tmux_session:create(Server, Wide),
            {ok, Window} = tmux_window:create(Session, Cat),
            {ok, _} = tmux_pane:split(Window, Cat#{direction => horizontal}),
            Criteria = #{width => #{lt => 100},
                current_command => <<"cat">>},
            Query = tmux_query:where(Criteria, tmux_query:panes(Server)),
            Pushed = tmux_query:pushdown(true, Query),
            % explain/1 does no I/O: it only describes what fetch would run.
            #{candidate := #{format := Local}} = tmux_query:explain(Query),
            #{candidate := #{format := Native, local_only := Kept}} =
                tmux_query:explain(Pushed),
            {ok, Everything} = tmux_query:fetch(Query),
            {ok, Narrowed} = tmux_query:fetch(Pushed),
            {ok, Isolated} = tmux_query:fetch(Pushed,
                #{hydration => isolated}),
            Ids = ids(Narrowed),
            2 = length(Ids),
            Ids = ids(Everything),
            Ids = ids(Isolated),
            #{local_candidate => Local, native_candidate => Native,
              kept_local => [maps:get(field, Reason) || Reason <- Kept],
              matched_panes => length(Ids), same_rows => true}
        end),
    Result.

ids(Selection) ->
    [tmux_model:get(id, Pane) || Pane <- tmux_select:to_list(Selection)].
```

It returns:

<!-- example-output: plan_demo -->

```json
{
  "local_candidate": "1",
  "native_candidate": "#{e|<|:#{pane_width},100}",
  "kept_local": ["tmux.pane.currentCommand"],
  "matched_panes": 2,
  "same_rows": true
}
```

- `local_candidate`: without pushdown, tmux drops nothing.
- `native_candidate`: the tmux format that drops rows before capture.
- `kept_local`: fields tmux cannot filter stay in Erlang.

More: [Source plans](docs/querying.md#source-plans).

### [`tmux_query:pushdown/2`][api-pushdown]: let tmux drop rows first

Pushdown is off by default. Turn it on to add a candidate scan that excludes
rows before capture. The full filter still runs locally, so a candidate can
admit extra rows but never hides a match.

The program above also fetches with `hydration => isolated`, which reads one
field per row when a single scan would pass the output limit.

Captures span several commands and are not atomic.

More: [Source plans](docs/querying.md#source-plans).

## Run commands together

### [`tmux_command:sequence/1`][api-sequence]: several commands, one call

Build commands without I/O, join them and run them once. A sequence is not
atomic: a failing member can leave the commands before it applied.

```console
$ mise exec -- escript tools/run_examples.escript batch
```

<!-- example: examples/batch_demo.erl -->

```erlang
-module(batch_demo).
-moduledoc "Run several commands in one tmux client and read an option batch.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            Cat = #{launch => #{argv => [<<"/bin/cat">>]}},
            {ok, Session} = tmux_session:create(Server,
                Cat#{name => <<"batch">>}),
            {ok, Window} = tmux_window:create(Session, Cat),
            Id = tmux_model:get(id, Session),
            {ok, Rename} = tmux_session:rename_command(Session, <<"batched">>),
            {ok, Stage} = tmux_command:raw(<<"set-option">>,
                [<<"-t">>, Id, <<"@stage">>, <<"built">>]),
            {ok, Owner} = tmux_command:raw(<<"set-option">>,
                [<<"-t">>, Id, <<"@owner">>, <<"batch-demo">>]),
            % Three commands, one native sequence. A failure can leave a prefix.
            {ok, Sequence} = tmux_command:sequence([Rename, Stage, Owner]),
            {ok, #{exit_status := 0}} =
                tmux_server:command(Server, Sequence, #{}),
            {ok, Renamed} = tmux_session:get(Server, Id),
            {ok, [<<"built">>, none]} =
                tmux_option:get_many([Session, Window], <<"@stage">>, #{}),
            #{commands => 3, session_name => tmux_model:get(name, Renamed),
              stage => <<"built">>, window_stage => none}
        end),
    Result.
```

It returns:

<!-- example-output: batch_demo -->

```json
{
  "commands": 3,
  "session_name": "batched",
  "stage": "built",
  "window_stage": "none"
}
```

- [`tmux_option:get_many/3`][api-get-many] reads one option from up to seven
  rows in one batch.

More: [Build command values](docs/commands.md) ·
[Scoped options](docs/options.md).

## Own a server and wait for work

### [`tmux_server:with_server/2`][api-with-server]: borrow an existing server

Closing the handle leaves the borrowed server and its sessions alone.
[`tmux_server:with_owned/2`][api-with-owned] starts a private one instead.

More: [Daemon ownership](docs/ownership.md) ·
[Control attachments](docs/control.md).

### [`tmux_control:attach/3`][api-attach]: hold a control attachment

Attach to a session over a persistent connection, check its identity on that
connection, then close it and confirm cleanup. Commands still run through
one-shot clients; control command submission and output streams are not built.

```console
$ mise exec -- escript tools/run_examples.escript control
```

<!-- example: examples/control_demo.erl -->

```erlang
-module(control_demo).
-moduledoc "Attach explicitly, inspect captured values and prove detachment.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"control-demo">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            Id = tmux_model:get(id, Session),
            0 = tmux_model:get(attached_count, Session),
            {ok, Control} = tmux_control:attach(Server, Session, #{}),
            tmux_scope:run_or_error(fun() ->
                {ok, #{phase := open, identity := same_connection}} =
                    tmux_control:status(Control),
                {ok, Attached} = tmux_session:get(Server, Id),
                1 = tmux_model:get(attached_count, Attached),
                {ok, Graph} = tmux_server:snapshot(Server),
                [Window] = tmux_snapshot:windows(Graph),
                120 = tmux_model:get(width, Window),
                30 = tmux_model:get(height, Window),
                ok = tmux_control:close(Control),
                {ok, #{phase := closed, cleanup := complete}} =
                    tmux_control:status(Control),
                {ok, Detached} = tmux_session:get(Server, Id),
                0 = tmux_model:get(attached_count, Detached),
                0 = tmux_model:get(attached_count, Session),
                #{identity => same_connection, attached_count => 1,
                  detached_count => 0, window_size => [120, 30],
                  cleanup => complete, session_preserved => true}
            end, fun() ->
                ok = tmux_control:close(Control)
            end)
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

It returns:

<!-- example-output: control_demo -->

```json
{
  "identity": "same_connection",
  "attached_count": 1,
  "detached_count": 0,
  "window_size": [120, 30],
  "cleanup": "complete",
  "session_preserved": true
}
```

More: [Control attachments](docs/control.md).

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
- **tmux:** 3.3a or newer. A release newer than the tested ones returns
  `unsupported_option_catalogue` for built-in options and hooks.
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
[tmux-filter]: https://libtmux.org/en/erlang/latest/reference/tmux_filter/
[api-with-owned]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_owned-2/
[api-related]: https://libtmux.org/en/erlang/latest/reference/tmux_snapshot-related-3/
[api-where]: https://libtmux.org/en/erlang/latest/reference/tmux_select-where-2/
[api-fetch]: https://libtmux.org/en/erlang/latest/reference/tmux_query-fetch-1/
[api-with-server]: https://libtmux.org/en/erlang/latest/reference/tmux_server-with_server-2/
[api-await]: https://libtmux.org/en/erlang/latest/reference/tmux_operation-await-2/
[api-explain]: https://libtmux.org/en/erlang/latest/reference/tmux_query-explain-1/
[api-pushdown]: https://libtmux.org/en/erlang/latest/reference/tmux_query-pushdown-2/
[api-sequence]: https://libtmux.org/en/erlang/latest/reference/tmux_command-sequence-1/
[api-get-many]: https://libtmux.org/en/erlang/latest/reference/tmux_option-get_many-3/
[api-attach]: https://libtmux.org/en/erlang/latest/reference/tmux_control-attach-3/
[api-send-text]: https://libtmux.org/en/erlang/latest/reference/tmux_pane-send_text-2/
[api-send-keys]: https://libtmux.org/en/erlang/latest/reference/tmux_pane-send_keys-2/
[api-capture]: https://libtmux.org/en/erlang/latest/reference/tmux_pane-capture-2/
[api-kill-pane]: https://libtmux.org/en/erlang/latest/reference/tmux_pane-kill-1/
[api-kill-window]: https://libtmux.org/en/erlang/latest/reference/tmux_window-kill-1/
[api-kill-session]: https://libtmux.org/en/erlang/latest/reference/tmux_session-kill-1/
[api-option-set]: https://libtmux.org/en/erlang/latest/reference/tmux_option-set-3/
[api-option-get]: https://libtmux.org/en/erlang/latest/reference/tmux_option-get-3/
[api-hook-set]: https://libtmux.org/en/erlang/latest/reference/tmux_hook-set-3/
[api-hook-get]: https://libtmux.org/en/erlang/latest/reference/tmux_hook-get-3/
