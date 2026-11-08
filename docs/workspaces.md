# Load a workspace file

Load desired sessions, windows and panes with `tmux_workspace:load/1`, then
inspect the normalized graph with `tmux_workspace:to_map/1`. The workspace
application depends on the core's public JSON API and OTP libraries.

This loader performs filesystem I/O. It does not contact tmux or launch the
programs in the file. Planning, applying changes and an installed workspace
CLI remain implementation work.

## Describe the desired graph

[This input file](../examples/workspace.json) declares one session, one window
and two panes. `endpoint` names a host-configured connection; it cannot choose
a socket. `argv` is literal executable data. `shell` explicitly requests shell
syntax for a future apply policy to authorize.

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
    ok = file:change_mode(Directory, 8#700),
    Output = try
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
    after
        ok = file:del_dir_r(Directory)
    end,
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
