# Observe transport, operations and captures

The core emits structured OTP Logger reports under the `[libtmux]` domain.
It adds no handler, telemetry dependency or background logging process.
Your application's Logger configuration controls delivery and cost.

Enable debug reports with `logger:set_module_level(tmux_log, debug)`. Restore
the inherited level with `logger:unset_module_level(tmux_log)`, or restore the
specific override returned by `logger:get_module_level/1`. A handler must
also admit debug events. Filter its metadata by the `[libtmux]` domain prefix
or one of its child domains. These are standard
[OTP Logger configuration](https://www.erlang.org/doc/apps/kernel/logger_chapter.html#configuration)
operations; they affect the Erlang node.

The implementation checks the configured module level before constructing a
report. Ordinary completion and credit reports use debug. Helper setup
failures, incomplete cleanup and owned-daemon failures use warning. An
application-shutdown cleanup summary uses error. Use
`logger:set_module_level(tmux_log, none)` to suppress these reports together.
Reports preserve the recorded outcome and cleanup evidence. Emitting them can
increase latency and consume command-deadline or caller-wait budgets.

## Report fields

`[libtmux, transport]` reports `transport_result` after a client result becomes
available. `transport` is the client's reference ID. Fields include `result`,
`code`, `outcome`, `cleanup`, `mode`, `duration_us`, `stdout_bytes`,
`stderr_bytes` and `stdin_delivered`. Duration starts when the transport owner
initializes, including native setup and retirement. A successful transport
result can contain a nonzero client exit status; the endpoint determines the
tmux operation's outcome. A later improvement in cleanup evidence produces
another result report with the same reference.

The same domain reports `transport_credit_held` when a channel delivers a
chunk and withdraws further read credit until acknowledgement. `stream`,
`sequence` and `held_bytes` identify that delivery. This records a flow-control
transition, not proof that a subscriber is slow. It does not claim a backlog
size inside tmux. One-shot output exhaustion instead appears as `output_limit`
in its result report. See [control attachments](control.md) for the currently
qualified control surface.

`[libtmux, operation]` reports `operation_result` with `generation` and
`operation` reference IDs. `phase`, `stage`, `outcome`, `cleanup`, `result`,
`code` and output byte counts describe the same evidence as
`tmux_operation:status/1` and `tmux_operation:await/2`. `tracked_duration_us`
starts when the endpoint begins tracking the operation; it excludes time
spent holding an unused admission lease. Incomplete cleanup may first produce
a `responded` report and later a `retired` report. Retirement does not turn an
unknown remote outcome into success. See [jobs and operations](jobs.md).

`[libtmux, query]` reports `capture_result` for an admitted snapshot or query
capture, including rejections after its endpoint context is established.
`capture` matches the successful snapshot's metadata ID; `generation` matches
the endpoint. `duration_us` covers that capture's observation interval and
validation. Success includes logical `source_calls` and `observed_bytes`.
Failure includes `code` and an atom-valued `reason` when available. Invalid
options and failures before endpoint context is available return their normal
errors without a capture report. Query retries have separate capture IDs.
These counters do not include the transport's identity preflight clients.

`[libtmux, ownership]` reports `owned_server_failure`,
`owned_server_cleanup_incomplete` and `owned_server_recovery_report_failed`.
`ownership` is a reference ID; `code` and an optional atom-valued `reason`
describe the failure. Retain the original API error for recovery handles and
resource evidence. The report grants no authority to stop a server.

Application shutdown reports `owned_server_shutdown_incomplete` in the same
domain with `scope => application`, `code` and `failed_owners`. The bounded
summary omits nested resource reports. Private recovery files retain the
separate cleanup evidence; see [daemon ownership](ownership.md).

## Cost and data boundaries

Reports contain a fixed set of reference IDs, atoms and integer counters.
They omit executable paths, socket paths, argv, environment values, terminal
bytes, names, filter criteria and full error maps. They are observations,
not durable audit records or a replacement for returned errors. Reference
IDs identify this VM's lifetimes; they are not persistent resource identities.

Caller-installed Logger metadata, filters and handlers remain under application
control. Handler callbacks run in the emitting process. Custom handlers can
delay it, and standard handlers can switch to synchronous backpressure under
load. Configure handler levels and overload protection for production.
Enabling debug on a large capture produces a report per transport and
operation. Reports describe the implemented one-shot and attachment lanes;
they do not qualify deferred command submission or public streams.

The Common Test diagnostics suite installs an owned Logger handler, exercises
real helper and tmux operations, and checks reference correlation, capture
rejection, read-credit withholding, setup failure, cleanup failure, bounded
reports, payload exclusion and disabled logging.

## Local programming errors

Library-raised validation, coverage, cardinality and explicit raising-helper
exceptions carry native EEP-54 metadata. `m:tmux_error` adds explanations to
the shell and `erl_error:format_exception/3`, including the input path,
allowed names or missing observations when available. Exception reasons and
tagged result APIs keep their structured data. Application callback exceptions
retain their original stack; the library does not relabel them as filter
failures. This formatting performs no I/O and is separate from Logger reports.

The [local filter program](querying.md#portable-input) checks a malformed
criterion and formats its native exception through the installed package.
