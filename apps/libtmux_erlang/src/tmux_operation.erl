-module(tmux_operation).
-moduledoc """
Own a command independently of an individual wait.

`start/3` submits a validated command through the endpoint's
bounded admission. The initiating process owns it. `await/2`
timing out abandons only that wait; `cancel/1` or owner death
retires the client and may leave an unknown tmux outcome. The endpoint
acknowledges `transfer/2` after monitoring the new owner and
before replying to the old owner. The new process does not perform a
handshake. Retired results expire after 60 seconds or earlier when the
endpoint exceeds 64 retained results or 4 MiB of retained stdout/stderr
(oldest evicted first). Closing the endpoint clears its operation results
immediately. Each operation accepts at most 16 concurrent waiters; excess
waits return too_many_waiters. `await_started/2` returns
lifecycle status once the operation leaves queued; dispatch authorization does
not establish a tmux aftereffect.

See `t:completed/0` and `t:failure/0` for
command outcomes and `t:state/0` for lifecycle status. The [job
guide](jobs.md) shows the complete workflow.
""".
-export([start/3, await/2, await_started/2, status/1, cancel/1, transfer/2]).
-export_type([t/0, completed/0, failure/0, state/0, outcome/0, cleanup/0]).
-doc """
A generation-bound operation handle. Possessing a waiter handle does not
transfer ownership.
""".
-opaque t() :: {operation, pid(), reference(), reference()}.

-doc "Command certainty, separate from resource cleanup. unknown must not trigger an automatic mutation retry.".
-type outcome() :: success | error | not_started | cancelled_before_send | unknown.
-doc "complete proves owned client retirement; incomplete or unverified does not.".
-type cleanup() :: complete | incomplete | unverified.
-doc """
A successful command result. stdout and stderr are separate byte strings;
exit_status is zero. stdin_delivered counts bytes accepted by the client pipe,
not bytes consumed by tmux. success does not prove a background aftereffect.
""".
-type completed() :: #{stdout := binary(), stderr := binary(), exit_status := 0,
    stdin_delivered := non_neg_integer(), outcome := success, cleanup := complete}.
-doc """
A tagged error detail with a stable code and optional certainty/output data.
Validation, admission and wait errors may contain only code. Command failures
retain available stdout/stderr, stdin_delivered and exit_status. Other keys
provide code-specific context. Never infer missing certainty fields.

Common codes are busy, invalid_operation_options, command_error, deadline,
cancelled, stale_server, cleanup_incomplete, await_timeout and
operation_expired. command_error means a nonzero client exit; it does not roll
back a mutation. await_timeout abandons only this wait. operation_expired
cannot reconstruct a previous result or establish its remote outcome.
""".
-type failure() :: #{code := atom(), outcome => outcome(), cleanup => cleanup(),
    stdout => binary(), stderr => binary(), stdin_delivered => non_neg_integer(),
    exit_status => integer(), submitted => boolean(), atom() => term()}.
-doc """
Observed lifecycle state, without command output. queued includes admission
and identity preflight; sent means dispatch authorization, not a proven
aftereffect. responded can retain incomplete cleanup; retired releases
operation resources. pending certainty means no result yet. The owner is the
initiating or transferred process; holding a waiter handle does not change it.
""".
-type state() :: #{phase := queued | sent | responded | retired,
    stage := pending | waiting | preflight | command, owner := pid(),
    outcome := pending | outcome(), cleanup := pending | cleanup()}.

-doc """
Submit a validated command under the endpoint's admission limits and return an
operation handle. The initiating process owns it. Submission is non-blocking
with respect to command completion; the handle does not prove that tmux has
executed the command.
""".
-spec start(tmux_server:t(), tmux_command:t(), tmux_server:command_options()) -> {ok, t()} | {error, failure()}.
start(Server, Command, Options) ->
    case tmux_server:submit(Server, Command, Options) of
        {ok, {Pid, Generation, Lease}} -> {ok, {operation, Pid, Generation, Lease}};
        Error -> Error
    end.

-doc """
Wait for a retained result for at most Timeout. An await_timeout removes only
this waiter; the operation continues and its handle remains usable. Additional
waiters do not become owners. Results preserve outcome and cleanup certainty.
""".
-spec await(t(), timeout()) -> {ok, completed()} | {error, failure()}.
await(Operation, Timeout) -> request(Operation, await, Timeout).

-doc """
Wait until the operation leaves queued, returning its lifecycle state even if
it has already failed or retired. Inspect outcome and cleanup; call `await/2`
for final command data. Authorization is not proof of a tmux aftereffect. A
timeout abandons this wait without cancelling the operation.
""".
-spec await_started(t(), timeout()) -> {ok, state()} | {error, failure()}.
await_started(Operation, Timeout) -> request(Operation, started, Timeout).

-doc """
Read the retained lifecycle state without starting a tmux command. Expired
handles return operation_expired. Status is observation of the operation, not
evidence that a possibly sent mutation was cancelled.
""".
-spec status(t()) -> {ok, state()} | {error, failure()}.
status(Operation) -> request(Operation, status, 900).

-doc """
Request cancellation using this handle. Any holder can cancel; only the owner
can transfer ownership. Queued work can be cancelled before submission;
possibly sent work retires its client and can retain an unknown tmux outcome.
Use `await/2` for the result and cleanup proof. Never infer rollback or
automatically retry a mutation from cancellation alone. already_completed
means a response exists; it does not establish complete cleanup.
""".
-spec cancel(t()) -> {ok, cancelled_before_send | cancel_requested | already_completed} | {error, map()}.
cancel(Operation) -> request(Operation, cancel, 900).

-doc """
Transfer ownership to a live process on this Erlang node. The endpoint
installs its new owner monitor before releasing the previous monitor and
returns after the swap. The new process performs no handshake. Waiters and
ownership remain separate; endpoint ownership does not change.
""".
-spec transfer(t(), pid()) -> ok | {error, map()}.
transfer(Operation, Owner) when is_pid(Owner), node(Owner) =:= node() ->
    request(Operation, {transfer, Owner}, 900);
transfer(_, _) -> {error, #{code => invalid_owner}}.

request({operation, Pid, Generation, Lease}, Kind, Timeout)
  when is_pid(Pid), is_reference(Generation), is_reference(Lease),
       (Timeout =:= infinity orelse is_integer(Timeout, 0, 4294967295)) ->
    Tag = make_ref(),
    Request = gen_server:send_request(Pid, {Generation, operation, Lease, Kind, Tag}),
    case gen_server:receive_response(Request, Timeout) of
        {reply, Reply} -> Reply;
        timeout ->
            gen_server:cast(Pid, {Generation, unwait, Lease, Tag}),
            {error, #{code => await_timeout}};
        {error, _} -> {error, #{code => operation_expired, cleanup => unverified}}
    end;
request(_, _, _) -> {error, #{code => invalid_operation}}.
