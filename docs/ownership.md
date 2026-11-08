# Own a daemon or borrow an endpoint

Use `tmux_server:start_owned/1` for a new private daemon and
`tmux_server:open/1` for an existing socket. The
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
