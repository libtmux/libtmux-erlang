# script_util

Shared helpers for the Erlang scripts under `scripts/`: run a command with a
deadline and bounded output, run `git`, hash a file and create a private
temporary directory.

Scripts call it through the library's packaged helper, so build the library
first. The module documents the three lines a script's `main/1` starts with.

Rebar3 compiles `scripts/` with the library and `rebar3 dialyzer` checks it.
Run the tests with:

```console
$ rebar3 eunit --module script_util_tests
```
