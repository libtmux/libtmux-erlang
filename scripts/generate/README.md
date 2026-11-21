# generate

Generators for the tmux source catalogues. Each one turns a checked-in JSON
schema into an Erlang data module and a Markdown reference, and can rebuild
that schema from the pinned tmux sources.

| Script | Schema | Generated files |
| --- | --- | --- |
| `generate_commands.erl` | `schema/commands.json` | `tmux_capability_data.erl`, `docs/commands-reference.md` |
| `generate_options.erl` | `schema/options.json` | `tmux_option_data.erl`, `docs/options-reference.md` |

`generate_capabilities.erl` exports the compiled `tmux_capability` operation
gates to the root and packaged `capabilities.json`. It does not regenerate the
native command catalogue or claim that every native command has a typed API.
Compile registry changes before writing or checking the manifests:

```console
$ mise exec -- escript scripts/generate/generate_capabilities.erl
```

```console
$ mise exec -- escript scripts/generate/generate_capabilities.erl --check
```

Both read the pinned tmux commits from
[schema/tmux-sources.json](../../schema/tmux-sources.json) and refuse a schema
whose sources differ from those pins. Maintainers run them after changing a
schema or the pins. The mid-loop check runs `--check`; package consumers need
neither the generators nor a tmux checkout.

## Check for drift

The scripts load the compiled library and their helper modules from `_build`,
so compile first:

```console
$ mise exec -- rebar3 compile
```

`--check` exits 1 and names the first generated file that differs from its
schema. It reads no tmux checkout.

```console
$ mise exec -- escript scripts/generate/generate_commands.erl --check
```

```console
$ mise exec -- escript scripts/generate/generate_options.erl --check
```

## Regenerate

Without a flag, each script validates its schema and rewrites its generated
files. Never edit the generated files by hand.

```console
$ mise exec -- escript scripts/generate/generate_commands.erl
```

## Refresh the schema from tmux

`--refresh-from` rebuilds the schema from the pinned commits in a local tmux
Git clone, then regenerates. Each pinned commit must exist in the clone;
`git -C <clone> cat-file -e <commit>` checks one. The options generator also
needs a C preprocessor (`cc -E -P`) to expand hook macros.

```console
$ mise exec -- escript scripts/generate/generate_options.erl \
    --refresh-from /path/to/tmux
```

A refresh that leaves the schema unchanged proves the pins and the extraction
agree. A changed schema is a review item: the diff must match the pin change.

## Modules

- `generate_catalogue`: the manifest, command line, schema round trip, drift
  check and the readers for tmux's C sources, shared by both generators.
- `generate_json`: JSON that keeps object key order and indents by two spaces,
  so schema diffs stay small. An object is a list of `{Key, Value}` pairs
  because Erlang maps do not keep order.

`refresh/2` in each generator takes its source reader as a fun, so tests supply
fixtures instead of a tmux clone.

## Tests

The unit tests in `tests/` cover the writer's text, every rejected source shape
and schema, and the drift check. One test reads a temporary Git repository and
runs `cc`. `rebar3 eunit` alone skips `scripts/`; select it with `--dir`:

```console
$ mise exec -- rebar3 eunit --dir=scripts
```
