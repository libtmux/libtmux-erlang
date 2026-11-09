# ADR 0003: Batch local scalar option reads

## Status

Accepted design. Native qualification, measurements and package delivery have
separate evidence gates. This refines the workspace observation strategy in
[ADR 0001, AD-8](adr-0001-architecture.md#ad-8-keep-workspace-execution-downstream-and-mcp-excluded).
It preserves complete graph
observations, local ownership metadata, per-step checks and interval semantics.

## Context and drivers

Workspace plan/apply observes the graph and every local ownership tag around
each step. Three concurrent readers reduce waiting, but one client per row
still incurs an identity preflight, helper and tmux client. Large workspaces
pay this process cost repeatedly even when metadata values are small.

Retain every ownership read and distinguish absence from target loss. Bound
native output and parser allocation. Reduce client starts without introducing
an implicit cache, weaker graph agreement or a persistent control dependency.

## Decision

Add a bounded `tmux_command:sequence/1` value for explicit one-shot command
groups. Literal argument semicolons retain their existing escaping; only
member boundaries become native separators. Generated members preserve their
shared endpoint origin. Different origins and nested groups are rejected.
The result contains combined output and native status. A failed member may
leave a completed prefix; it supplies no per-member attribution or rollback.
Control submission qualification remains separate.

Use that value in `tmux_option:get_many/3`: one scalar key, one to seven local
session/window/pane rows, and one registered endpoint. Validate all scopes,
ownership and option metadata before native dispatch. Restrict names to a
bounded ASCII grammar and reject array, indexed, hook and command values.
The existing `tmux_option:get/3` retains the broader option surface.

Each row emits its physical ID, reads the named option, then emits the ID
again. Index-specific envelopes frame those observations. Native
[local and inherited lookup](https://github.com/tmux/tmux/blob/3.3a/cmd-show-options.c#L121-L139)
uses quiet mode so an absent local user option emits no value line. Quiet
mode also suppresses missing-target errors, so both identity envelopes must
match before absence is accepted.

Use tmux's
[named string quoting](https://github.com/tmux/tmux/blob/3.3a/cmd-show-options.c#L177-L191),
which applies
[argument escaping](https://github.com/tmux/tmux/blob/3.3a/arguments.c#L526-L577).
Split at most three wire lines per requested row before decoding values.
Require exact indexes, identities, scalar headers and final termination.
Escaped newlines and protocol-looking payload bytes remain values. Normalize
the qualified legacy print layer once for each envelope and once in the
existing option codec; never decode values before framing. Unexpected hook
output, missing envelopes or malformed values reject the whole batch.

The operation retains the endpoint's observed identity preflight, 2500 ms
deadline, 1 MiB stdout and 64 KiB stderr limits. Seven 32 KiB values fit the
worst qualified fourfold quoting expansion plus bounded names/envelopes.
Larger external values can overflow the aggregate bound. Errors preserve
command outcome and cleanup independently; decoding failure after native
success does not turn that outcome into a native execution error.

These are observations over an interval. Hooks and queued work can intervene;
a removed sole-pane window can keep its pane observable through queued
references on older tmux. Envelopes do not prove membership, atomic reads or
an atomic server-incarnation check. Workspace graph and ownership checks still
govern each apply step. Ambient aliases/configuration retain the existing
unresolved qualification boundary; batching establishes no new alias policy.

## Workspace execution and cost

Partition rows by entity kind and then into groups of at most seven. Use the
existing coordinator to run at most three groups concurrently, preserve row
order and drain dispatched groups on cancellation. The next coordinator batch
requires another cancellation check. A group may contain several native reads
after cancellation arrives; all belong to already dispatched work.

For nonempty complete graphs, let `R` be physical session/window/pane rows and
`B = ceil(S/7) + ceil(W/7) + ceil(P/7)`. Metadata changes from `R` to `B`
library commands. Observation therefore uses `9 + B` library commands and
`18 + 2B` client/helper starts, including snapshot identity preflights.
Empty collections skip their corresponding work.

This reduces processes, not the number of commands executed inside tmux:
each metadata row now uses two display guards and one option read. It can
also transfer more bytes and retain larger frames. Complete apply still makes
graph observations around every step; it is not a linear-time reconciliation
algorithm. Report source calls, elapsed time, semantic equality and cleanup
together when comparing it with individual reads.

## Qualification

The four-pane observation regression changes from 15 library commands to 12,
while inherited global tags remain absent from local ownership reads. Native
tests cover missing middle targets, deletion during a read, hook output,
arbitrary non-NUL bytes and seven maximally escaped 32 KiB values. Cancellation
drains three dispatched groups and prevents the fourth from starting. A
newline-heavy response also runs under an explicit decoder heap bound.

An eight-pane apply retains 45 graph observations and 384 ownership-row reads;
transport starts change from 1608 to 1164. A 64-pane apply retains all 176
steps, 353 graph observations and 19,200 ownership-row reads; starts change
from 45,092 to 13,880 on both tmux 3.3a and 3.8. Ordered pane-summary
fingerprints match the recorded individual-read baseline. Binding and expected
launch-metadata checks pass separately, layout cell counts agree, the second
plan is empty, and owned cleanup completes.

The candidate completion runs took 4.76 seconds for eight panes on tmux 3.8,
42.27 seconds for 64 panes on 3.8, and 40.14 seconds for 64 panes on 3.3a,
including caller startup and owned fixture setup. These are single completion
observations under shared host load, not latency distributions, speedup ratios
or a tmux-version ranking. Full-product adoption and publication remain
separate gates.

## Alternatives and reconsideration

Individual `get/3` calls remain suitable for broader keys and isolated reads.
A `tmux_command:to_config/1` list loaded through `source_file/2` would add a
configuration-lexer boundary and carry no captured command origin. Direct
sequence values retain executable argv and generated-member provenance.
A full option-table scan would transfer unrelated values and enlarge framing
requirements. Format lookups inherit table parents and cannot establish local
ownership. Persistent control could reduce process starts further but needs
its own configuration, framing and lifecycle qualification.

Reconsider group size or strategy if measured hook cost, aggregate overflow,
parser work or cancellation drain latency outweigh saved client starts. Keep
complete metadata coverage and explicit failure evidence in any replacement.
