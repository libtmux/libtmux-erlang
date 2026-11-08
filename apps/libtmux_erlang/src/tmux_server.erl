-module(tmux_server).
-moduledoc """
Open tmux endpoints and execute explicit command values.

`open/1` validates an absolute socket path and the
executable/server versions. It never creates a tmux server or attaches a
control client. Each command rechecks the observed Linux process incarnation
before dispatch. Replacement between that observation and a later client
connection remains possible; same_connection requests are rejected until
persistent dispatch qualifies.

`start_owned/1` creates a separate private daemon and returns an ownership
token for `stop_owned/1`. The [ownership guide](ownership.md) explains caller
death, application shutdown and namespace cleanup.

The calling process owns the endpoint. `close/1` cancels queued
work, retires its one-shot clients and preserves the borrowed server. Cleanup
failure remains explicit and keeps the supervised owner alive. Successful close is
idempotent during the 60-second handle retention period. Separate
`m:tmux_control` attachments receive an invalidation notice and begin their
own retirement. Close those attachments explicitly to prove their native
cleanup. Command results preserve stdout, stderr and status; cancellation
after dispatch cannot undo
remote effects. Clients explicitly select tmux's UTF-8 mode so Unicode and the
identity probe's tab do not depend on the caller's locale. Command-specific
escaping still applies to raw command output.

Use `snapshot/1` to capture a graph for `m:tmux_snapshot` and
`m:tmux_select`. Use `m:tmux_operation` for non-blocking submission and
explicit waits; the [job guide](jobs.md) explains ownership and cleanup.
""".
-behaviour(gen_server).
-export([open/1, command/3, close/1, status/1, origin/1, version/1, from_origin/1, bind/2,
         snapshot/1, snapshot/2, observation_context/1, start_owned/1, stop_owned/1]).
-export([submit/3, start_link/3, init/1, handle_call/3, handle_cast/2,
         handle_info/2, format_status/1, send_request/2, open_observed/3]).
-export([watch_closing/1, watch_closing/2, unwatch_closing/2]).
-export_type([t/0]).
-export_type([open_options/0, command_options/0, capture_options/0, state/0]).
-export_type([owned_options/0, ownership/0]).
-doc "An explicit absolute socket endpoint and optional absolute tmux executable path.".
-type open_options() :: #{socket_path := binary(), executable => binary()}.
-doc "Owned startup options. The finite startup budget defaults to 2500 milliseconds.".
-type owned_options() :: #{executable => binary(), startup_timeout_ms => 1..600000}.
-doc """
Opaque ownership token for `stop_owned/1`. An ordinary endpoint or row origin
does not convey this token. Trusted code can pass it to another process.
""".
-opaque ownership() :: {owned_server, pid(), reference()}.
-doc """
Command options: deadline_ms defaults to 2500, max_stdout to 1 MiB, max_stderr
to 64 KiB, stdin to an empty binary and identity to observed. The deadline
includes admission, preflight and execution. stdin is limited to 256 KiB;
stdin plus the rendered argument reservation must also fit 256 KiB. Each
endpoint admits at most 64 operations and 256 KiB of command payload;
exhaustion returns busy. same_connection is recognized but unsupported.
""".
-type command_options() :: #{deadline_ms => 1..600000, max_stdout => 0..1048576,
    max_stderr => 0..65536, stdin => binary(), identity => observed | same_connection}.
-doc "Capture bounds and consistency request. Atomic capture is explicitly unsupported.".
-type capture_options() :: #{deadline_ms => 1..600000, max_rows => 1..65536,
    max_bytes => 1..67108864, consistency => observed | atomic}.
-doc """
Endpoint resource summary. owner is the supervised endpoint process, not its
initiating caller. operations and command_bytes count active admission leases;
active_bytes reserves output capacity. Retired results are bounded separately
by retained_results and result_bytes. These are accounting limits, not VM heap
measurements. generation identifies this endpoint handle's lifetime.
""".
-type state() :: #{phase := open | closing | closed, generation := reference(),
    owner := pid(), operations := non_neg_integer(), command_bytes := non_neg_integer(),
    active_bytes := non_neg_integer(), retained_results := non_neg_integer(),
    result_bytes := non_neg_integer()}.

-doc """
A supervised borrowed-endpoint handle bound to an owner generation and
admission state.
""".
-opaque t() :: {server, pid(), reference(), tmux_admission:t()}.
%% Reserve two copies of the 256 KiB ingress limit while validating/rendering.
-define(PAYLOAD_BUDGET, 7864320).

-doc """
Open a borrowed socket endpoint and start its supervised library owner. The
caller owns that handle. This probes the executable, daemon version and
observed Linux process incarnation; it never starts a tmux server or attaches
a control client. Pass an absolute socket_path and optionally an executable.
""".
-spec open(open_options()) -> {ok, t()} | {error, map()}.
open(Options) ->
    maybe
        {ok, Config} ?= endpoint_options(Options),
        {ok, #{stdout := Raw}} ?= successful(tmux_transport:run(maps:get(executable, Config),
            [<<"-V">>], #{max_stdout => 64, max_stderr => 4096})),
        {ok, _} ?= require_version(Raw),
        {ok, Result} ?= successful(tmux_transport:run(maps:get(executable, Config),
            endpoint_args(Config, probe_args()), #{max_stdout => 128, max_stderr => 4096})),
        {ok, Pid, Version} ?= parse_probe(maps:get(stdout, Result)),
        {ok, Identity} ?= tmux_identity:observe(Pid),
        create_endpoint(self(), Config#{identity => Identity, server_pid => Pid, version => Version})
    end.

-doc """
Start an empty owned daemon in a fresh private Linux socket directory. Performs
I/O and waits for bounded startup; no session or attached observer is created.
Returns an ordinary endpoint and a separate `t:ownership/0` token. The caller
owns the daemon lifetime: caller death or `stop_owned/1` retires its helper tree.
`close/1` only closes the endpoint and preserves the daemon.

The daemon starts without a user config, with `exit-empty` disabled. One idle,
unattached bootstrap client keeps the owned helper tree alive. Startup includes
readiness and endpoint incarnation binding, not just executable launch.
Incomplete cleanup remains explicit; it is never permission to kill by path.
An incomplete startup error includes an ownership token and captured resources
for `stop_owned/1` recovery. The token does not serialize across VM lifetimes.
""".
-spec start_owned(owned_options()) -> {ok, t(), ownership()} | {error, map()}.
start_owned(Options) -> tmux_owned_server:start(Options).

-doc """
Stop the daemon and endpoint associated with a `t:ownership/0` token. Performs
I/O and returns ok only after endpoint/client/helper retirement and namespace
cleanup are proved. It never sends kill-server to a socket path.

A replaced socket/directory or unexpected directory contents are preserved and
return `cleanup_incomplete` with process and namespace details. A supervised
tombstone retains uncertain cleanup; call again to inspect/retry after external
repair. Filesystem identity checks are observations, not atomic reservations
against another trusted process replacing a path during unlink.

Successful stop is idempotent during the 60-second token retention period.
After token expiry or application shutdown, returns `ownership_expired`.
Stop explicitly before application shutdown when the caller needs a verified
cleanup result. OTP application shutdown itself does not prove native cleanup.
Incomplete shutdown writes a private recovery report outside the owned socket
directory and logs its location or write failure; no automatic recovery runs.
""".
-spec stop_owned(ownership()) -> ok | {error, map()}.
stop_owned(Ownership) -> tmux_owned_server:stop(Ownership).

-doc false.
-spec open_observed(pid(), map(), binary()) -> {ok, t()} | {error, map()}.
open_observed(Owner, Config, Bytes) ->
    maybe
        {ok, Pid, Version} ?= parse_probe(Bytes),
        {ok, Identity} ?= tmux_identity:observe(Pid),
        {ok, Server} ?= create_endpoint(Owner,
            Config#{identity => Identity, server_pid => Pid, version => Version}),
        case tmux_identity:check(Identity, Pid) of
            ok -> {ok, Server};
            Error -> _ = close(Server), Error
        end
    end.

create_endpoint(Owner, Config) ->
    Generation = make_ref(),
    Child = #{id => Generation, start => {?MODULE, start_link,
        [Owner, Generation, Config]}, restart => temporary, shutdown => 1000},
    case supervisor:start_child(tmux_sup, Child) of
        {ok, Pid} -> {ok, gen_server:call(Pid, handle, 900)};
        {error, _} -> {error, #{code => endpoint_unavailable}}
    end.

-doc """
Execute one validated command and await its result. Performs I/O. The result
preserves stdout, stderr, exit status and cleanup certainty. Use
`tmux_operation:start/3` to submit without blocking this caller. A timeout or
cancellation cannot reverse effects that may already have reached tmux.
Values from domain command builders keep their captured endpoint origin.
Another endpoint returns different_owner with submitted = false before any
native preflight or execution. Raw commands do not carry that origin.
""".
-spec command(t(), tmux_command:t(), command_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
command(Server, Command, Options) ->
    case tmux_operation:start(Server, Command, Options) of
        {ok, Operation} -> tmux_operation:await(Operation, infinity);
        Error -> Error
    end.

-doc """
Retire this endpoint's operations and one-shot clients, preserving the borrowed
tmux server. Returns ok only after their cleanup completes; incomplete cleanup
remains an explicit error. Closing an already closed retained handle is
idempotent. The initiator controls endpoint lifetime. Separate control
attachments are invalidated and asked to retire; use `tmux_control:close/1`
before this call to verify those clients' cleanup too.
""".
-spec close(t()) -> ok | {error, map()}.
close(Server) -> server_request(Server, close, 1000).

-doc """
Read the endpoint owner's lifecycle and resource summary. This contacts the
library owner, not tmux, and does not refresh captured rows.
""".
-spec status(t()) -> {ok, state()} | {error, tmux_operation:failure()}.
status(Server) -> server_request(Server, status, 900).

-doc """
Return the registered opaque origin for this open endpoint. The token provides
library provenance and generation checks, not authorization against trusted
Erlang code. It is not a portable identifier.
""".
-spec origin(t()) -> {ok, reference()} | {error, map()}.
origin(Server) -> server_request(Server, origin, 900).

-doc """
Return the daemon version observed when the endpoint opened. This reads owner
state and does not execute a fresh version command or qualify another tmux
release.
""".
-spec version(t()) -> {ok, tmux_version:t()} | {error, map()}.
version(Server) -> server_request(Server, version, 900).

-doc """
Capture a complete immutable graph with default capture limits. Performs I/O.
See `snapshot/2` for bounds, consistency and conflict errors.
""".
-spec snapshot(t()) -> {ok, tmux_snapshot:t()} | {error, map()}.
snapshot(Server) -> snapshot(Server, #{}).

-doc """
Capture the server's sessions, physical windows, window links and panes.

This performs explicit I/O and records each command's observation interval.
Identity scans bracket field reads; detected topology or value disagreements
return inconsistent_capture. Changes between reads can remain undetected,
including changes followed by a reversal. Atomic capture is unsupported.

Options are consistency (observed only), deadline_ms (default 2500, maximum
600000), max_rows (4096, maximum 65536 identity observations per scan) and
max_bytes (8 MiB, maximum 64 MiB total stdout across capture commands). A
field or scan is additionally limited to 1 MiB. These are data limits, not a
VM heap limit. Capturing performs no retry. Local reads of the resulting value
do no I/O.

Unsupported consistency is rejected before contacting a server:

```erlang
1> tmux_server:snapshot(invalid_server, #{consistency => atomic}).
{error,#{code => unsupported_consistency}}
```
""".
-spec snapshot(t(), capture_options()) -> {ok, tmux_snapshot:t()} | {error, map()}.
snapshot(Server, Options) -> tmux_observe:snapshot(Server, Options).

-doc false.
-spec observation_context(t()) -> {ok, map()} | {error, map()}.
observation_context(Server) -> server_request(Server, observation_context, 900).

-doc """
Explicitly read current fields from this server and register the new value.
For sessions, physical windows and panes, the read uses the stable ID and
discards the supplied field observations. It provides no atomic identity
check. Window-link binding checks its session/index and expected physical
window. A replaced or missing membership returns stale_link. This observed
preflight does not make a later action atomic.

Invalid rows are rejected before I/O:

```erlang
1> tmux_server:bind(invalid_server, invalid_row).
{error,#{code => invalid_row,path => []}}
```
""".
-spec bind(t(), tmux_model:row()) -> {ok, tmux_model:row()} | {error, map()}.
bind(Server, Row) ->
    maybe
        {ok, Validated} ?= tmux_model:validate(Row),
        case tmux_model:entity(Validated) of
            window_link ->
                maybe
                    {ok, Current, _} ?= tmux_window_link:check(Server, Validated),
                    {ok, Current}
                end;
            Entity -> tmux_observe:get(Server, Entity, tmux_model:get(id, Validated))
        end
    end.

-doc false.
-spec from_origin(reference()) -> {ok, t()} | {error, map()}.
from_origin(Origin) ->
    maybe
        {ok, {Pid, Generation, Admission}} ?= tmux_registry:lookup(Origin),
        case tmux_admission:stats(Admission) of
            {ok, #{open := true}} -> {ok, {server, Pid, Generation, Admission}};
            _ -> {error, #{code => stale_reference}}
        end
    end.

-doc false.
-spec submit(t(), tmux_command:t(), map()) ->
    {ok, {pid(), reference(), reference()}} | {error, map()}.
submit({server, Pid, Generation, Admission}, Command, Options) ->
    Started = now_ms(),
    maybe
        {ok, Spec} ?= submission(Command, Options, Started),
        Bytes = maps:get(bytes, Spec),
        {ok, Lease} ?= tmux_admission:reserve(Admission, self(), Bytes, maps:get(deadline, Spec)),
        Packed = {maps:get(command, Spec), Options#{stdin => maps:get(stdin, Spec)}, Started},
        ok ?= tmux_admission:deliver(Admission, Lease, Bytes, Packed),
        {ok, {Pid, Generation, Lease}}
    end;
submit(_, _, _) -> {error, #{code => invalid_server}}.

server_request({server, Pid, Generation, _}, Kind, Timeout) ->
    Tag = make_ref(),
    Request = gen_server:send_request(Pid, {Generation, Kind, Tag}),
    case gen_server:receive_response(Request, Timeout) of
        {reply, Reply} -> Reply;
        timeout ->
            gen_server:cast(Pid, {Generation, unclose, Tag}),
            Code = case Kind of close -> cleanup_incomplete; _ -> await_timeout end,
            {error, #{code => Code}};
        {error, _} -> {error, #{code => server_expired, cleanup => unverified}}
    end;
server_request(_, _, _) -> {error, #{code => invalid_server}}.

-doc false.
-spec send_request(t(), close | retired) -> gen_server:request_id().
send_request({server, Pid, Generation, _}, Kind) when Kind =:= close; Kind =:= retired ->
    gen_server:send_request(Pid, {Generation, Kind, make_ref()}).

-doc false.
-spec watch_closing(t()) -> {ok, reference(), map()} | {error, map()}.
watch_closing(Server) -> watch_closing(Server, 900).

-doc false.
-spec watch_closing(t(), 0..900) -> {ok, reference(), map()} | {error, map()}.
watch_closing({server, Pid, Generation, _} = Server, Timeout)
  when is_pid(Pid), is_reference(Generation), is_integer(Timeout, 0, 900) ->
    Watch = make_ref(),
    case server_request(Server, {watch_closing, Watch}, Timeout) of
        {ok, Context} -> {ok, Watch, Context};
        Error ->
            %% Revoke even a late registration after abandoning its response.
            gen_server:cast(Pid, {Generation, unwatch_closing, Watch, self()}),
            Error
    end;
watch_closing(_, _) -> {error, #{code => invalid_closing_watch}}.

-doc false.
-spec unwatch_closing(t(), reference()) -> ok | {error, map()}.
unwatch_closing({server, Pid, Generation, _} = Server, Watch)
  when is_pid(Pid), is_reference(Generation), is_reference(Watch) ->
    case server_request(Server, {unwatch_closing, Watch}, 900) of
        ok ->
            receive {tmux_server_closing, Pid, Generation, Watch, _} -> ok
            after 0 -> ok
            end;
        Error -> Error
    end;
unwatch_closing(_, _) -> {error, #{code => invalid_closing_watch}}.

-doc false.
-spec start_link(pid(), reference(), map()) -> gen_server:start_ret().
start_link(Owner, Generation, Config) ->
    gen_server:start_link(?MODULE, {Owner, Generation, Config}, []).

-doc false.
-spec init({pid(), reference(), map()}) -> {ok, map()}.
init({Owner, Generation, Config}) ->
    Admission = tmux_admission:new(Generation),
    {ok, Origin, Registry} = tmux_registry:register(Generation, Admission),
    {ok, #{owner => Owner, owner_monitor => monitor(process, Owner), owner_alive => true,
           generation => Generation, admission => Admission, origin => Origin,
           registry_monitor => monitor(process, Registry),
           config => Config, phase => open, valid => true, operations => #{},
           queue => queue:new(), completed => queue:new(), active_bytes => 0, result_bytes => 0,
           requests => gen_server:reqids_new(), close_waiters => #{}, closing_watchers => #{},
           close_timer => none,
           sweep => erlang:start_timer(100, self(), sweep), retention_timer => none}}.

-doc false.
-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()} | {noreply, map()}.
handle_call(handle, _, #{generation := Generation, admission := Admission} = State) ->
    {reply, {server, self(), Generation, Admission}, State};
handle_call({Generation, status, _}, _, #{generation := Generation} = State) ->
    {reply, {ok, public_status(State)}, State};
handle_call({Generation, origin, _}, _, #{generation := Generation, phase := open, valid := true} = State) ->
    {reply, {ok, maps:get(origin, State)}, State};
handle_call({Generation, version, _}, _, #{generation := Generation, phase := open, valid := true} = State) ->
    {reply, {ok, maps:get(version, maps:get(config, State))}, State};
handle_call({Generation, observation_context, _}, _,
            #{generation := Generation, phase := open, valid := true,
              config := Config, origin := Origin} = State) ->
    {reply, {ok, #{origin => Origin, generation => Generation,
        endpoint => maps:with([socket_path], Config),
        server_instance => maps:get(identity, Config),
        tmux_version => maps:get(version, Config)}}, State};
handle_call({Generation, {watch_closing, Watch}, _}, {Pid, _},
            #{generation := Generation, phase := open, valid := true} = State)
  when is_reference(Watch), node(Pid) =:= node() ->
    Next = prune_closing_watchers(State),
    Watchers = maps:get(closing_watchers, Next),
    case {map_size(Watchers) < 16, maps:is_key(Watch, Watchers)} of
        {true, false} ->
            Context = (maps:with([generation, origin, config, admission], Next))#{owner => self()},
            {reply, {ok, Context}, Next#{closing_watchers =>
                Watchers#{Watch => {Pid, monitor(process, Pid)}}}};
        {false, _} -> {reply, {error, #{code => too_many_closing_watchers}}, Next};
        _ -> {reply, {error, #{code => invalid_closing_watch}}, Next}
    end;
handle_call({Generation, {watch_closing, _}, _}, _, #{generation := Generation} = State) ->
    {reply, {error, #{code => stale_reference}}, State};
handle_call({Generation, {unwatch_closing, Watch}, _}, {Pid, _},
            #{generation := Generation} = State) ->
    case unwatch(Watch, Pid, State) of
        {ok, Next} -> {reply, ok, Next};
        Error -> {reply, Error, State}
    end;
handle_call({Generation, Kind, _}, _, #{generation := Generation} = State)
  when Kind =:= origin; Kind =:= version; Kind =:= observation_context ->
    {reply, {error, #{code => stale_reference}}, State};
handle_call({Generation, Kind, _}, _, #{generation := Generation, phase := closed} = State)
  when Kind =:= close; Kind =:= retired ->
    {reply, ok, State};
handle_call({Generation, Kind, Tag}, From, #{generation := Generation} = State)
  when Kind =:= close; Kind =:= retired ->
    Ready = case Kind of
        close -> advance(begin_close(State));
        retired -> State
    end,
    case {maps:get(phase, Ready), map_size(maps:get(close_waiters, Ready)) < 16} of
        {closed, _} -> {reply, ok, Ready};
        {_, false} -> {reply, {error, #{code => too_many_waiters}}, Ready};
        {_, true} ->
            {Pid, _} = From,
            Waiters = maps:get(close_waiters, Ready),
            Next = Ready#{close_waiters => Waiters#{Tag => {Kind, From, monitor(process, Pid)}}},
            {noreply, Next}
    end;
handle_call({Generation, operation, Id, Kind, Tag}, From, #{generation := Generation} = State) ->
    case ensure_operation(Id, State) of
        {error, Error} -> {reply, {error, Error}, State};
        {ok, Next} -> operation_call(Id, Kind, Tag, From, Next)
    end;
handle_call(_, _, State) -> {reply, {error, #{code => server_expired}}, State}.

-doc false.
-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({Generation, unwait, Id, Tag}, #{generation := Generation} = State) ->
    {noreply, remove_waiter(Id, Tag, State)};
handle_cast({Generation, unclose, Tag}, #{generation := Generation} = State) ->
    {noreply, remove_close_waiter(Tag, State)};
handle_cast({Generation, unwatch_closing, Watch, Pid}, #{generation := Generation} = State) ->
    case unwatch(Watch, Pid, State) of
        {ok, Next} -> {noreply, Next};
        _ -> {noreply, State}
    end;
handle_cast(_, State) -> {noreply, State}.

-doc false.
-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({tmux_admission, Generation, Id, Owner, Payload}, #{generation := Generation} = State) ->
    continue(admit(Id, Owner, Payload, State));
handle_info({timeout, Timer, sweep}, #{sweep := Timer} = State) ->
    Next = expire_results(expire_leases(State)),
    continue(Next#{sweep => erlang:start_timer(100, self(), sweep)});
handle_info({timeout, Timer, {deadline, Id}}, State) ->
    case maps:find(Id, maps:get(operations, State)) of
        {ok, #{timer := Timer}} -> continue(cancel_operation(Id, deadline, State));
        _ -> {noreply, State}
    end;
handle_info({timeout, Timer, close}, #{close_timer := Timer} = State) ->
    Next = reply_close({error, #{code => cleanup_incomplete}}, State#{close_timer => none}),
    continue(Next);
handle_info({timeout, Timer, expire}, #{retention_timer := Timer, phase := closed} = State) ->
    {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, #{owner_monitor := Monitor} = State) ->
    continue(begin_close(State#{owner_alive => false}));
handle_info({'DOWN', Monitor, process, _, _}, #{registry_monitor := Monitor} = State) ->
    continue(begin_close(State#{valid => false}));
handle_info({'DOWN', Monitor, process, _, _} = Message, State) ->
    case response(Message, State) of
        no_reply -> continue(owner_down(Monitor, State));
        Next -> continue(Next)
    end;
handle_info(Message, State) ->
    case response(Message, State) of
        no_reply -> {noreply, State};
        Next -> continue(Next)
    end.

-doc false.
-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun
        (state, State) -> public_status(State);
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (_, Value) -> Value
    end, maps:without([log], Status)).

endpoint_options(#{socket_path := <<$/, _/binary>> = Socket} = Options)
  when byte_size(Socket) < 104 ->
    Executable = maps:get(executable, Options, case os:find_executable("tmux") of
        false -> none;
        Path -> unicode:characters_to_binary(Path)
    end),
    case maps:without([socket_path, executable], Options) =:= #{} andalso
         binary:match(Socket, <<0>>) =:= nomatch andalso is_binary(Executable) of
        true ->
            case Executable of
                <<$/, _/binary>> -> {ok, #{socket_path => Socket, executable => Executable}};
                _ -> {error, #{code => invalid_executable}}
            end;
        false -> {error, #{code => invalid_endpoint}}
    end;
endpoint_options(_) -> {error, #{code => invalid_endpoint}}.

submission(Command, Options, Started) when is_map(Options), is_integer(Started) ->
    Defaults = #{deadline_ms => 2500, max_stdout => 1048576, max_stderr => 65536,
                 stdin => <<>>, identity => observed},
    #{deadline_ms := Timeout, max_stdout := Out, max_stderr := Err,
      stdin := Input, identity := Identity} = maps:merge(Defaults, Options),
    Valid = maps:without(maps:keys(Defaults), Options) =:= #{} andalso
            is_integer(Timeout, 1, 600000) andalso is_integer(Out, 0, 1048576) andalso
            is_integer(Err, 0, 65536) andalso is_binary(Input) andalso byte_size(Input) =< 262144,
    case {Valid, Identity} of
        {false, _} -> {error, #{code => invalid_operation_options}};
        {_, same_connection} -> {error, #{code => unsupported_identity_guarantee}};
        {_, observed} ->
            maybe
                {ok, Validated} ?= tmux_command:validate(Command),
                Args = tmux_command:argv(Validated),
                Bytes = byte_size(Input) + lists:sum([byte_size(A) + 3 || A <- Args]),
                case Bytes =< 262144 of
                    true -> {ok, #{command => Validated, args => Args,
                                  stdin => compact(Input), bytes => Bytes,
                                  max_stdout => Out, max_stderr => Err, deadline => Started + Timeout,
                                  cost => 32768 + 2 * (Out + Err)}};
                    false -> {error, #{code => command_limit}}
                end
            end;
        _ -> {error, #{code => unsupported_identity_guarantee}}
    end;
submission(_, _, _) -> {error, #{code => invalid_operation_options}}.

endpoint_args(Config, Args) -> [<<"-u">>, <<"-N">>, <<"-S">>, maps:get(socket_path, Config) | Args].
probe_args() -> [<<"display-message">>, <<"-p">>, <<"#{pid}\t#{version}">>].

require_version(Raw) ->
    case tmux_version:require(Raw) of
        {ok, Version} -> {ok, Version};
        {error, {Code, _}} -> {error, #{code => Code}}
    end.

parse_probe(Bytes) ->
    case binary:split(Bytes, <<"\t">>, [global]) of
        [Pid, Version] when byte_size(Pid) < 11 ->
            try binary_to_integer(Pid) of
                Number when is_integer(Number, 1, 2147483647) ->
                    case require_version(<<"tmux ", Version/binary>>) of
                        {ok, Parsed} -> {ok, Number, Parsed};
                        Error -> Error
                    end;
                _ -> {error, #{code => invalid_server_identity}}
            catch error:badarg -> {error, #{code => invalid_server_identity}}
            end;
        _ -> {error, #{code => invalid_server_identity}}
    end.

successful({ok, #{exit_status := 0} = Result}) -> {ok, Result};
successful({ok, Result}) -> {error, Result#{code => command_error, outcome => error}};
successful(Error) -> Error.

ensure_operation(Id, #{operations := Operations, admission := Admission} = State) ->
    Now = now_ms(),
    case maps:find(Id, Operations) of
        {ok, #{retired := true, expires := Expires}} when Expires =< Now ->
            {error, #{code => operation_expired}};
        {ok, _} -> {ok, State};
        error ->
            case tmux_admission:lookup(Admission, Id) of
                {ok, #{owner := Owner, expires := Deadline}} ->
                    {ok, put_operation(Id, new_operation(Owner, Deadline), State)};
                {error, _} -> {error, #{code => operation_expired}}
            end
    end.

new_operation(Owner, Deadline) ->
    #{owner => Owner, monitor => monitor(process, Owner), phase => queued,
      stage => pending, spec => none, deadline => Deadline, timer => none,
      handle => none, cost => 0, cancel => none, result => none,
      retired => false, waiters => #{}}.

admit(Id, Owner, {Command, Options, Started}, State) ->
    case submission(Command, Options, Started) of
        {ok, Spec} ->
            Origin = maps:get(origin, State),
            case tmux_command:provenance(maps:get(command, Spec)) of
                none -> admit_validated(Id, Owner, Spec, State);
                #{origin := Origin} -> admit_validated(Id, Owner, Spec, State);
                _ -> reject(Id, #{code => different_owner}, State)
            end;
        {error, Error} -> reject(Id, Error, State)
    end;
admit(Id, _, _, State) -> reject(Id, #{code => invalid_command}, State).

admit_validated(Id, Owner, #{bytes := Bytes, deadline := Deadline} = Spec, State) ->
    case tmux_admission:claim(maps:get(admission, State), Id, Owner, Bytes) of
        ok ->
            {ok, Next} = ensure_operation(Id, State),
            Op = operation(Id, Next),
            Timer = erlang:start_timer(Deadline, self(), {deadline, Id}, [{abs, true}]),
            put_operation(Id, Op#{spec => maps:remove(command, Spec), stage => waiting,
                deadline => Deadline, timer => Timer},
                Next#{queue => queue:in(Id, maps:get(queue, Next))});
        {error, _} -> expire_leases(State)
    end.

reject(Id, Error, State) ->
    case ensure_operation(Id, State) of
        {ok, Next} -> finish(Id, before_send(Error), Next);
        {error, _} -> State
    end.

operation_call(Id, status, _, _, State) ->
    {reply, {ok, operation_status(operation(Id, State))}, State};
operation_call(Id, cancel, _, _, State) ->
    #{result := Result, handle := Handle} = operation(Id, State),
    Reply = case {Result, Handle} of
        {none, none} -> cancelled_before_send;
        {none, _} -> cancel_requested;
        _ -> already_completed
    end,
    {reply, {ok, Reply}, advance(cancel_operation(Id, cancelled, State))};
operation_call(Id, {transfer, Owner}, _, {Caller, _}, State) ->
    Op = operation(Id, State),
    case maps:get(owner, Op) =:= Caller andalso is_pid(Owner) andalso
         node(Owner) =:= node() andalso is_process_alive(Owner) andalso not maps:get(retired, Op) of
        true ->
            Monitor = monitor(process, Owner),
            demonitor(maps:get(monitor, Op), [flush]),
            {reply, ok, put_operation(Id, Op#{owner => Owner, monitor => Monitor}, State)};
        false -> {reply, {error, #{code => invalid_owner}}, State}
    end;
operation_call(Id, Kind, Tag, From, State) when Kind =:= await; Kind =:= started ->
    Op = operation(Id, State),
    case {Kind, maps:get(phase, Op), maps:get(result, Op)} of
        {started, Phase, _} when Phase =/= queued ->
            {reply, {ok, operation_status(Op)}, State};
        {_, _, Result} when Result =/= none -> {reply, Result, State};
        _ -> add_waiter(Id, Kind, Tag, From, State)
    end;
operation_call(_, _, _, _, State) -> {reply, {error, #{code => invalid_operation}}, State}.

add_waiter(Id, Kind, Tag, {Pid, _} = From, State) ->
    Op = operation(Id, State),
    Waiters = maps:get(waiters, Op),
    case map_size(Waiters) < 16 of
        true ->
            Next = Op#{waiters => Waiters#{Tag => {Kind, From, monitor(process, Pid)}}},
            {noreply, put_operation(Id, Next, State)};
        false -> {reply, {error, #{code => too_many_waiters}}, State}
    end.

remove_waiter(Id, Tag, State) ->
    case maps:find(Id, maps:get(operations, State)) of
        {ok, Op} ->
            case maps:take(Tag, maps:get(waiters, Op)) of
                {{_, _, Monitor}, Rest} ->
                    demonitor(Monitor, [flush]), put_operation(Id, Op#{waiters => Rest}, State);
                error -> State
            end;
        error -> State
    end.

notify(Id, State) ->
    Op = operation(Id, State),
    maps:fold(fun(Tag, {Kind, From, _}, Acc) ->
        case {Kind, maps:get(phase, Op), maps:get(result, Op)} of
            {started, Phase, _} when Phase =/= queued ->
                gen_server:reply(From, {ok, operation_status(Op)}), remove_waiter(Id, Tag, Acc);
            {_, _, Result} when Result =/= none ->
                gen_server:reply(From, Result), remove_waiter(Id, Tag, Acc);
            _ -> Acc
        end
    end, State, maps:get(waiters, Op)).

schedule(#{phase := Phase} = State) when Phase =/= open -> State;
schedule(State) ->
    case queue:out(maps:get(queue, State)) of
        {empty, _} -> State;
        {{value, Id}, Rest} ->
            Op = operation(Id, State),
            Next = State#{queue => Rest},
            case {maps:get(retired, Op), maps:get(valid, State), maps:get(deadline, Op) > now_ms()} of
                {true, _, _} -> schedule(Next);
                {_, false, _} -> schedule(finish(Id, before_send(#{code => stale_server}), Next));
                {_, _, false} -> schedule(cancel_operation(Id, deadline, Next));
                _ ->
                    Cost = maps:get(cost, maps:get(spec, Op)),
                    Used = maps:get(active_bytes, State) + maps:get(result_bytes, State),
                    case Used + Cost =< ?PAYLOAD_BUDGET of
                        false -> State;
                        true ->
                            Reserved = put_operation(Id, Op#{cost => Cost},
                                Next#{active_bytes => maps:get(active_bytes, Next) + Cost}),
                            schedule(preflight(Id, Reserved))
                    end
            end
    end.

preflight(Id, #{config := Config} = State) ->
    case tmux_identity:check(maps:get(identity, Config), maps:get(server_pid, Config)) of
        ok -> start_stage(Id, preflight, probe_args(), State);
        {error, Error} -> finish(Id, before_send(Error), invalidate(State))
    end.

invalidate(State) ->
    ok = tmux_admission:close(maps:get(admission, State)),
    Next = notify_closing_watchers(invalidated, State),
    _ = tmux_registry:revoke(maps:get(origin, State)),
    Next#{valid => false}.

start_stage(Id, Stage, Args, #{config := Config} = State) ->
    Op = operation(Id, State),
    Remaining = maps:get(deadline, Op) - now_ms(),
    case Remaining > 0 andalso maps:get(cancel, Op) =:= none andalso maps:get(phase, State) =:= open of
        false -> finish(Id, before_send(#{code => deadline}), State);
        true ->
            Options = case Stage of
                preflight -> #{max_stdout => 128, max_stderr => 4096};
                command -> maps:with([stdin, max_stdout, max_stderr], maps:get(spec, Op))
            end,
            Phase = case Stage of preflight -> queued; command -> sent end,
            Next = put_operation(Id, Op#{stage => Stage, phase => Phase}, State),
            case tmux_transport:start(maps:get(executable, Config), endpoint_args(Config, Args),
                                      Options#{timeout_ms => Remaining}) of
                {ok, Handle} ->
                    Requests = gen_server:reqids_add(tmux_transport:send_request(Handle, await),
                        {Id, Stage, result}, maps:get(requests, Next)),
                    Started = put_operation(Id, (operation(Id, Next))#{handle => Handle},
                                            Next#{requests => Requests}),
                    notify(Id, Started);
                {error, Error} -> finish(Id, before_send(Error), Next)
            end
    end.

response(Message, State) ->
    case gen_server:check_response(Message, maps:get(requests, State), true) of
        {{reply, Result}, {Id, Stage, Kind}, Requests} ->
            transport_result(Id, Stage, Kind, Result, State#{requests => Requests});
        {{error, _}, {Id, _, _}, Requests} ->
            incomplete(Id, #{code => cleanup_incomplete, cause => transport_owner_lost,
                             cleanup => incomplete}, State#{requests => Requests});
        _ -> no_reply
    end.

transport_result(Id, _, retired, {_, #{cleanup := complete}}, State) ->
    Op = operation(Id, State),
    {Tag, Detail} = maps:get(result, Op),
    finish(Id, {Tag, Detail#{cleanup => complete}}, State);
transport_result(Id, Stage, result, {Tag, #{cleanup := complete} = Detail}, State) ->
    Op = operation(Id, State),
    ok = tmux_transport:close_async(maps:get(handle, Op)),
    Next = put_operation(Id, Op#{handle => none}, State),
    case {Stage, maps:get(cancel, Op), Tag} of
        {preflight, none, ok} ->
            case successful({ok, Detail}) of
                {ok, _} -> validate_observation(Id, maps:get(stdout, Detail), Next);
                {error, Error} -> finish(Id, before_send(Error), Next)
            end;
        {preflight, none, error} -> finish(Id, before_send(Detail), Next);
        {preflight, Cause, _} -> finish(Id, before_send(#{code => Cause}), Next);
        {command, Cause, _} when Cause =/= none ->
            finish(Id, {error, Detail#{code => Cause, outcome => unknown}}, Next);
        {command, none, ok} ->
            case maps:get(exit_status, Detail) of
                0 -> finish(Id, {ok, Detail#{outcome => success}}, Next);
                _ -> finish(Id, {error, Detail#{code => command_error, outcome => error}}, Next)
            end;
        {command, none, error} -> finish(Id, {error, Detail}, Next)
    end;
transport_result(Id, Stage, result, {_, Detail}, State) ->
    Next = incomplete(Id, Detail, State),
    Handle = maps:get(handle, operation(Id, Next)),
    Requests = gen_server:reqids_add(tmux_transport:send_request(Handle, retired),
                                    {Id, Stage, retired}, maps:get(requests, Next)),
    Next#{requests => Requests};
transport_result(Id, _, _, _, State) ->
    incomplete(Id, #{code => cleanup_incomplete, cause => invalid_transport_response,
                     cleanup => incomplete}, State).

validate_observation(Id, Bytes, #{config := Config} = State) ->
    Checked = maybe
        {ok, Pid, _} ?= parse_probe(Bytes),
        tmux_identity:check(maps:get(identity, Config), Pid)
    end,
    case Checked of
        ok -> start_stage(Id, command, maps:get(args, maps:get(spec, operation(Id, State))), State);
        {error, Error} -> finish(Id, before_send(Error), invalidate(State))
    end.

cancel_operation(Id, Cause, State) ->
    Op = operation(Id, State),
    case {maps:get(result, Op), maps:get(handle, Op)} of
        {none, none} -> finish(Id, before_send(#{code => Cause}), State);
        {none, Handle} ->
            ok = tmux_transport:cancel_async(Handle),
            FirstCause = case maps:get(cancel, Op) of none -> Cause; Existing -> Existing end,
            put_operation(Id, Op#{cancel => FirstCause}, State);
        _ -> State
    end.

before_send(Detail) ->
    Outcome = case maps:get(code, Detail) of
        cancelled -> cancelled_before_send;
        deadline -> cancelled_before_send;
        owner_down -> cancelled_before_send;
        server_closed -> cancelled_before_send;
        admission_expired -> cancelled_before_send;
        _ -> error
    end,
    {error, Detail#{outcome => Outcome, submitted => false, cleanup => complete}}.

incomplete(Id, Detail, State) ->
    Op = operation(Id, State),
    Outcome = case maps:get(stage, Op) of command -> unknown; _ -> cancelled_before_send end,
    Result = {error, Detail#{code => cleanup_incomplete, cleanup => incomplete, outcome => Outcome}},
    notify(Id, put_operation(Id, Op#{phase => responded, result => Result}, State)).

finish(Id, Result, State) ->
    Op = operation(Id, State),
    case maps:get(retired, Op) of
        true -> State;
        false ->
            cancel_timer(maps:get(timer, Op)),
            demonitor(maps:get(monitor, Op), [flush]),
            case maps:get(handle, Op) of none -> ok; Handle -> ok = tmux_transport:close_async(Handle) end,
            ok = tmux_admission:release(maps:get(admission, State), Id),
            Expires = now_ms() + 60000,
            Bytes = result_size(Result),
            Retired = Op#{phase => retired, result => Result, retired => true, spec => none,
                          handle => none, cost => 0, expires => Expires, result_bytes => Bytes},
            Next = State#{active_bytes => maps:get(active_bytes, State) - maps:get(cost, Op),
                          result_bytes => maps:get(result_bytes, State) + Bytes,
                          queue => queue:filter(fun(Queued) -> Queued =/= Id end, maps:get(queue, State)),
                          completed => queue:in({Id, Expires}, maps:get(completed, State))},
            expire_results(notify(Id, put_operation(Id, Retired, Next)))
    end.

result_size({_, Detail}) ->
    byte_size(maps:get(stdout, Detail, <<>>)) + byte_size(maps:get(stderr, Detail, <<>>)).

expire_leases(State) ->
    Expired = tmux_admission:expire(maps:get(admission, State)),
    lists:foldl(fun({Id, #{owner := Owner, expires := Deadline}}, Acc) ->
        Next = case maps:is_key(Id, maps:get(operations, Acc)) of
            true -> Acc;
            false -> put_operation(Id, new_operation(Owner, Deadline), Acc)
        end,
        Cause = case is_process_alive(Owner) of true -> admission_expired; false -> owner_down end,
        finish(Id, before_send(#{code => Cause}), Next)
    end, State, Expired).

expire_results(State) ->
    Completed = maps:get(completed, State),
    case queue:out(Completed) of
        {empty, _} -> State;
        {{value, {Id, Expires}}, Rest} ->
            case Expires =< now_ms() orelse queue:len(Completed) > 64 orelse maps:get(result_bytes, State) > 4194304 of
                false -> State;
                true ->
                    Op = operation(Id, State),
                    expire_results(State#{completed => Rest,
                        operations => maps:remove(Id, maps:get(operations, State)),
                        result_bytes => maps:get(result_bytes, State) - maps:get(result_bytes, Op)})
            end
    end.

owner_down(Monitor, State) ->
    Next = maps:fold(fun(Id, Op, Acc) ->
        case maps:get(monitor, Op) =:= Monitor andalso not maps:get(retired, Op) of
            true -> cancel_operation(Id, owner_down, Acc);
            false -> maps:fold(fun(Tag, {_, _, Ref}, S) ->
                case Ref =:= Monitor of true -> remove_waiter(Id, Tag, S); false -> S end
            end, Acc, maps:get(waiters, Op))
        end
    end, State, maps:get(operations, State)),
    Closed = maps:fold(fun(Tag, {_, _, Ref}, Acc) ->
        case Ref =:= Monitor of true -> remove_close_waiter(Tag, Acc); false -> Acc end
    end, Next, maps:get(close_waiters, Next)),
    maps:fold(fun(Watch, {_, Ref}, Acc) ->
        case Ref =:= Monitor of true -> remove_closing_watcher(Watch, Acc); false -> Acc end
    end, Closed, maps:get(closing_watchers, Closed)).

prune_closing_watchers(State) ->
    maps:fold(fun(Watch, {Pid, _}, Acc) ->
        case is_process_alive(Pid) of
            true -> Acc;
            false -> remove_closing_watcher(Watch, Acc)
        end
    end, State, maps:get(closing_watchers, State)).

unwatch(Watch, Pid, State) ->
    case maps:find(Watch, maps:get(closing_watchers, State)) of
        {ok, {Pid, _}} -> {ok, remove_closing_watcher(Watch, State)};
        error -> {ok, State};
        _ -> {error, #{code => not_owner}}
    end.

remove_closing_watcher(Watch, #{closing_watchers := Watchers} = State) ->
    case maps:take(Watch, Watchers) of
        {{_, Monitor}, Rest} ->
            demonitor(Monitor, [flush]),
            State#{closing_watchers => Rest};
        error -> State
    end.

notify_closing_watchers(Cause, State) ->
    Generation = maps:get(generation, State),
    maps:fold(fun(Watch, {Pid, _}, Acc) ->
        Pid ! {tmux_server_closing, self(), Generation, Watch, Cause},
        remove_closing_watcher(Watch, Acc)
    end, State, maps:get(closing_watchers, State)).

begin_close(#{phase := closed} = State) -> State;
begin_close(State) ->
    ok = tmux_admission:close(maps:get(admission, State)),
    Closing = notify_closing_watchers(closing, State),
    _ = case maps:get(phase, State) of
        open -> _ = tmux_registry:revoke(maps:get(origin, State));
        _ -> ok
    end,
    Next = expire_leases(Closing#{phase => closing}),
    Cancelled = lists:foldl(fun(Id, Acc) -> cancel_operation(Id, server_closed, Acc) end,
                            Next, maps:keys(maps:get(operations, Next))),
    case maps:get(close_timer, Cancelled) of
        none -> Cancelled#{close_timer => erlang:start_timer(900, self(), close)};
        _ -> Cancelled
    end.

advance(State) ->
    Next = schedule(State),
    case maps:get(phase, Next) =:= closing andalso
         maps:fold(fun(_, Op, Done) -> Done andalso maps:get(retired, Op) end,
                   true, maps:get(operations, Next)) of
        false -> Next;
        true ->
            cancel_timer(maps:get(close_timer, Next)),
            reply_close(ok, Next#{phase => closed, operations => #{}, queue => queue:new(),
                completed => queue:new(), result_bytes => 0, close_timer => none,
                retention_timer => erlang:start_timer(60000, self(), expire)})
    end.

reply_close(Reply, State) ->
    maps:fold(fun(Tag, {Kind, From, _}, Acc) ->
        case Kind =:= retired andalso Reply =/= ok of
            true -> Acc;
            false -> gen_server:reply(From, Reply), remove_close_waiter(Tag, Acc)
        end
    end, State, maps:get(close_waiters, State)).

remove_close_waiter(Tag, #{close_waiters := Waiters} = State) ->
    case maps:take(Tag, Waiters) of
        {{_, _, Monitor}, Rest} -> demonitor(Monitor, [flush]), State#{close_waiters => Rest};
        error -> State
    end.

continue(State) ->
    case advance(State) of
        #{phase := closed, owner_alive := false} = Next -> {stop, normal, Next};
        Next -> {noreply, Next}
    end.

operation(Id, State) -> maps:get(Id, maps:get(operations, State)).
put_operation(Id, Operation, State) ->
    State#{operations => (maps:get(operations, State))#{Id => Operation}}.

operation_status(Op) ->
    {Outcome, Cleanup} = case maps:get(result, Op) of
        none -> {pending, pending};
        {_, Detail} -> {maps:get(outcome, Detail, unknown), maps:get(cleanup, Detail, incomplete)}
    end,
    (maps:with([phase, stage, owner], Op))#{outcome => Outcome, cleanup => Cleanup}.

public_status(State) ->
    {ok, Admission} = tmux_admission:stats(maps:get(admission, State)),
    #{phase => maps:get(phase, State), generation => maps:get(generation, State),
      owner => self(), operations => maps:get(operations, Admission),
      command_bytes => maps:get(bytes, Admission), active_bytes => maps:get(active_bytes, State),
      retained_results => queue:len(maps:get(completed, State)),
      result_bytes => maps:get(result_bytes, State)}.

cancel_timer(none) -> ok;
cancel_timer(Timer) -> _ = erlang:cancel_timer(Timer), ok.

compact(Bytes) ->
    case binary:referenced_byte_size(Bytes) =:= byte_size(Bytes) of
        true -> Bytes;
        false -> binary:copy(Bytes)
    end.

now_ms() -> erlang:monotonic_time(millisecond).
