# Compare filter and selection contracts

Run the unchanged [filter fixtures](../../test/fixtures/filters-v1.json)
through Erlang and a pinned companion port. The runner reports wire admission,
ordered matches and validation diagnostics separately. It changes neither
port's runtime or filter syntax.

**Current result: interoperability FAIL.** Erlang accepts all 23 valid cases
with the expected identities and rejects all eight invalid cases with the
expected paths. Elixir v0.1.1 admits ten of those valid wire documents; all ten
match on the explicitly projected graph. It rejects the other 13 valid
documents. Only three invalid cases produce the same code and path.

These results identify a compatibility gap, not a shared wire-format promise.

## Run the comparison

This is a separate Linux outer qualification command. It requires Python 3.12+,
Git, a C11 compiler, the repository's pinned OTP and Rebar3, and Elixir 1.20.4
on that OTP. Put the executables on PATH before running it. Provide a trusted
local clone of libtmux-elixir containing commit
`a740a1308e51e5e975d4239e0e017efacf4cb169`
([v0.1.1](https://github.com/libtmux/libtmux-elixir/tree/v0.1.1)). The command
does not fetch dependencies or start tmux. Linux must provide pidfds and the
readable procfs children interface required by the core helper. Compiling
source is not a sandbox.

With sibling checkouts, run:

```console
$ python3 tools/filter-conformance/check.py \
    --elixir-repo ../libtmux-elixir \
    --output _build/filter-conformance/first-comparison
```

The output directory must be new. The current comparison exits **1** because
the ports do not conform. Exit **0** requires every case, the complete graph
and the validation diagnostics to agree. Exit **2** means setup, execution or
receipt validation failed. An interrupted command leaves RUNNING or ERROR;
neither is qualification evidence.

The runner archives committed native HEAD and the selected companion commit
into private temporary directories. Uncommitted runtime changes are excluded.
It compiles both sources, isolates Rebar configuration/cache, and checks the
loaded filter BEAM paths and hashes against those private builds. Command
completion, failure, timeout and cancellation retire owned children through
a process group and Linux subreaper, with pidfd exit checks. Temporary
builds are removed; input snapshots, observations, command logs, durations and
source/consumer/BEAM identities remain in the output directory.

Use `--elixir-revision` with another immutable companion commit to compare a
later candidate. Use `--fixture` with another explicit fixture file. Receipts
identify both inputs; a smaller fixture does not qualify the original corpus.

## What is compared

The filter and selection calls use each port's public API. Erlang test-graph
assembly uses the internal `tmux_snapshot:build/2` fixture boundary; the
Elixir graph uses public `LibTmux.Snapshot.new/2`. This is not an installed
package or public graph-construction qualification.

The complete fixture contains a path with arbitrary bytes, including NUL and
invalid UTF-8. Elixir v0.1.1 treats paths as text and rejects that graph. The
runner retains this full-graph failure. It separately removes only
pane.currentPath and leaves that field unloaded to evaluate admitted filters
that do not require it. This projection cannot produce an interoperability
PASS. Filter documents and scalar operands are never translated or coerced.

The current differences include:

- Boolean keys: lowercase `and`, `or`, `not` versus `AND`, `OR`, `NOT`.
- Operator spellings: `is_not`, `starts_with`, `not_in` versus camel case.
- Integral JSON floats, explicit presence, byte operands and restricted regex.
- Validation paths that include an implicit equality operator in Elixir.

The shared fixtures remain the Erlang contract. This comparison does not
select a new common grammar or silently change either port's version-1 wire
format. Native pushdown, other companion ports, tmux I/O and release delivery
retain their separate qualification gates.
