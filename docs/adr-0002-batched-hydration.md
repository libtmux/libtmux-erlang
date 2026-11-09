# ADR 0002: Batch complete-graph field hydration

## Status

Accepted architecture. Implementation qualification remains separate from
release and full-product adoption.

This supersedes the capture execution strategy in
[ADR 0001, AD-4](adr-0001-architecture.md#ad-4-make-observation-and-optimization-explicit).
The graph model, interval semantics, identity checks, coverage, limits and
explicit execution boundary remain the governing contracts.

## Context

The original one-shot capture reads each text or byte field separately. A
successful nonempty capture needs `6 + S + 2W + 3P + C` logical commands for
sessions, physical windows, physical panes and an optional candidate scan.
Each successful command also starts an identity-preflight client. Complete
hydration dominates the cost even when a query returns one pane.

A delimiter alone cannot frame paths containing tabs or newlines. A separate
length expression is also insufficient: tmux's
[format lookup](https://github.com/tmux/tmux/blob/3.3a/format.c#L3432)
invokes built-in callbacks on each lookup, and
[pane_current_path](https://github.com/tmux/tmux/blob/3.3a/format.c#L844)
reads an external process. Length and value could therefore describe different
observations. The field must be observed once before framing.

## Decision

Hydrate each nonempty entity collection with one bounded list command.
The schema explicitly admits each current text/byte field to
`escaped_columns_v1`. A field without that admission retains isolated reads.

Each field expansion applies three literal
[substitutions](https://github.com/tmux/tmux/blob/3.3a/format.c#L4513) to one
value: escape backslashes, then replace tabs and newlines with their textual
escapes. Only then add column tabs and row newlines. No payload is expanded
again as a format, command or shell program. List commands use ordinary
format expansion, preserving literal percent sequences.

The decoder requires the final newline, exact column counts, valid escapes
and bounded raw row counts. It reverses the selected tmux print layer before
field validation, including the older VIS and dollar encodings. Native
qualification covers every non-NUL byte, empty values and protocol-looking
text; NUL is outside tmux's string representation. Text fields retain schema
UTF-8 validation, while paths remain bytes.

Validate every hydrated identity against the initial spine. Repeated physical
rows from linked memberships must agree before deduplication. Missing or new
identities reject the capture; conflicting repeated values reject it too.
The final identity/scalar spine must still agree with the first. Multiple
commands and external process reads retain interval semantics, including the
possibility of undetected change and reversal.

Default snapshot and query hydration is `batched`. The existing options maps
also accept `hydration => isolated` for one field per physical row.
[Query plans](querying.md#source-plans) describe both command templates;
[snapshot metadata](api.md) records the requested strategy and actual calls.
There is no automatic fallback after an overflowing batch.

The current successful nonempty batched capture needs `9 + C` logical commands
and `18 + 2C` tmux clients: six spine scans, three hydration scans, and the
optional candidate scan. Empty collections skip their hydration command.
Unqualified schema fields can increase this cost through isolated fallback.
Native candidate filtering remains opt-in and still hydrates the complete
graph. Limits apply after full residual evaluation and identity handling.

## Resource tradeoffs

The command stdout bound remains 1 MiB, and the capture total remains 8 MiB by
default. A batch combines entity output under that command bound. Callers with
larger entity output can explicitly choose isolated hydration, distributing it
across commands under the same total and deadline. Output overflow remains an
explicit error with cleanup evidence; the library neither enlarges bounds nor
silently retries the observation. See the native capture options in the
[API guide](api.md).

The native limit regression uses 37 panes with 30,000-byte titles. Batched
capture returns `output_limit` with its bounded prefix and completed cleanup;
an explicitly requested isolated capture returns every full title.

Linked windows can increase raw batch output because the list traversal
repeats memberships. Row bounds count those observations before physical
deduplication. Fewer commands do not imply fewer transferred bytes.

The decoder rebuilds field binaries rather than retaining slices of the batch
frame. A snapshot-backed selection still retains the complete captured graph.
After relationship evaluation, callers can keep extracted rows and release
their other snapshot and selection references. Extraction preserves field
values, including any backing allocations shared by caller-created rows; see
the selection contracts in the [API guide](api.md).

## Qualification and measurements

The linked-graph regression first returned 21 logical commands, then returned
nine with equal row maps under both strategies. The real-path regression
retains tabs, newlines, carriage returns, format syntax, backslashes and a
non-UTF-8 byte. Native framing tests run at the CI endpoints, tmux 3.3a and
3.8; focused local probes also checked the distinct older print encodings.
Support remains continuous through the intermediate releases.

A controlled Linux x86_64 experiment used OTP 29.1.2, tmux 3.8, the real
Erlang/helper path and cooperating pane programs with per-process readiness.
Both strategies observed the same owned graph, and all successful full row
maps had equal hashes. Three repetitions alternated strategy order after one
default-deadline attempt per strategy. The figures below are capture medians;
they exclude fixture setup and are observations on that host, not latency
promises.

| Graph | Batched commands | Isolated commands | Batched median | Isolated median |
| --- | ---: | ---: | ---: | ---: |
| 1 session, 1 window, 1 pane | 9 | 12 | 0.065 s | 0.084 s |
| 1 session, 5 windows, 20 panes | 9 | 77 | 0.066 s | 0.556 s |
| 2 sessions, 9 linked windows, 27 panes | 9 | 107 | 0.072 s | 0.858 s |
| 2 sessions, 20 linked windows, 200 panes | 9 | 648 | 0.125 s | 6.772 s |

The isolated 200-pane default attempt reached its deadline. Its median uses
three successful repetitions with an explicit 60-second deadline; the other
cells each have four successful observations. All owned helpers, servers and
pane roots retired, and their namespaces were removed. The complete sweep,
including fresh source builds and fixture setup, took about 40 seconds.
These measurements qualify this one-shot strategy choice. They establish no
control-mode speedup, churn rate or general workload distribution.

## Alternatives and reconsideration

Persistent control submission remains a separate qualification task with
alias, framing, attribution and lifecycle obligations. A single command batch
does not establish a general atomic snapshot. In-server guards also retain
their identity and configuration qualification requirements.

Candidate-scoped hydration would reduce complete coverage and needs a distinct
contract before adoption. Reconsider this strategy if measured transferred
bytes, regex-substitution cost, large-field overflow or repeated memberships
outweigh the saved round trips. A future strategy must preserve the current
byte, coverage, identity and cleanup contracts or name its weaker guarantees.
