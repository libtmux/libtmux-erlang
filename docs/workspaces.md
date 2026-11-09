# Plan and apply a workspace

Load desired sessions, windows and panes with the workspace application's
load function, then inspect the normalized graph with its to_map function. The
workspace application depends on the core's public JSON API and OTP libraries.

Loading performs filesystem I/O. Planning observes tmux without mutations;
applying executes the saved operations. The standalone CLI uses the same
workspace application and the core's public one-shot operations.

## Describe the desired graph

[This input file](../examples/workspace.json) declares one session, one window
and two panes. `endpoint` names a host-configured connection; it cannot choose
a socket. `argv` is literal executable data. `shell` explicitly requests shell
syntax. Apply requires both the plan's shell opt-in and host policy approval.

<!-- example-input: examples/workspace.json -->

```json
{
  "version": 1,
  "id": "demo",
  "endpoint": "dev",
  "sessions": [
    {
      "name": "editor",
      "windows": [
        {
          "name": "api",
          "layout": "even-horizontal",
          "panes": [
            {"cwd": ".", "argv": ["rebar3", "shell"]},
            {"cwd": ".", "shell": "exec erl"}
          ]
        }
      ]
    }
  ]
}
```

Relative working directories use the canonical workspace file directory.
Symlinks resolve before `..`; directories must already exist. There is no
environment interpolation. Each pane requires exactly one launch form.

An explicit `id` keeps workspace identity stable when moving the file.
Otherwise the loader hashes its canonical filename. Optional entity `key`
fields identify sessions, windows and panes across edits. Without a key, the
loader uses the entry's JSON pointer; reordering entries changes identity.
Keys must be unique across the workspace.

Explicit keys preserve identity when reordering entries. Apply orders managed
windows and panes as listed, preserving unmanaged resources. Changing argv or
cwd plans a respawn: it replaces that pane's running process. Current command
names cannot reconstruct the original launch.

## Build the CLI

Use the pinned OTP and Rebar3 toolchain plus the Linux C11 build prerequisites
in [Contributing](../.github/CONTRIBUTING.md#setup). From this source checkout:

```console
$ mise exec -- rebar3 escriptize
```

Inspect the command help:

```console
$ mise exec -- _build/default/bin/libtmux-workspace --help
```

The resulting escript includes the compiled helper, its MIT license and source
provenance. Each invocation materializes those assets in an owned temporary
directory, starts its core application, closes its endpoint and removes the
directory before returning its JSON result. BEAM modules remain in the archive.
Run the copied escript with OTP 29.1.2 installed on the same Linux architecture.
It needs neither a compiler nor this checkout at runtime. Registry publication
is a separate gate; no published workspace version is claimed here.

## Configure the endpoint

Create a trusted host configuration file. Replace the socket path below with
the absolute path of your existing tmux server; no default server is selected
or started. The optional executable is an absolute tmux path, otherwise PATH
selects it. Workspace input cannot override either path.

<!-- example-input: examples/workspace_host.json -->

```json
{
  "version": 1,
  "allowShell": false,
  "endpoints": {
    "dev": {"socketPath": "/tmp/project/tmux.sock"}
  }
}
```

Save that file as host.json. The CLI also accepts LIBTMUX_WORKSPACE_CONFIG
when the config option is omitted. Shell launches need host allowShell true
and an explicit allow-shell option when creating the plan.

## Review a plan, then execute it

The [argv-only example](../examples/workspace_apply.json) declares a session,
one window and two long-lived panes. Replace cat with your own programs after
trying the complete owned-server example below. From the checkout, plan it:

```console
$ mise exec -- _build/default/bin/libtmux-workspace plan \
    examples/workspace_apply.json \
    --config host.json \
    --output plan.json
```

Planning writes canonical JSON with mode 0600 and prints its hash and step
count. The file records stable targets, ownership, preconditions, schema and
input hashes. It retains the source filename and observed names, while omitting
launch argv, shell text and cwd. Review it before applying:

```console
$ mise exec -- _build/default/bin/libtmux-workspace apply plan.json \
    --config host.json
```

Apply reloads the desired file and verifies its hash. It checks that the stored
operations follow from that file and the stored observation, then executes
exactly those operations. Fresh state can reject the plan; it never supplies
replacement operations. Each step checks IDs, names, memberships, pane order,
layouts and ownership before and after its command. Captures span commands,
so concurrent changes can still intervene.
There is no atomic reservation, automatic retry or terminal-effect rollback.

Ownership reads use at most three workers and retain the captured row order.
Cancellation stops the next batch and drains reads already in flight before
returning. Their core operation deadlines still apply individually; there is
no separate batch deadline. Lost results leave cleanup unverified, and a
later cleanup failure remains visible alongside an earlier metadata error.

Pane creation uses fixed targets and the saved unzoomed layout. It distributes
splits across tiled cells, then applies the requested arrangement and pane
order. Floating cells are excluded. For a new window, the plan stores a
breadth-first target schedule; apply chooses the longer usable axis from each
checked cell. Available area and options such as reserved scrollbars can
still reject a split. The failure retains the completed prefix; apply never
substitutes another target. A pane count within the file limit does not promise
that the server's window geometry can accommodate it.

Run the plan command again with unchanged managed state: its step count is
zero. An existing untagged session/window name instead conflicts. To adopt it,
add one adopt option for each explicit resource key you intend to manage;
pane adoption respawns its ordered target. Linked windows with another
membership, duplicate ownership and missing/tampered metadata conflict.
Removal requires matching ownership for the whole affected subtree.

Machine stdout contains one JSON line. OTP diagnostics use stderr. Exit codes
are 0 for success, 2 for validation, 3 for changed input or observed conflict,
and 4 for operational failure, cancellation or uncertain outcome. Failures
retain the verified completed prefix and native command outcome separately.
A native creation can return success while its process exits before observation;
that returns creation_not_observed with the reported IDs for explicit recovery.

SIGTERM requests cancellation and waits for owned client cleanup. A command
possibly delivered to tmux can return unknown; earlier steps remain applied.
Ctrl-C uses OTP's separate VM break path and has no qualified JSON-receipt
guarantee. Abrupt process death also has no CLI temporary-file cleanup promise.
Cancellation in Erlang uses an application-owned reference and a cancel message,
as documented by the apply module.

The initial execution strategy recaptures the complete projected graph per
step. It favors drift detection over source-call cost; large-workspace
performance remains unqualified. See [snapshot costs](querying.md).

## Run the complete apply example

This program owns its tmux server, applies a real input/plan file, inspects the
resulting object graph and verifies an empty second plan. Scope cleanup keeps
operation and cleanup failures together, then retires the owned server.

```console
$ mise exec -- escript tools/run_examples.escript workspace-apply
```

<!-- example: examples/workspace_apply_demo.erl -->

```erlang
-module(workspace_apply_demo).
-moduledoc "Apply a workspace and verify an empty second plan.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    Directory = <<"/tmp/ltm-workspace-apply-", Suffix/binary>>,
    ok = file:make_dir(Directory),
    Result = tmux_scope:run_or_error(fun() ->
        ok = file:change_mode(Directory, 8#700),
        Source = filename:join(Directory, <<"workspace.json">>),
        PlanFile = filename:join(Directory, <<"plan.json">>),
        {ok, _} = file:copy("examples/workspace_apply.json", Source),
        {ok, Output} = tmux_server:with_owned(#{executable => Executable},
            fun(Server) ->
                {ok, Plan} = tmux_workspace_plan:new(Source, Server, #{}),
                ok = tmux_workspace_plan:write(Plan, PlanFile),
                {ok, Stored} = tmux_workspace_plan:read(PlanFile),
                {ok, #{completed := Completed}} =
                    tmux_workspace_apply:run(Stored, Server, #{}),
                true = length(Completed) > 0,
                {ok, Snapshot} = tmux_server:snapshot(Server),
                [Session] = tmux_snapshot:sessions(Snapshot),
                <<"project">> = tmux_model:get(name, Session),
                {ok, [Window]} =
                    tmux_snapshot:related(windows, Session, Snapshot),
                <<"api">> = tmux_model:get(name, Window),
                {ok, Panes} = tmux_snapshot:related(panes, Window, Snapshot),
                2 = length(Panes),
                {ok, Settled} = tmux_workspace_plan:new(Source, Server, #{}),
                #{<<"steps">> := []} = tmux_workspace_plan:to_map(Settled),
                {ok, #{completed := []}} =
                    tmux_workspace_apply:run(Settled, Server, #{}),
                #{sessions => 1, windows => 1, panes => 2,
                  plan_round_trip => true, second_plan_empty => true}
            end),
        Output
    end, fun() -> file:del_dir_r(Directory) end),
    {error, enoent} = file:read_file_info(Directory),
    Result#{files_removed => true}.
```

<!-- example-output: workspace_apply_demo -->

```json
{
  "sessions": 1,
  "windows": 1,
  "panes": 2,
  "plan_round_trip": true,
  "second_plan_empty": true,
  "files_removed": true
}
```

## Read and inspect it

Compile this checkout first:

```console
$ mise exec -- rebar3 compile
```

Run the complete program below:

```console
$ mise exec -- escript tools/run_examples.escript workspace
```

The program copies the real JSON file to an owned temporary directory, checks
the desired object graph and canonical cwd, and verifies removal of its files.
The outer check repeats it using installed core and workspace OTP archives.

<!-- example: examples/workspace_demo.erl -->

```erlang
-module(workspace_demo).
-moduledoc "Load a real workspace file and inspect its desired object graph.".
-export([run/0]).

-spec run() -> map().
run() ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    Directory = <<"/tmp/ltm-workspace-demo-", Suffix/binary>>,
    ok = file:make_dir(Directory),
    Output = tmux_scope:run_or_error(fun() ->
        ok = file:change_mode(Directory, 8#700),
        Path = filename:join(Directory, <<"workspace.json">>),
        {ok, _} = file:copy("examples/workspace.json", Path),
        {ok, Workspace} = tmux_workspace:load(Path),
        #{id := Id, endpoint := Endpoint, sessions := [Session]} =
            tmux_workspace:to_map(Workspace),
        #{name := SessionName, windows := [Window]} = Session,
        #{name := WindowName, layout := <<"even-horizontal">>,
          panes := [Build, Shell]} = Window,
        #{cwd := Directory, launch := #{argv := Arguments}} = Build,
        [<<"rebar3">>, <<"shell">>] = Arguments,
        #{cwd := Directory, launch := #{shell := <<"exec erl">>}} = Shell,
        #{workspace_id => Id, endpoint => Endpoint,
          session => SessionName, window => WindowName, panes => 2,
          first_pane_key => maps:get(key, Build), canonical_cwd => true,
          shell_declared => true, launched => false}
    end, fun() ->
        ok = file:del_dir_r(Directory)
    end),
    {error, enoent} = file:read_file_info(Directory),
    Output#{files_removed => true}.
```

<!-- example-output: workspace_demo -->

```json
{
  "workspace_id": "demo",
  "endpoint": "dev",
  "session": "editor",
  "window": "api",
  "panes": 2,
  "first_pane_key": "/sessions/0/windows/0/panes/0",
  "canonical_cwd": true,
  "shell_declared": true,
  "launched": false,
  "files_removed": true
}
```

## Handle validation failures

Errors include a source basename, a `code` and a JSON `path` with zero-based
array indexes. Unknown fields, duplicate JSON object keys and duplicate
entity keys fail before any tmux operation. A pane with both launch forms
returns `ambiguous_launch`; a nonexistent directory returns `invalid_directory`.

The loader accepts version 1, at most 256 KiB of JSON and 32 nested
containers. Collections contain 1–64 entries and a workspace has at most
2048 entities. IDs and keys use at most 128 UTF-8 bytes; names use at most
256. Names exclude controls and backslashes; session names also exclude
periods and colons because tmux rewrites them. Launch argv has at most 256
elements and a 32 KiB aggregate bound. Layouts use the five standard named
tmux arrangements.

Local filesystem checks are synchronous and assume trusted directories.
They provide byte bounds and canonicalization, not a filesystem sandbox,
an I/O deadline or protection against concurrent replacement of path entries.
See the [API browser](api.md) for native types and
[project policy](project-policy.md) for application boundaries.
