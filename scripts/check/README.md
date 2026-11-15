# check

Runs the repository's development checks in three loops and keeps evidence for
each command.

- `inner --module MODULE` runs one EUnit module, under 5 seconds.
- `mid` compiles the library and scripts, checks the generated sources and
  runs the unit tests, the documentation corpus and the whitespace check,
  under 30 seconds.
- `outer` compiles, runs Dialyzer, Common Test, the reader examples and the
  installed-archive consumer, under 5 minutes.

The commands of each tier are listed in `check.erl`. Each runs under the
remaining budget; the first failure or timeout ends the loop. Output goes to
`_build/checks/<tier>-<n>.log` and a receipt to `_build/checks/<tier>.json`.
Outside GitHub Actions each command runs through `mise exec --`. The default
`ERL_FLAGS` is `+S 4:4`.

The runner uses no helper module, because it runs before the library is
compiled. Run it from anywhere:

```console
$ escript scripts/check/check.erl mid
```

Run its tests with:

```console
$ rebar3 eunit --module=check_tests
```
