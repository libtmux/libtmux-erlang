# Choose a feature for the selected daemon

Read the endpoint's captured daemon version, then ask
`tmux_capability:decision/2` whether an operation's native version requirement
is met. `supported = false` can mean that an older-daemon fallback is used;
inspect `handling` and `fallback` before rejecting the operation.

This program starts a private daemon through the library, prints the JSON
layout and control decisions, and proves owned cleanup before returning:

```console
$ mise exec -- escript tools/run_examples.escript capabilities
```

<!-- example: examples/capability_demo.erl -->

```erlang
-module(capability_demo).
-moduledoc "Inspect daemon feature decisions inside an owned endpoint scope.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            {ok, Vsn} = tmux_server:version(Server),
            {ok, Layout} = tmux_capability:decision(Vsn, layout_json),
            {ok, Control} = tmux_capability:decision(Vsn, control_no_detach),
            {error, #{code := unknown_capability}} =
                tmux_capability:decision(Vsn, unknown),
            #{daemon_version => tmux_version:format(Vsn),
              json_layout => maps:with([supported, minimum, handling], Layout),
              control => maps:with([supported, handling, fallback], Control)}
        end),
    Result.
```

The output includes `daemon_version`, `json_layout` and `control`. JSON layout
admission requires tmux 3.8. Control attachment on older releases omits
`no-detach-on-destroy`; it can detach when its session is destroyed.

## Discover gates and errors

- `tmux_capability:features/0` lists the known feature atoms.
- `describe/1` returns their minimum release, APIs, native commands and
  older-release behavior. `decision/2` adds `supported` for a parsed version.
- `require/2` returns `unsupported_capability` with the requested capability
  and minimum release. Unknown names return `unknown_capability`; malformed
  versions return `invalid_version`.
- These calls perform no I/O. A decision permits no target mutation and
  establishes no daemon liveness or security boundary.

The registry drives existing buffer and control gates. Some native command
features expose only `require/2`; their metadata names that API explicitly.
A generated command declaration alone is not a typed operation.

## Version and observation boundaries

`tmux_server:version/1` returns the daemon version observed when the endpoint
was opened, not the client executable's `-V` output. It is a cached
observation. Commands retain their existing identity checks and refuse a
replaced daemon; an old decision never refreshes target authority.

Opening and command preflight use the native `list-commands` bootstrap to
avoid after-hooks. The exact spelling must remain unaliased. An override can
run arbitrary server code; discovery does not audit aliases through
`show-options`, which can itself run after-hooks.

Minimum checks order `next-3.8`, `3.8-rc1`, `3.8-rc2`, `3.8`, then `3.8a`.
They compare numeric minor and RC components. A version meeting a minimum is
not proof that a custom or future build was tested. Exact native catalogues
still refuse tracking builds, RCs and releases absent from their source data.

The library floor is 3.3a. The operation manifest can name an earlier feature
minimum independently of that floor. Native catalogue entries record the
first sampled release, not necessarily their historical upstream introduction.

## Package and migration

The generated [capabilities.json](../capabilities.json) contains operation
gates from this registry. The OTP archive and Hex source package carry the
same file; installed consumers can also call `tmux_capability:manifest/0`.
Informational buffer-name and rename behavior remains discoverable through
`decision/2` and is omitted from the operation manifest.

`describe/1` now returns a binary minimum such as `<<"3.8">>` instead of a
numeric pair. Use `tmux_version:at_least/2` for comparisons. Parsed versions
include a `candidate` field, and development builds no longer satisfy the
corresponding stable minimum. Reparse retained version text after upgrading.

The generated [native command reference](commands-reference.md) owns the
pinned upstream source evidence. Managed Program handles, pane waits, MCP
and control output streams remain separate work; this registry does not
implement them.
