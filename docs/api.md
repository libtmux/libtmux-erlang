# Build and browse the native API

Core and workspace contracts live in Erlang `-moduledoc`, `-doc` and specs.
OTP's compiler stores EEP-48 documentation chunks; ExDoc renders searchable module,
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
| Load and inspect desired workspace files | `m:tmux_workspace` |
| Inspect observed process identities | `m:tmux_identity` |

The [field reference](fields.md) is generated from the same registry and
operator validator used by filtering. [Contributor checks](../.github/CONTRIBUTING.md)
execute native shell examples and complete programs; compilation alone is
not the example gate.

## Types at application boundaries

Entity constructors accept generated maps such as
`t:tmux_model:pane_input/0`. Required fields and scalar categories are visible
to Dialyzer. Optional observations retain `not_loaded` and `unavailable`;
nullable fields also accept `none`. Numeric fields accept integral floats,
which normalize to integers. Runtime validation checks bounds, ID syntax,
UTF-8 and derived values. Use `tmux_model:new/2` when validating dynamic maps
and handle its `t:tmux_schema:error_detail/0` result.

`t:tmux_select:t/1` describes the intended row type. Dialyzer in OTP 29.1.2
does not always substitute actual argument types into generic return
variables. For example, a selection passed through `tmux_select:one/1` can
lose its specific entity type during analysis. A successful analysis does
not prove every pane/window relationship. Keep native patterns and runtime
action validation at those boundaries. The
[OTP contract solver](https://github.com/erlang/otp/blob/OTP-29.1.2/lib/dialyzer/src/dialyzer_contracts.erl#L477-L502)
records this generic constraint limitation.

The installed-consumer outer check executes valid constructor calls and
requires Dialyzer to reject wrong Boolean/numeric fields and missing session
identity or window-link index. It analyzes the installed core outside the
umbrella; a green library analysis alone does not establish those diagnostics.
