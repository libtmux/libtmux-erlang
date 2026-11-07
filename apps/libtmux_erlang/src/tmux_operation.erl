-module(tmux_operation).
-moduledoc """
Own a command independently of an individual wait.

start submits a validated command through the endpoint's bounded admission.
The initiating process owns it. await timing out abandons only that wait;
cancel or owner death retires the client and may leave an unknown tmux outcome.
transfer acknowledges the new owner before removing the previous monitor.
Results expire after the endpoint's bounded retention period.
await_started waits for dispatch authorization or a terminal result;
authorization does not establish a tmux aftereffect.
""".
-export([start/3, await/2, await_started/2, status/1, cancel/1, transfer/2]).
-export_type([t/0]).
-opaque t() :: {operation, pid(), reference(), reference()}.

-spec start(tmux_server:t(), tmux_command:t(), map()) -> {ok, t()} | {error, map()}.
start(Server, Command, Options) ->
    case tmux_server:submit(Server, Command, Options) of
        {ok, {Pid, Generation, Lease}} -> {ok, {operation, Pid, Generation, Lease}};
        Error -> Error
    end.

-spec await(t(), timeout()) -> {ok, map()} | {error, map()}.
await(Operation, Timeout) -> request(Operation, await, Timeout).

-spec await_started(t(), timeout()) -> {ok, map()} | {error, map()}.
await_started(Operation, Timeout) -> request(Operation, started, Timeout).

-spec status(t()) -> {ok, map()} | {error, map()}.
status(Operation) -> request(Operation, status, 900).

-spec cancel(t()) -> {ok, cancelled_before_send | cancel_requested | already_completed} | {error, map()}.
cancel(Operation) -> request(Operation, cancel, 900).

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
