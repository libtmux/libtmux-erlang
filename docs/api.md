# Build and browse the native API

Public contracts live in Erlang `-moduledoc`, `-doc` and specs. OTP's compiler
stores EEP-48 documentation chunks; ExDoc renders them into searchable module,
function and type pages. Source links open captured files with line anchors
and content digests. An unchanged file also links to its exact Git commit;
changed files are labelled as working-tree previews.

Compile the project:

```console
$ mise exec -- rebar3 compile
```

Prepare the checksum-pinned ExDoc tool. This step uses the network:

```console
$ python3 tools/build_docs.py --prepare
```

Build the browser without fetching dependencies:

```console
$ mise exec -- python3 tools/build_docs.py
```

Open `_build/docs/core/index.html`. This is a local build, not a published
HexDocs URL. The build refreshes compiled modules before rendering. The
renderer treats warnings as failures and uses the OTP 29
build of ExDoc. It consumes compiler chunks directly because the older EDoc
source-extraction path rejects native-record attributes.

## Read by task

| Task | API modules |
| --- | --- |
| Open, inspect and close an endpoint | `m:tmux_server` |
| Create and act on terminal objects | `m:tmux_session`, `m:tmux_window`, `m:tmux_pane` |
| Switch one explicitly named attached client | `tmux_session:select/2`, `tmux_session:select/3` |
| Break, join, move and swap running panes | `tmux_pane:break/4`, `tmux_pane:join/3`, `tmux_pane:move/3`, `tmux_pane:swap/3` |
| Act on session-relative window memberships | `m:tmux_window_link` |
| Read local or inherited options and change explicit tables | `m:tmux_option` |
| Register, inspect and explicitly run native hooks | `m:tmux_hook` |
| Register and remove keys in explicit server tables | `m:tmux_key` |
| Inspect native command declarations and feature minimums | `m:tmux_capability` |
| Store byte buffers and paste into a pane | `m:tmux_buffer` |
| Read a captured graph | `m:tmux_snapshot`, `m:tmux_model` |
| Filter captured data | `m:tmux_select`, `m:tmux_filter`, `m:tmux_matcher` |
| Plan source retrieval | `m:tmux_query` |
| Submit, await and cancel work | `m:tmux_operation`, `m:tmux_command` |
| Render/load configuration and build channel waits or signals | `tmux_command:to_config/1`, `tmux_command:source_file/2`, `tmux_command:wait_for/2` |
| Connect a shell consumer to live pane bytes | `tmux_pane:pipe/3`, `tmux_pane:stop_pipe/1` |
| Inspect schema and wire validation | `m:tmux_schema`, `m:tmux_json`, `m:tmux_version` |
| Inspect observed process identities | `m:tmux_identity` |

The [field reference](fields.md) is generated from the same registry and
operator validator used by filtering. [Contributor checks](../.github/CONTRIBUTING.md)
execute native shell examples and complete programs; compilation alone is
not the example gate.
