# ADR 0001: Immutable values and owned tmux execution

## Status

Accepted architecture, 2026-11-08. Implementation and delivery remain partial.

This record describes the design selected for the
[recorded source baseline](https://github.com/libtmux/libtmux-erlang/tree/9a1ca749f7bf6f082c910c99f961bb586781ab0b). It does not qualify unfinished APIs or
announce a release. [Support and gaps](compatibility.md) owns the current
implementation and platform inventory. A later decision that changes these
boundaries should identify which part of this record it supersedes.

Upstream code references use release tags. This repository has no release tag
at this baseline; implementation links pin the recorded source commit. The
decisions below distinguish that implementation from required follow-up work.

## Context

tmux owns mutable sessions, physical windows, membership links and panes in a
separate server. Several sessions can link the same window, and one session
can contain several links to it. tmux's [pane-list traversal](https://github.com/tmux/tmux/blob/3.3/cmd-list-panes.c#L70-L84)
walks those links. Treating a window as a session-owned object would lose that
structure and could count one physical pane several times.

Observing the graph, acting on it and managing a client process have different
lifetimes. A captured pane can disappear before an action. A timed-out waiter
can leave a command running. A client can retire after tmux has already made
an irreversible change. The API must preserve those distinctions while fitting
ordinary Erlang programs.

The core targets the single current stable OTP baseline and the selected Linux
qualification matrix, starting at plain tmux 3.3. It does not carry older-OTP
compatibility branches. The [project policy](project-policy.md) defines the
runtime dependency and application boundaries.

## Decision drivers

- Preserve tmux identity, linked-window membership and observed coverage.
- Give callers predictable errors, ownership and cleanup evidence.
- Bound native I/O, queued operations and retained results.
- Make source-call cost and observation intervals inspectable.
- Keep ordinary Erlang use concise and downstream installation reproducible.
- Review public record compatibility independently from OTP upgrades.

## Architectural decisions

### AD-1: Use native Erlang values and explicit module functions

Use exported OTP native records for session, window, window-link and pane rows.
Keep selections, queries, filters and operation handles opaque. Criteria and
options use maps; text and terminal bytes use binaries; ordinary lists remain
the exchange format for collections.

[Native records in OTP 29](https://github.com/erlang/otp/blob/OTP-29.1.2/system/doc/reference_manual/ref_man_native_records.md#L31) provide module-owned definitions and
record export/import without distributing a header. Their experimental status
is an explicit dependency: assess record construction, consumers and upgrades
before accepting another OTP line. Do not serialize record internals as a
public format. [Constructors](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_model.erl#L100) and action boundaries validate values;
typespecs and nominal IDs assist tooling without enforcing runtime invariants.

Exported record definitions are a versioned library contract. A value retains
the definition used when it was constructed; adding a field does not add that
field to retained values. Each release must state whether older rows and
snapshots remain usable, require conversion, or must be discarded and freshly
observed. Field renames, defaults and model-version changes need the same
review. A documented consumer restart is an acceptable initial upgrade policy.
Experimental status permits future incompatibilities; it does not establish
that every future OTP release or code upgrade will break these values.

Use [to_list/1](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_select.erl#L159) and [fold/3](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_select.erl#L165) at library boundaries.
The opaque selection itself is not an Erlang list. Arbitrary transformations
return ordinary values rather than preserving an entity selection after its
rows have changed type.

Keeping a selection retains its snapshot context. Store the extracted rows
when relationship evaluation is finished. A future compact selection must
declare its retained relationship closure and coverage; dropping related rows
cannot turn an incomplete relation into an empty complete one. Measure that
need before adding another extraction alias or pruning API.

Companion APIs provide behavioral references, with their own language
interfaces: Python's [QueryList](https://github.com/tmux-python/libtmux/blob/v0.62.0/src/libtmux/_internal/query_list.py#L327) extends a list, Elixir's
[Selection](https://github.com/libtmux/libtmux-elixir/blob/v0.1.1/lib/libtmux/selection.ex#L1-L13) implements Enumerable, and the OCaml core
[Map.S interface](https://github.com/ocaml/ocaml/blob/5.5.2/stdlib/map.mli#L65) describes an abstract container. Erlang uses
module functions and pattern matching. None of those companion runtimes is a
core dependency.

### AD-2: Separate physical identity, membership and observation

[tmux_model](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_model.erl#L4) distinguishes Session, Window, WindowLink and Pane.
A physical window has no universal session or session-relative index.
A window link records the observed session, index and expected physical
window; it is not a stable tmux link ID. Session window traversal deduplicates
physical windows while preserving every membership in window-link traversal.

[Snapshots](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_snapshot.erl#L3) retain immutable indexes, coverage, source calls, capture
intervals and endpoint/server generation. Server-wide physical entities use
numeric ID order. Link and pane traversal use their documented observed
indexes. Filtering preserves that order instead of exposing map iteration.

Coverage distinguishes a known value, known absence, not-loaded data and an
unavailable capability. An unloaded relationship cannot become an empty list.
[require/2](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_snapshot.erl#L187) checks the fields and relationships needed by an
evaluation, including when its selection is empty.

Constructed rows are detached. [bind/2](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_server.erl#L267) performs an explicit fresh
observation before registering an action-capable row. Actions validate the
registered origin, generation and expected membership. A vanished target does
not permit fallback to a positional target.

At the recorded baseline, the [origin registry](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_server.erl#L282) identifies an endpoint and
generation, while [target resolution](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_target.erl#L9) takes the ID from the supplied row.
Exported records permit construction and updates, including that ID and their
provenance fields. The origin therefore does not authenticate an unchanged
observation. The selected correction binds the captured target in a private,
unexported native record carried by the public row. Actions compare its entity,
origin, snapshot ID and target fields with the supplied row before dispatch.
Edited identities require fresh `tmux_server:bind/2` observation. The private
value retains identifiers rather than a graph or a per-row registry entry.
Edited-row regressions cover IDs, origins, snapshot IDs and link memberships.
The [model upgrade policy](compatibility.md#retained-rows-and-upgrades) requires
discarding version-1 values when adopting this model version 2 representation.
These checks provide library provenance, not authorization against trusted
code in the Erlang VM or callers of internal construction functions.

### AD-3: Keep selections, portable filters and source queries distinct

| Value | Meaning | Execution boundary |
| --- | --- | --- |
| Selection | Ordered rows from one captured graph | Local reads and transformations |
| Filter | Validated, versioned predicate data | Preparation against explicit snapshot coverage |
| Query | A future source observation and its plan | Explicit fetch |

[where/2](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_select.erl#L107) accepts declarative criteria or a portable filter.
[filter/2](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_select.erl#L132) accepts a unary Boolean function; callback failures
propagate. A trusted matcher behaviour prepares local executable code. A
serialized filter cannot select a module or carry a closure.

Criteria use one map grammar with field-specific operators, Boolean
composition and explicit relationship quantifiers. A single existential child
must satisfy all conditions inside that child. Separate existential clauses
may match different children and must not be merged during normalization.
Complete coverage is required for relationship counts, every and none.

[Portable filters](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_filter.erl#L3) contain stable schema identifiers and normalized
values. [Prepared evaluation](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_filter.erl#L169) may cache membership sets, compiled
patterns and relation indexes, but remains bound to the captured context.
Checked cardinality distinguishes absence from ambiguity and stops after a
second match establishes the latter.

Composition should depend on the normalized expression, not the sequence of
query-builder calls. Compose validated filters internally and flatten adjacent
Boolean conjunctions before applying normalized limits. Preserve bounds during
external parsing and preserve separate existential nodes. The recorded
implementation still nests conjunctions through wire conversion; chained and
flat construction need an equivalent-semantics and resource-accounting test.

[OTP JSON](https://github.com/erlang/otp/blob/OTP-29.1.2/lib/stdlib/src/json.erl#L880) owns parsing and encoding. The [wire boundary](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_json.erl#L5)
adds document and nesting limits, duplicate-key and trailing-input rejection,
exact-number bounds and explicit field mappings. Payload keys never create
atoms. Shared regex support uses the tested restricted dialect; full local
regex behavior belongs in trusted callbacks, without an interoperability claim.

### AD-4: Make observation and optimization explicit

[snapshot/2](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_server.erl#L245) and [fetch/2](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_query.erl#L212) perform source I/O.
Query construction, explanation and local selection reads do not refresh or
hydrate data implicitly.

Capture brackets hydration with identity/scalar scans and rejects detected
disagreements. It remains an interval of observations. A change followed by a
reversal can escape detection; immutable storage does not make capture atomic.
Stable IDs and observed process identity do not make later actions atomic.

The current `fetch/2` permits one opt-in inconsistent-capture retry within the
original deadline; `snapshot/2` has no retry option. Changing that default or
accepting disagreements in volatile fields changes the observation contract.
Measure churn before making that decision. `max_rows` bounds each raw scan and
the aggregate session/window/pane observations in each spine; repeated linked
memberships count before physical deduplication.

Native tmux filtering is a candidate optimization. For the same observed state,
the full predicate must imply the candidate predicate. The complete residual
still runs locally, required relationships remain complete, and limits apply
after residual filtering and identity handling. Unknown translations broaden
the candidate; negation requires an exact child translation.

Numeric formats need their own conversion and range qualification. Erlang term
ordering and tmux string comparison must not stand in for schema numeric
semantics. [explain/1](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_query.erl#L172) exposes the plan and its temporal limits.
Disabling pushdown avoids an earlier candidate exclusion, while retaining the
capture interval. Later filtering cannot recover a row excluded earlier.

#### Capture cost and optimization gate

The [capture sequence](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_observe.erl#L29) hydrates the complete graph even when a
candidate filter is present. With the recorded field schema, a successful
nonempty capture performs `6 + S + 2W + 3P + C` logical data commands: two
three-command spine scans, one text field per session, two per physical window,
three text/byte fields per physical pane, and an optional candidate scan `C` of
zero or one.
Each successful command also performs an identity preflight. Three sessions,
nine windows and 27 panes therefore require 108 logical commands and 216 tmux
client launches without a candidate scan. Startup, retries and failures are
outside this calculation; it is not a latency measurement.

Pushdown currently defaults on. It can reduce local residual work, but does
not reduce hydration and adds an earlier exclusion point. The selected next
step is to disable it by default for complete-graph queries unless equivalent
workload measurements justify retaining it. Report that choice in `explain/1`
and the query guide when implemented.

Measure the Erlang/helper path on small, linked, changing and 200-pane graphs.
Record commands, client launches, elapsed distributions, bytes, retained memory,
capture failures and cleanup. Require identical successful payloads, IDs,
ordering and attribution before comparing one-shot and control timings. A
literal newline inside a line-framed control command can change the request;
a successful reply guard alone cannot validate a benchmark's work.

Compare qualified persistent control, lossless batching and an in-server
guard before changing the source strategy. tmux's [command queue](https://github.com/tmux/tmux/blob/3.3/cmd-queue.c#L719-L790)
can wait for external work, so chaining commands does not establish general
snapshot atomicity. [if-shell -F](https://github.com/tmux/tmux/blob/3.3/cmd-if-shell.c#L73-L103)
provides a candidate synchronous guard, subject to identity precision, alias,
hook, membership, parsing and concurrent-client qualification. Qualify text
framing per field and tmux version; paths cannot inherit a title codec merely
because one release sanitizes titles.

Candidate-scoped hydration is a later strategy if measurements justify its
coverage complexity. A subset of matching children must never be represented
as the complete relationship. Candidate implication tests must execute the
translated predicate through supported tmux versions, including plain 3.3.

### AD-5: Supervise resource owners and keep domain rows as values

The endpoint, transport and owned-daemon lifecycle require supervised
processes. Sessions, panes, snapshots and selections remain values; there is
no process for every domain row.

[start_owned/1](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_server.erl#L118) creates a private server namespace and returns
a separate ownership token. Borrowed endpoint close retires library clients
while preserving the borrowed daemon. Stopping an owned daemon requires its
ownership token and cleanup proof. No operation gains permission to stop a
default or borrowed server from a socket path alone.

The initiating process owns an [operation](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_operation.erl#L3). Ownership transfer
registers the new owner before acknowledging the old owner. Submission is
non-blocking with respect to command completion. Waiting, command deadlines,
cancellation, remote outcome and native cleanup are separate contracts.
[OTP response abandonment](https://github.com/erlang/otp/blob/OTP-29.1.2/lib/stdlib/src/gen_server.erl#L1524) does not undo remote effects.
Cancellation after dispatch can leave the tmux outcome unknown; an uncertain
mutation must not be retried automatically.

A transfer timeout can also leave an uncertain ownership outcome: abandoning
the response does not retract the queued owner change. Callers reconcile the
current owner through [tmux_operation:status/1](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_operation.erl#L104) before relying on ownership. A delayed-endpoint
regression must cover the late transfer and owner-death ordering.

Keep an executable transition model for cancellation before dispatch, partial
writes, terminal responses and late retirement. Duplicate or stale events must
release admission once; stronger cleanup evidence cannot invent a known remote
outcome. Adopt a different OTP behaviour or supervisor layout only when it
improves these invariants or a measured bottleneck.

### AD-6: Use a separate bounded Linux helper for native I/O

The OTP transport launches the [bundled C11 helper](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_transport.erl#L324) with
spawn_executable. It sends the child's executable and argument vector through
the helper's framed protocol. The helper runs outside the VM and uses Linux
process and pipe interfaces. It is built from packaged source; there is no
runtime executable download.

The [private protocol](../apps/libtmux_erlang/c_src/README.md) separates stdout and stderr, grants output read
credits, bounds frames and queues, acknowledges input writes, and distinguishes
terminal delivery from observed helper exit. The helper owns its child tree
and retains incomplete cleanup as an explicit failure. A successful tmux
reply, pipe write or helper exit alone cannot prove every later aftereffect.

[Descendant retirement](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/c_src/owned_io.c#L291) reads `/proc/self/task/<pid>/children`; the Linux kernel
must expose that interface through [CONFIG_PROC_CHILDREN](https://man7.org/linux/man-pages/man5/proc_tid_children.5.html). A mounted procfs
alone is insufficient. The recorded helper first attempts the interface during
cleanup and ignores open failure; remaining descendants can then produce
`cleanup_incomplete`. Required follow-up is admission before child launch, with a
specific capability error and underlying OS error, plus a negative test that
proves no child started. Missing support must not silently select a weaker
cleanup contract.

The helper is reused from the [tagged Elixir source](https://github.com/libtmux/libtmux-elixir/blob/v0.1.1/c_src/owned_io.c#L380), with
[provenance and license records](../apps/libtmux_erlang/c_src/provenance.json). Its source identity does
not transfer Elixir runtime qualification to Erlang. Separate processes also
do not provide a sandbox: inherited authority, hostile forks, helper SIGKILL
and concurrently replaced filesystem entries retain documented limits.

Carry helper fixes with their source/protocol provenance and qualify each port
independently. Focused frame fuzzing, sanitizer checks and installed source
consumers complement lifecycle tests; matching the upstream digest is not a
substitute for them.

Executable argv, tmux command syntax, formats and explicit shell-command
arguments are separate interpreter boundaries. Avoiding an implicit host
shell does not suppress tmux aliases, hooks or terminal-program behavior.

### AD-7: Qualify persistent control separately from one-shot execution

[attach/3](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang/src/tmux_control.erl#L55) currently establishes explicit control-client lifetime
and identity on that persistent connection. Attachment changes attached_count.
The selected no-output/ignore-size and environment-update policies remain
visible. Existing hooks and destruction policies can still produce effects;
closing a client is not a rollback.

The [control guide](control.md) limits current qualification to attachment.
Command submission and groups need separate framing, ordering, eligibility,
certainty and cleanup evidence. tmux's [reply guards](https://github.com/tmux/tmux/blob/3.8/control.c#L523-L543) coexist with
asynchronous notifications. Its [alias-expansion path](https://github.com/tmux/tmux/blob/3.3/cmd-parse.y#L744-L779) means a
canonical command name alone cannot establish what configured tmux will do.
The ambient-alias contract also applies to the existing attachment command and
its identity probe. Qualify those paths against configured aliases while
preserving borrowed-server configuration. Record the library's attached client
where possible; retain the raw attached count and hook effects. Any adjusted
view needs a separately named contract rather than silently subtracting the
observer.

Public output subscriptions and sampled observation streams are also unfinished.
The helper's internal credit protocol does not establish a public streaming
API. Any such API must define credits, gaps, acknowledgement and retirement,
and describe sampled observations without promising unobserved terminal history.

### AD-8: Keep workspace execution downstream and MCP excluded

Use a Rebar3 umbrella to develop independent OTP applications together.
libtmux_erlang owns the core; libtmux_erlang_workspace consumes its public API.
The core has no dependency on the workspace application. Each package owns
metadata, license and changelog material, and needs an installed-consumer check
outside the umbrella before independent delivery.

The [workspace loader](https://github.com/libtmux/libtmux-erlang/blob/9a1ca749f7bf6f082c910c99f961bb586781ab0b/apps/libtmux_erlang_workspace/src/tmux_workspace.erl#L71) currently validates versioned JSON into
inert desired state. Planning, apply and the CLI remain implementation work.
Endpoint names need host policy; loading shell text does not authorize its
execution. File loading and path resolution are synchronous trusted-filesystem
operations without an I/O deadline or atomic filesystem-snapshot guarantee.

Erlang runtime dependencies stay within OTP, alongside the recorded external
helper exception. Build, test and documentation dependencies have separate
roles. An additional runtime dependency needs a concrete capability requirement
and a new recorded decision. MCP packages, servers and SDK integration are
excluded by [project policy](project-policy.md); they are not pending packages.

### AD-9: Keep contracts and verification native to Erlang

Keep specs, exported type/callback documentation and module/function docs beside
their definitions. Native record exports and compiler documentation support
API browsers. [ct_doctest](https://github.com/erlang/otp/blob/OTP-29.1.2/lib/common_test/src/ct_doctest.erl#L24) executes Erlang-shell examples;
reader programs exercise real tmux through owned fixtures and installed core
packages. Generated field/operator documentation shares the validation schema.

Keep failure examples useful when both an operation and cleanup fail: retain
both outcomes instead of masking the original exception in an `after` clause.
Validate more precise query/constructor/error specs through an external
Dialyzer consumer with deliberate entity mixups. Generated recursive filters
and linked graphs should agree with a small reference evaluator.

Use bounded OTP logger reports for transport failures, cleanup, IPC duration,
capture rejection and credit saturation. Give structured programming errors
useful native error formatting. Keep payloads and environment secrets out of
ordinary diagnostics, and keep optional telemetry outside core dependencies.

EUnit, Common Test, properties, Dialyzer, documentation and installed-consumer
checks cover different contracts. Preserve failed or skipped evidence instead
of treating it as a passing subset. Exact source/tool/platform identities and
individual matrix conclusions determine qualification. Test-loop durations
do not establish throughput or a control-versus-streaming performance claim.

Source installation is a separate gate from consuming a compiled `ebin`/`priv`
archive. Build the exact source package outside the umbrella without a prebuilt
helper or checkout-relative resources, on each supported architecture. This
gate remains open at the recorded baseline.

## Alternatives considered

| Alternative | Decision and consequence |
| --- | --- |
| Map-only domain rows | Native records provide named shapes and downstream patterns; maps remain appropriate for criteria and options. Runtime validation is still required. |
| A general collection or ORM framework | Keep the entity-aware operations small and exchange ordinary lists. Arbitrary transformations leave the selection type. |
| Mutable shared storage as the snapshot contract | Use immutable captured indexes. An internal cache or optional adapter must preserve observation identity and coverage. |
| Direct ports without the helper | A replacement must prove separate bounded output, input accounting and owned-tree retirement. The selected helper exposes those contracts explicitly. |
| A native extension inside the VM | Keep the transport helper outside the VM, accepting Linux build and IPC costs. |
| Transparent lazy relationship reads | Reject incomplete local coverage. Arrange hydration only during explicit source execution. |
| One application for core and consumers | Separate OTP applications preserve dependency direction and expose installed-package integration failures. |
| QLC, graph or ETS as the public predicate language | Defer adapters; portable filters remain data and local callers retain native Erlang tools. |

## Consequences

The public API follows Erlang conventions and supports local reuse without
transport calls. Captured context makes relationship filtering predictable,
but retaining a selection can retain its complete snapshot graph. Callers that
only need rows should exchange lists.

Native records require deliberate upgrade qualification. Linux helper builds
require a C11 compiler, make, libc and the documented Linux interfaces. Platform
support follows the tested matrix rather than the availability of an Erlang VM.

Resource ownership and bounded protocols make failure evidence explicit. They
do not make multi-command tmux actions transactional, turn socket access into
confinement, or bound arbitrary application callbacks. Observed identity checks
and filesystem cleanup retain concurrency races stated in their contracts.

At the recorded baseline, the core graph/query/one-shot path and control
attachment exist; workspace JSON loading exists; control submission, groups,
public streams, workspace plan/apply/CLI and complete delivery remain open.
Registry and shared-site publication require their own verified delivery steps.
Consult [support and gaps](compatibility.md) before selecting an execution lane.

## When to reconsider

Revisit the native-record choice when another OTP line changes representation,
construction or upgrade behavior. Revisit the helper boundary when another
platform or transport can prove the same bounded-I/O and retirement contracts.

Revisit observation guarantees if tmux supplies a server-side atomic capture
or compare-and-act primitive. Qualify control and streams before changing the
default execution lane; compare equal workloads, errors and cleanup outcomes.
Revisit caching or advanced query adapters when measured workloads justify
their additional state and lifecycle costs.

Record a separate consumer decision if MCP is brought back into scope or if a
new runtime dependency is proposed. Do not infer either change from artwork,
an empty package directory or an implementation plan.

## References

The linked upstream code is pinned to OTP 29.1.2, tmux 3.3/3.8, Python libtmux
v0.62.0, Elixir libtmux v0.1.1 and OCaml 5.5.2. Companion references explain
interfaces or source provenance, without adding runtime dependencies.
