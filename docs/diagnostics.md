# Observe transport, operations and captures

The core emits structured OTP Logger reports under the `[libtmux]` domain.

- It adds no handler, telemetry dependency or background logging process.
- Your Logger configuration controls delivery and cost.

## Turn reports on

- Enable debug reports with `logger:set_module_level(tmux_log, debug)`.
- Restore the inherited level with `logger:unset_module_level(tmux_log)`, or
  restore the override that `logger:get_module_level/1` returned.
- A handler must also admit debug events. Filter its metadata by the
  `[libtmux]` domain prefix or one child domain.
- These are standard
  [OTP Logger configuration](https://www.erlang.org/doc/apps/kernel/logger_chapter.html#configuration)
  operations. They affect the whole Erlang node.
- The level is checked before a report is built. Completion and credit reports
  use debug. Helper setup failures, incomplete cleanup and owned-daemon
  failures use warning. The application-shutdown cleanup summary uses error.
- `logger:set_module_level(tmux_log, none)` suppresses all of them.
- Reports keep the recorded outcome and cleanup evidence. Emitting them adds
  latency and can use command-deadline or caller-wait budgets.

## Report fields

### `[libtmux, transport]`

- `transport_result` appears once a client result is available. `transport` is
  the client's reference ID. Fields: `result`, `code`, `outcome`, `cleanup`,
  `mode`, `duration_us`, `stdout_bytes`, `stderr_bytes`, `stdin_delivered`.
- Duration starts when the transport owner initializes and includes native
  setup and retirement.
- A successful transport result can hold a nonzero client exit status. The
  endpoint decides the tmux operation's outcome.
- Better cleanup evidence later produces another result report with the same
  reference.
- `transport_credit_held` appears when a channel delivers a chunk and withholds
  more read credit until acknowledged. `stream`, `sequence` and `held_bytes`
  identify the delivery.
- That is a flow-control transition. It does not show a slow subscriber or a
  backlog size inside tmux. One-shot output exhaustion appears as
  `output_limit` in its result report.
- See [control attachments](control.md) for the control surface that exists.

### `[libtmux, operation]`

- `operation_result` carries `generation` and `operation` reference IDs.
  `phase`, `stage`, `outcome`, `cleanup`, `result`, `code` and output byte
  counts match `tmux_operation:status/1` and `tmux_operation:await/2`.
- `tracked_duration_us` starts when the endpoint begins tracking the operation.
  It excludes time spent holding an unused admission lease.
- Incomplete cleanup can first give a `responded` report and later a `retired`
  report. Retirement does not turn an unknown remote outcome into success.
- See [jobs and operations](jobs.md).

### `[libtmux, query]`

- `capture_result` covers an admitted snapshot or query capture, including
  rejections after the endpoint context exists. `capture` matches the
  snapshot's metadata ID. `generation` matches the endpoint.
- `duration_us` covers that capture's observation interval and validation.
- Success adds logical `source_calls` and `observed_bytes`. Failure adds `code`
  and, when available, an atom `reason`.
- Invalid options, and failures before the endpoint context exists, return
  their normal errors with no report.
- Each query retry gets its own capture ID.
- The counters leave out the transport's identity-preflight clients.
- Snapshot metadata records the hydration strategy. Batched hydration uses
  three field scans on a nonempty graph. Isolated hydration uses one command per
  text or byte field per physical row. Both keep the six bracketing spine
  scans. See [source plans](querying.md#source-plans).

### `[libtmux, ownership]`

- `owned_server_failure`, `owned_server_cleanup_incomplete` and
  `owned_server_recovery_report_failed` carry an `ownership` reference ID, a
  `code` and an optional atom `reason`.
- Keep the original API error for recovery handles and resource evidence. A
  report gives no authority to stop a server.
- Application shutdown reports `owned_server_shutdown_incomplete` with
  `scope => application`, `code` and `failed_owners`. The summary omits nested
  resource reports. Private recovery files keep that evidence; see
  [daemon ownership](ownership.md).

## Cost and data boundaries

- Reports hold a fixed set of reference IDs, atoms and integer counters.
- They omit executable paths, socket paths, argv, environment values, terminal
  bytes, names, filter criteria and full error maps.
- They are observations, not audit records and not a substitute for returned
  errors. Reference IDs identify lifetimes in this VM and are not persistent
  resource identities.
- Your Logger metadata, filters and handlers stay under your control. Handler
  callbacks run in the emitting process. A custom handler can delay it, and a
  standard handler can switch to synchronous backpressure under load.
- Set handler levels and overload protection for production. Debug on a large
  capture emits a report per transport and operation.
- Reports cover the one-shot and attachment lanes. They say nothing about
  command submission or public streams, which are not built.

## Local programming errors

- Validation, coverage, cardinality and explicit raising-helper exceptions
  carry native EEP-54 metadata.
- `m:tmux_error` adds explanations to the shell and to
  `erl_error:format_exception/3`: the input path, allowed names or missing
  observations when known.
- Exception reasons and tagged results keep their structured data. Exceptions
  from your callbacks keep their original stack. The library does not relabel
  them as filter failures.
- This formatting does no I/O and is separate from Logger reports.

The [local filter program](querying.md#portable-input) checks a malformed
criterion and formats its native exception.
