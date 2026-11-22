# Update generated files

Run libtmux_erlang generators from the repository root. Edit the source first;
`--check` reports a missing or stale output without changing it.

| Change | Source | Generator | Output |
| --- | --- | --- | --- |
| Entity fields and relationships | `schema/entities.json` | `generate_schema.escript` | `tmux_schema_data.erl`, `tmux_model.erl` |
| Field and operator reference | Compiled entity schema and validator | `generate_reference.escript` | `docs/fields.md` |
| tmux commands | `schema/commands.json` | `generate_commands.erl` | `tmux_capability_data.erl`, `docs/commands-reference.md` |
| tmux options and named hooks | `schema/options.json` | `generate_options.erl` | `tmux_option_data.erl`, `docs/options-reference.md` |
| Operation support and minimum versions | `tmux_capability:manifest/0` | `generate_capabilities.erl` | `capabilities.json` |

Run the entity generator before `rebar3 compile`. All other generators read
compiled modules. After changing and compiling an operation gate:

```console
$ escript scripts/generate/generate_capabilities.erl
```

The [mid loop](../check/README.md) checks drift without a tmux checkout:

```console
$ escript scripts/check/check.erl mid
```

## Refresh command and option schemas from tmux

The catalogue generators read the commits in
[schema/tmux-sources.json](../../schema/tmux-sources.json). Use a local tmux
Git clone containing those commits. The option generator also uses a C
preprocessor to expand hook macros.

```console
$ escript scripts/generate/generate_options.erl \
    --refresh-from /path/to/tmux
```

`generate_commands.erl` accepts the same flag. Review the schema and generated
file changes together when updating a pin.
