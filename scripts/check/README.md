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

A command that overruns its remaining budget is killed together with every
process it started, including one that moved to another session or process
group. Each command's environment carries `LIBTMUX_CHECK_RUN`, and the runner
kills the processes whose `/proc/<pid>/environ` names that run, then rescans
until none is left. Without `/proc` it kills only the command itself. It needs
a `kill` executable on `PATH`.

The runner loads the fixture helper before it compiles the library. The helper
starts each run with a private directory and clears inherited tmux selectors.
Cleanup requires the original directory and reports any remaining sockets.

Run it from anywhere:

```console
$ escript scripts/check/check.erl mid
```

Run its tests with:

```console
$ rebar3 eunit --module=check_tests
```
