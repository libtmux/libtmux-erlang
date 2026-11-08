# Own a daemon or borrow an endpoint

Use `tmux_server:with_owned/2` for work inside a new private daemon and
`tmux_server:with_server/2` for a callback using an existing socket. Use
`tmux_server:start_owned/1` and `tmux_server:open/1` when your application
manages those lifetimes explicitly. The
[README program](../README.md#create-capture-and-query) uses public owned
startup, graph queries and cleanup; it also runs against the installed archive.

Owned startup returns an endpoint and an ownership token. The daemon starts
empty, without a user config, in a fresh private directory. It disables
`exit-empty` on that daemon and keeps one unattached bootstrap client alive.
It does not create a session, attach an observer or change a borrowed daemon's
policy. The startup budget includes readiness, a no-start socket identity
probe and binding the endpoint to the observed Linux process incarnation.
These observations do not make connection replacement atomic.

`tmux_server:close/1` retires endpoint operations and one-shot clients without
issuing daemon destruction commands. Native policies and hooks may still
change state. Separate [control attachments](control.md) receive an
invalidation notice and begin their own retirement; close them before their
endpoint to verify their cleanup too. Closing a row's endpoint never conveys the
separate ownership token. `tmux_server:stop_owned/1` requires that token and
retires the owned endpoint, bootstrap client, daemon and finite descendants.
It targets the helper's owned process tree, never a daemon discovered by path.
The process that called startup owns this lifetime; its death also starts
cleanup. A successful stop remains idempotent for 60 seconds.

## Preserve work and cleanup failures

Scoped server callbacks run in the calling process. Successful cleanup returns
`{ok, Value}` or re-raises the callback's original error, throw or exit with its
stack. A callback returning `{error, Detail}` returns that ordinary value inside
`{ok, Value}`; the scope does not interpret application-specific results.

If cleanup fails, the result is `{error, Failure}` with
`t:tmux_server:scope_failure/0`. Its `primary` field retains the callback value
or exception, and `cleanup` retains the separate cleanup error or exception.
The failure includes `server` and, for an owned scope, `ownership`. Retain these
handles for inspection and an explicit cleanup retry. A cleanup timeout leaves
the existing supervised owner responsible; it does not establish retirement.

For nested resources, `tmux_scope:run/2` preserves the same evidence without
acquiring a resource. `tmux_scope:run_or_error/2` returns the callback value
directly and raises `{scope_cleanup_failed, Failure}` on cleanup failure.
The examples use this raising form so an inner failure propagates while outer
cleanup still runs. Each cleanup closure normalizes its resource's successful
reply to `ok`. Nested cleanup failures retain their separate evidence.

These helpers attempt cleanup once. They do not impose callback duration
limits, retry work or retire separately allocated resources automatically.
Close a control attachment explicitly before leaving its endpoint scope.

## Handle incomplete cleanup

A cleanup deadline is an error, not retirement proof. While the application
runs, the supervised controller retains uncertainty and continues receiving
retirement events. Errors include separate process, endpoint, probe and
namespace results. Incomplete startup also returns the ownership token and
captured resources for inspection and a later stop attempt.

The controller checks directory and socket filesystem identities before
removal. It preserves a changed namespace and unexpected files. It never
recursively removes the directory. A replacement socket can therefore remain
live after the original daemon retires. A later stop can retry after the
application repairs its own namespace. Filesystem checks remain observations;
they do not reserve paths against concurrent changes by trusted local code.

Stop explicitly before application shutdown when the caller needs a verified
result. The application prepares owned cleanup while its supervisors are still
running. If cleanup remains incomplete, it logs a diagnostic and writes a
private recovery report outside the socket directory, or reports the write
failure. The report records captured identities and remaining resources; it
never authorizes signalling a PID or deleting a path. No automatic recovery
runs. Stopping the OTP application itself does not establish native cleanup,
and old ownership tokens expire with that application lifetime.

See [jobs and operations](jobs.md) for per-command ownership, cancellation and
uncertain remote effects, and [support and gaps](compatibility.md) for the
separate control and streaming qualification work.
