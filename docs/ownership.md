# Own a daemon or borrow an endpoint

- `tmux_server:with_owned/2` runs a callback inside a new private daemon.
- `tmux_server:with_server/2` runs a callback on an existing socket.
- `tmux_server:start_owned/1` and `tmux_server:open/1` do the same when your
  application manages the lifetime itself.

The [README program](../README.md#create-capture-and-query) uses owned
startup, graph queries and cleanup.

## Start and stop an owned daemon

- Owned startup returns an endpoint and an ownership token.
- The daemon starts empty, with no user config, in a fresh private directory.
  It sets `exit-empty` off and keeps one unattached bootstrap client alive.
- Startup creates no session and attaches no observer. It never changes a
  borrowed daemon's policy.
- The startup budget covers readiness, a no-start socket identity probe and
  binding the endpoint to the observed Linux process. These observations do
  not make connection replacement atomic.
- `tmux_server:stop_owned/1` needs the token. It retires the endpoint, the
  bootstrap client, the daemon and its finite descendants. It targets the
  helper's owned process tree, never a daemon found by path.
- The process that called startup owns the lifetime. Its death also starts
  cleanup.
- A successful stop stays idempotent for 60 seconds.

## Close an endpoint

- `tmux_server:close/1` retires endpoint operations and one-shot clients. It
  issues no daemon destruction commands. Native policies and hooks can still
  change state.
- Closing a row's endpoint never conveys the separate ownership token.
- A [control attachment](control.md) gets an invalidation notice and starts its
  own retirement. Close it before its endpoint to verify its cleanup too.

## Preserve work and cleanup failures

- A scoped server callback runs in the calling process.
- On successful cleanup, the scope returns `{ok, Value}` or re-raises the
  callback's original error, throw or exit with its stack.
- A callback that returns `{error, Detail}` still yields `{ok, Value}`. The
  scope does not interpret your results.
- If cleanup fails, the result is `{error, Failure}` with
  `t:tmux_server:scope_failure/0`. Its `primary` field holds the callback value
  or exception and `cleanup` holds the cleanup error.
- The failure also holds `server` and, for an owned scope, `ownership`. Keep
  them to inspect and retry cleanup.
- A cleanup timeout leaves the supervised owner responsible. It does not prove
  retirement.

For nested resources:

- `tmux_scope:run/2` keeps the same evidence without acquiring a resource.
- `tmux_scope:run_or_error/2` returns the callback value directly and raises
  `{scope_cleanup_failed, Failure}` when cleanup fails. The examples use it so
  an inner failure propagates while outer cleanup still runs.
- Each cleanup closure turns its resource's successful reply into `ok`. Nested
  failures keep separate evidence.
- These helpers try cleanup once. They set no callback time limit, retry
  nothing and do not retire separately allocated resources.
- Close a control attachment before leaving its endpoint scope.

## Handle incomplete cleanup

- A cleanup deadline is an error, not proof of retirement. While the
  application runs, the supervised controller keeps the uncertainty and keeps
  receiving retirement events.
- Errors carry separate process, endpoint, probe and namespace results.
  Incomplete startup also returns the token and captured resources for a later
  stop attempt.
- Before removing anything, the controller checks directory and socket
  filesystem identities. It keeps a changed namespace and unexpected files and
  never removes a directory recursively.
- A replacement socket can stay live after the original daemon retires. A later
  stop can retry once the application repairs its namespace.
- Those checks are observations. They do not reserve paths against concurrent
  changes by trusted local code.

## Stop before shutdown

- Stop explicitly before application shutdown when you need a verified result.
- The application prepares owned cleanup while its supervisors still run. If
  cleanup stays incomplete, it logs a diagnostic and writes a private recovery
  report outside the socket directory, or reports the write failure.
- The report records captured identities and remaining resources. It never
  authorizes signalling a PID or deleting a path. No automatic recovery runs.
- Stopping the OTP application does not establish native cleanup. Old
  ownership tokens expire with that application lifetime.

See [jobs and operations](jobs.md) for per-command ownership, cancellation and
uncertain remote effects, and [support and gaps](compatibility.md) for control
and streaming work that is not built.
