# Update generated files

Edit the source for the change, then run its generator from the repository root.
Each generator also accepts `--check` to report a missing or stale output.

| Change | Source | Generator | Output |
| --- | --- | --- | --- |
| Entity fields and relationships | `schema/entities.json` | `generate_schema.escript` | `tmux_schema_data.erl`, `tmux_model.erl` |
| Field and operator reference | Compiled entity schema and validator | `generate_reference.escript` | `docs/fields.md` |
| tmux commands | `schema/commands.json` | `generate_commands.erl` | `tmux_capability_data.erl`, `docs/commands-reference.md` |
| tmux options and named hooks | `schema/options.json` | `generate_options.erl` | `tmux_option_data.erl`, `docs/options-reference.md` |
| Operation support and minimum versions | `tmux_capability:manifest/0` | `generate_capabilities.erl` | `capabilities.json` |

Run the entity generator before compiling when you change `schema/entities.json`.
The field reference, catalogues and capability manifest read compiled modules.

```console
$ mise exec -- rebar3 compile
```

After updating an operation gate and compiling, write the manifest.

```console
$ mise exec -- escript scripts/generate/generate_capabilities.erl
```

The [mid loop](../check/README.md) runs the drift checks. It uses the tracked
schemas and compiled modules, so it needs no tmux checkout.

```console
$ mise exec -- escript scripts/check/check.erl mid
```

## Refresh command and option schemas from tmux

The catalogue generators read the commits in
[schema/tmux-sources.json](../../schema/tmux-sources.json). Use a local tmux
Git clone containing those commits. The option generator also uses a C
preprocessor to expand hook macros.

```console
$ mise exec -- escript scripts/generate/generate_options.erl \
    --refresh-from /path/to/tmux
```

`generate_commands.erl` accepts the same flag. Review the schema and generated
file changes together when updating a pin.
