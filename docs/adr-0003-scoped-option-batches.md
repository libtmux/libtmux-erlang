# ADR 0003: Batch local scalar option reads

## Status

Accepted design. Native qualification, measurements and package delivery have
separate evidence gates. It preserves complete graph observations, local
ownership metadata and interval semantics.

## Context and drivers

Reading the local ownership tag of every row in a captured graph starts one
client per row. Each client incurs an identity preflight, helper and tmux
client. Large graphs pay this process cost repeatedly even when metadata values
are small.

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
an atomic server-incarnation check. Ambient aliases/configuration retain the
existing unresolved qualification boundary; batching establishes no new alias
policy.

## Cost

A caller partitions rows into groups of at most seven. For `R` rows, metadata
reads change from `R` library commands to `ceil(R/7)`.

This reduces processes, not the number of commands executed inside tmux:
each metadata row now uses two display guards and one option read. It can
also transfer more bytes and retain larger frames. Report source calls, elapsed
time, semantic equality and cleanup together when comparing it with individual
reads.

## Qualification

Native tests cover missing middle targets, deletion during a read, hook output,
arbitrary non-NUL bytes and seven maximally escaped 32 KiB values. A
newline-heavy response also runs under an explicit decoder heap bound.

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
