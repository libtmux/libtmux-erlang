-module(tmux_control).
-moduledoc """
Own an explicit persistent tmux control attachment.

`attach/3` attaches to an existing session from `m:tmux_server` and verifies
the daemon identity on that connection. The caller owns its lifetime.
Attachment changes the session's attached-client count. The command client
uses no-output and ignore-size; -E skips attachment's environment update.
The library issues no session-option writes or session-creation commands.
Configured hooks and native lifetime policies can still change state,
including on failed attach or detachment. Those effects are not rolled back.
Command submission and terminal streaming are not yet exposed.

Use `close/1` before closing the parent endpoint. Parent closing, invalidation
or caller death requests retirement, but parent close alone does not prove
this client's exit. Control close and `status/1` report its native cleanup.
Neither detachment nor cancellation reverses remote effects. Application
shutdown alone is not a verified cleanup result.
""".
-behaviour(gen_server).
-export([attach/3, close/1, status/1]).
-export([start_link/4, init/1, handle_continue/2, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, format_status/1, send_request/2]).
-export_type([t/0, attach_options/0, state/0]).

-doc "A generation-bound connection handle. Passing it does not transfer lifetime ownership.".
-opaque t() :: {control, pid(), reference()}.
-doc "Finite attachment budget, including parent registration, exec and identity. Defaults to 2500 ms.".
-type attach_options() :: #{startup_timeout_ms => 1..600000}.
-doc """
Connection state, separate from command completion. complete proves native
client/helper retirement; pending and incomplete do not. Retained PIDs are
diagnostic observations, never permission to signal a process.
""".
-type state() :: #{phase := attaching | open | closing | closed,
    generation := reference(), owner := pid(), identity := unverified | same_connection,
    cleanup := pending | incomplete | complete, child_pid := none | pos_integer(),
    helper_pid := none | pos_integer(), cause := none | atom()}.

-doc """
Attach to an existing captured session from this exact endpoint origin.
Performs I/O and waits for a same-connection identity probe. Uses attach-session
with -E rather than creating a session or writing options. Configured hooks
may change state; failure does not reverse their effects. The control client
affects attached_count.
Unexpected hook-generated reply blocks fail attachment and retire the client.

An attachment timeout requests cleanup. If cleanup cannot be proved within
its finite deadline, the error includes a control handle for `close/1` recovery.
The supervised owner remains until native retirement. Close explicitly to
observe cleanup, including when the parent endpoint is already closed.
""".
-spec attach(tmux_server:t(), tmux_model:session(), attach_options()) ->
    {ok, t()} | {error, map()}.
attach(Server, Session, Options) ->
    Started = now_ms(),
    maybe
        {ok, Timeout} ?= options(Options),
        {ok, Origin, Target} ?= tmux_target:captured_target(session, Session),
        Generation = make_ref(),
        Config = #{origin => Origin, target => Target, deadline => Started + Timeout},
        Child = #{id => Generation, start => {?MODULE, start_link,
            [self(), Generation, Server, Config]}, restart => temporary, shutdown => 1000},
        try supervisor:start_child(tmux_sup, Child) of
            {ok, Pid} ->
                Control = {control, Pid, Generation},
                case request(Control, ready, max(0, Started + Timeout + 1000 - now_ms())) of
                    ok -> {ok, Control};
                    {error, Error} ->
                        gen_server:cast(Pid, {Generation, close}),
                        {error, Error#{control => Control}}
                end;
            {error, _} -> {error, #{code => control_unavailable, cleanup => complete}}
        catch
            exit:{noproc, _} -> {error, #{code => control_unavailable, cleanup => complete}};
            exit:_ -> {error, #{code => control_unavailable, cleanup => unverified}}
        end
    end.

-doc """
Retire this control client and its helper without issuing session or daemon
destruction commands. Native lifetime policies and detachment hooks may still
change state; cleanup does not reverse their effects. Returns ok only after
actual retirement. A finite cleanup failure leaves a supervised owner for
retry and observation.
Successful close is idempotent during the 60-second handle retention period.
""".
-spec close(t()) -> ok | {error, map()}.
close(Control) -> request(Control, close, 1000).

-doc """
Read retained connection state without a tmux command. Inspect cleanup rather
than inferring native exit from the Erlang owner's lifecycle. Closed handles
expire after 60 seconds and then return control_expired.
""".
-spec status(t()) -> {ok, state()} | {error, map()}.
status(Control) -> request(Control, status, 900).

request({control, Pid, Generation}, Kind, Timeout)
  when is_pid(Pid), is_reference(Generation) ->
    Tag = make_ref(),
    Request = gen_server:send_request(Pid, {Generation, Kind, Tag}),
    case gen_server:receive_response(Request, Timeout) of
        {reply, Reply} -> Reply;
        timeout ->
            gen_server:cast(Pid, {Generation, unwait, Tag}),
            Code = case Kind of close -> cleanup_incomplete; _ -> await_timeout end,
            {error, #{code => Code, cleanup => unverified}};
        {error, _} -> {error, #{code => control_expired, cleanup => unverified}}
    end;
request(_, _, _) -> {error, #{code => invalid_control}}.

-doc false.
-spec send_request(t(), retired) -> gen_server:request_id().
send_request({control, Pid, Generation}, retired) ->
    gen_server:send_request(Pid, {Generation, retired, make_ref()}).

-doc false.
-spec start_link(pid(), reference(), tmux_server:t(), map()) -> gen_server:start_ret().
start_link(Owner, Generation, Server, Config) ->
    gen_server:start_link(?MODULE, {Owner, Generation, Server, Config}, []).

-doc false.
-spec init({pid(), reference(), tmux_server:t(), map()}) ->
    {ok, map(), {continue, launch}}.
init({Owner, Generation, Server, Config}) ->
    {ok, #{owner => Owner, owner_monitor => monitor(process, Owner),
        generation => Generation, server => Server, config => Config, context => none,
        parent_monitor => none, watch => none, channel => none,
        requests => gen_server:reqids_new(), phase => attaching, startup => attachment,
        codec => tmux_control_codec:new(Generation), block => none, probe => none,
        write => none, child_pid => none, helper_pid => none,
        identity => unverified, cleanup => pending, cause => none,
        failure => none, diagnostics => <<>>, startup_bytes => 0,
        timer => none, close_timer => none, retention_timer => none, waiters => #{}},
        {continue, launch}}.

-doc false.
-spec handle_continue(launch, map()) -> {noreply, map()}.
handle_continue(launch, State) -> {noreply, launch(State)}.

-doc false.
-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()} | {noreply, map()}.
handle_call({Generation, status, _}, _, #{generation := Generation} = State) ->
    {reply, {ok, public_status(State)}, State};
handle_call({Generation, Kind, Tag}, From, #{generation := Generation} = State)
  when Kind =:= ready; Kind =:= close; Kind =:= retired ->
    Next = case Kind of close -> retire(closed, State); _ -> State end,
    case answer(Kind, Next) of
        pending -> add_waiter(Kind, Tag, From, Next);
        Reply -> {reply, Reply, Next}
    end;
handle_call(_, _, State) -> {reply, {error, #{code => invalid_control}}, State}.

-doc false.
-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({Generation, close}, #{generation := Generation} = State) ->
    {noreply, retire(closed, State)};
handle_cast({Generation, unwait, Tag}, #{generation := Generation} = State) ->
    {noreply, remove_waiter(Tag, State)};
handle_cast(_, State) -> {noreply, State}.

-doc false.
-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({tmux_transport, Channel, {data, stdout, Sequence, Bytes}},
            #{channel := Channel} = State) ->
    Next = stdout(Bytes, State),
    case maps:get(phase, Next) of
        closing -> {noreply, Next};
        closed -> {noreply, Next};
        _ ->
            case tmux_transport:ack(Channel, stdout, Sequence) of
                ok -> {noreply, Next};
                {error, Error} -> {noreply, fail(Error, Next)}
            end
    end;
handle_info({tmux_transport, Channel, {data, stderr, Sequence, Bytes}},
            #{channel := Channel, diagnostics := Previous} = State) ->
    case byte_size(Previous) + byte_size(Bytes) =< 65536 of
        true ->
            Next = State#{diagnostics => <<Previous/binary, Bytes/binary>>},
            case tmux_transport:ack(Channel, stderr, Sequence) of
                ok -> {noreply, Next};
                {error, Error} -> {noreply, fail(Error, Next)}
            end;
        false -> {noreply, fail(#{code => control_diagnostic_limit}, State)}
    end;
handle_info({tmux_transport, Channel, {write_ack, Id, Size}},
            #{channel := Channel, write := {Id, Size}} = State) ->
    case tmux_transport:ack_write(Channel, Id) of
        ok -> {noreply, maybe_ready(State#{write => none})};
        {error, Error} -> {noreply, fail(Error, State)}
    end;
handle_info({tmux_transport, Channel, {eof, stdout}}, #{channel := Channel} = State) ->
    {noreply, fail(#{code => control_eof}, State)};
handle_info({tmux_server_closing, Parent, ParentGeneration, Watch, _},
            #{context := #{owner := Parent, generation := ParentGeneration}, watch := Watch} = State) ->
    {noreply, retire(parent_closed, State)};
handle_info({timeout, Timer, startup}, #{timer := Timer} = State) ->
    {noreply, fail(#{code => startup_timeout}, State#{timer => none})};
handle_info({timeout, Timer, cleanup}, #{close_timer := Timer} = State) ->
    {noreply, reply_waiters(State#{cleanup => incomplete, close_timer => none})};
handle_info({timeout, Timer, expire}, #{retention_timer := Timer, phase := closed} = State) ->
    {stop, normal, State};
handle_info({'DOWN', Ref, process, _, _}, #{owner_monitor := Ref} = State) ->
    {noreply, retire(owner_down, State)};
handle_info({'DOWN', Ref, process, _, _}, #{parent_monitor := Ref} = State) when is_reference(Ref) ->
    {noreply, retire(parent_down, State)};
handle_info(Message, State) ->
    case gen_server:check_response(Message, maps:get(requests, State), true) of
        {{reply, Reply}, Label, Requests} ->
            {noreply, native_reply(Label, Reply, State#{requests => Requests})};
        {{error, _}, _, Requests} ->
            {noreply, fail(#{code => channel_unavailable}, State#{requests => Requests})};
        _ -> {noreply, subscriber_down(Message, State)}
    end.

-doc false.
-spec terminate(term(), map()) -> ok.
terminate(_, #{channel := none}) -> ok;
terminate(_, #{channel := Channel}) -> tmux_transport:cancel_async(Channel).

-doc false.
-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun
        (state, State) -> public_status(State);
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (_, Value) -> Value
    end, maps:without([log], Status)).

options(Options) when is_map(Options) ->
    Timeout = maps:get(startup_timeout_ms, Options, 2500),
    case maps:without([startup_timeout_ms], Options) =:= #{} andalso is_integer(Timeout, 1, 600000) of
        true -> {ok, Timeout};
        false -> {error, #{code => invalid_control_options}}
    end;
options(_) -> {error, #{code => invalid_control_options}}.

launch(#{server := Server, config := Config} = State) ->
    Remaining = maps:get(deadline, Config) - now_ms(),
    case Remaining > 0 andalso is_process_alive(maps:get(owner, State)) of
        false -> fail(#{code => startup_timeout}, State);
        true ->
            case tmux_server:watch_closing(Server, min(900, Remaining)) of
                {ok, Watch, Context} ->
                    Next = State#{watch => Watch, context => Context,
                        parent_monitor => monitor(process, maps:get(owner, Context))},
                    case maps:get(origin, Context) =:= maps:get(origin, Config) of
                        false -> fail(#{code => different_owner}, Next);
                        true -> launch_channel(Next)
                    end;
                {error, Error} -> fail(Error, State)
            end
    end.

launch_channel(#{context := #{config := Native}, config := Config} = State) ->
    Remaining = maps:get(deadline, Config) - now_ms(),
    case authorized(State) andalso Remaining > 0 of
        false -> fail(#{code => parent_closed}, State);
        true ->
            Flags = case tmux_version:at_least(maps:get(version, Native), {3, 6}) of
                true -> <<"no-output,ignore-size,no-detach-on-destroy">>;
                false -> <<"no-output,ignore-size">>
            end,
            Args = [<<"-u">>, <<"-C">>, <<"-N">>, <<"-S">>, maps:get(socket_path, Native),
                <<"attach-session">>, <<"-E">>, <<"-f">>, Flags, <<"-t">>, maps:get(target, Config)],
            case tmux_transport:start_channel(maps:get(executable, Native), Args,
                                              #{startup_timeout_ms => min(600000, Remaining)}) of
                {ok, Channel} ->
                    Requests = lists:foldl(fun(Kind, Acc) ->
                        gen_server:reqids_add(tmux_transport:send_request(Channel, Kind), Kind, Acc)
                    end, maps:get(requests, State), [started, await, retired]),
                    State#{channel => Channel,
                        requests => Requests, timer => erlang:start_timer(Remaining, self(), startup)};
                {error, Error} -> fail(Error, State)
            end
    end.

authorized(#{context := #{admission := Admission}, owner := Owner}) ->
    is_process_alive(Owner) andalso
        case tmux_admission:stats(Admission) of {ok, #{open := true}} -> true; _ -> false end;
authorized(_) -> false.

stdout(_, #{phase := Phase} = State) when Phase =:= closing; Phase =:= closed -> State;
stdout(Bytes, State) ->
    Used = maps:get(startup_bytes, State) + byte_size(Bytes),
    case maps:get(phase, State) =:= attaching andalso Used > 1048576 of
        true -> fail(#{code => control_startup_limit}, State);
        false ->
            Next = case maps:get(phase, State) of attaching -> State#{startup_bytes => Used}; _ -> State end,
            case tmux_control_codec:feed(maps:get(codec, State), Bytes) of
                {ok, Events, Codec} -> events(Events, Next#{codec => Codec});
                {error, Error, _} -> fail(Error, Next)
            end
    end.

events([], State) -> maybe_ready(State);
events(_, #{phase := Phase} = State) when Phase =:= closing; Phase =:= closed -> State;
events([Event | Rest], State) -> events(Rest, event(Event, State)).

event({notification, _, _}, State) -> State;
event({exit, _, _}, State) -> fail(#{code => control_exit}, State);
event({block_begin, #{flags := 0} = Guard}, #{startup := attachment, block := none} = State) ->
    State#{block => {Guard, <<>>}, startup => attachment_block};
event({block_begin, #{flags := 1} = Guard}, #{startup := probe, block := none} = State) ->
    State#{block => {Guard, <<>>}};
event({block_begin, _}, State) -> fail(#{code => unexpected_control_block}, State);
event({block_data, Guard, Bytes}, #{block := {Guard, Acc}} = State)
  when byte_size(Acc) + byte_size(Bytes) =< 128 ->
    State#{block => {Guard, <<Acc/binary, Bytes/binary>>}};
event({block_end, Guard, ok}, #{startup := attachment_block, block := {Guard, <<>>}} = State) ->
    probe(State#{block => none});
event({block_end, Guard, ok}, #{startup := probe, block := {Guard, Bytes}} = State) ->
    verify_probe(Bytes, State#{block => none});
event({block_end, _, error}, State) -> fail(#{code => control_attach_error}, State);
event(_, State) -> fail(#{code => unqualified_control_reply}, State).

probe(State) ->
    case {within_deadline(State), authorized(State)} of
        {false, _} -> fail(#{code => startup_timeout}, State);
        {_, false} -> fail(#{code => parent_closed}, State);
        {true, true} ->
            Nonce = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
            Bytes = <<"display-message -p \"", Nonce/binary, ":#{pid}:#{version}\"\n">>,
            case tmux_transport:write(maps:get(channel, State), Bytes) of
                {ok, Id} -> State#{startup => probe, probe => Nonce, write => {Id, byte_size(Bytes)}};
                {error, Error} -> fail(Error, State)
            end
    end.

verify_probe(Bytes, #{context := #{config := Native}, probe := Nonce} = State) ->
    Prefix = <<Nonce/binary, $:>>, Size = byte_size(Prefix),
    case Bytes of
        <<Prefix:Size/binary, Rest/binary>> ->
            ExpectedPid = integer_to_binary(maps:get(server_pid, Native)),
            case binary:split(Rest, <<":">>, [global]) of
                [ExpectedPid, Version] ->
                    case {tmux_version:require(<<"tmux ", Version/binary>>),
                          tmux_identity:check(maps:get(identity, Native), maps:get(server_pid, Native))} of
                        {{ok, Parsed}, ok} ->
                            Known = maps:get(version, Native),
                            case maps:without([raw], Parsed) =:= maps:without([raw], Known) of
                                true -> State#{startup => verified, identity => same_connection};
                                false -> fail(#{code => stale_server}, State)
                            end;
                        _ -> fail(#{code => stale_server}, State)
                    end;
                _ -> fail(#{code => stale_server}, State)
            end;
        _ -> fail(#{code => invalid_control_identity}, State)
    end.

maybe_ready(#{phase := attaching, startup := verified, write := none,
              child_pid := Child} = State) when is_integer(Child) ->
    case {within_deadline(State), authorized(State)} of
        {true, true} ->
            cancel_timer(maps:get(timer, State)),
            reply_waiters(State#{phase => open, timer => none, probe => none, startup_bytes => 0});
        {false, _} -> fail(#{code => startup_timeout}, State);
        _ -> fail(#{code => parent_closed}, State)
    end;
maybe_ready(State) -> State.

within_deadline(#{config := #{deadline := Deadline}}) -> now_ms() < Deadline.

native_reply(started, {ok, Native}, State) ->
    maybe_ready(State#{child_pid => maps:get(child_pid, Native), helper_pid => maps:get(helper_pid, Native)});
native_reply(retired, {_, #{cleanup := complete}}, State) -> closed(State);
native_reply(await, {error, Error}, State) -> fail(Error, State);
native_reply(await, {ok, _}, State) -> retire(control_exit, State);
native_reply(_, {error, Error}, State) -> fail(Error, State);
native_reply(_, _, State) -> fail(#{code => invalid_channel_response}, State).

fail(_, #{phase := closed} = State) -> State;
fail(Error, State) ->
    Next = case maps:get(failure, State) of none -> State#{failure => maps:with([code], Error)}; _ -> State end,
    retire(maps:get(code, Error), Next).

retire(_, #{phase := Phase} = State) when Phase =:= closing; Phase =:= closed -> State;
retire(Cause, State) ->
    cancel_timer(maps:get(timer, State)),
    unwatch(State),
    Next = State#{phase => closing, cause => Cause, timer => none, watch => none,
        block => none, codec => none, probe => none, write => none},
    case maps:get(channel, Next) of
        none -> closed(Next);
        Channel ->
            ok = tmux_transport:cancel_async(Channel),
            Next#{close_timer => erlang:start_timer(900, self(), cleanup)}
    end.

unwatch(#{watch := Watch, context := #{owner := Pid, generation := Generation}})
  when is_reference(Watch) ->
    gen_server:cast(Pid, {Generation, unwatch_closing, Watch, self()});
unwatch(_) -> ok.

closed(#{phase := closed} = State) -> State;
closed(State) ->
    Next = retire(control_exit, State),
    cancel_timer(maps:get(close_timer, Next)),
    reply_waiters(Next#{phase => closed, cleanup => complete, close_timer => none,
        retention_timer => erlang:start_timer(60000, self(), expire)}).

answer(status, State) -> {ok, public_status(State)};
answer(ready, #{phase := open}) -> ok;
answer(ready, #{cleanup := Cleanup, failure := Failure, cause := Cause}) when Cleanup =/= pending ->
    Error = case Failure of none -> #{code => Cause}; _ -> Failure end,
    {error, Error#{cleanup => Cleanup}};
answer(close, #{cleanup := complete}) -> ok;
answer(close, #{cleanup := incomplete}) -> {error, #{code => cleanup_incomplete}};
answer(retired, #{cleanup := complete}) -> ok;
answer(_, _) -> pending.

add_waiter(Kind, Tag, {Pid, _} = From, #{waiters := Waiters} = State) when map_size(Waiters) < 16 ->
    {noreply, State#{waiters => Waiters#{Tag => {Kind, From, monitor(process, Pid)}}}};
add_waiter(_, _, _, State) -> {reply, {error, #{code => too_many_waiters}}, State}.

remove_waiter(Tag, #{waiters := Waiters} = State) ->
    case maps:take(Tag, Waiters) of
        {{_, _, Monitor}, Rest} -> demonitor(Monitor, [flush]), State#{waiters => Rest};
        error -> State
    end.

reply_waiters(State) ->
    maps:fold(fun(Tag, {Kind, From, _}, Acc) ->
        case answer(Kind, Acc) of
            pending -> Acc;
            Reply -> gen_server:reply(From, Reply), remove_waiter(Tag, Acc)
        end
    end, State, maps:get(waiters, State)).

subscriber_down({'DOWN', Ref, process, _, _}, State) ->
    maps:fold(fun(Tag, {_, _, Monitor}, Acc) ->
        case Ref =:= Monitor of true -> remove_waiter(Tag, Acc); false -> Acc end
    end, State, maps:get(waiters, State));
subscriber_down(_, State) -> State.

public_status(State) -> maps:with([phase, generation, owner, identity, cleanup,
                                 child_pid, helper_pid, cause], State).

cancel_timer(none) -> ok;
cancel_timer(Timer) -> _ = erlang:cancel_timer(Timer), ok.
now_ms() -> erlang:monotonic_time(millisecond).
