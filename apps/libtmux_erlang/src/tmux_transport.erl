-module(tmux_transport).
-moduledoc false.
-behaviour(gen_server).
-export([run/3, start/3, await/2, await_started/2, cancel/1, close/1, status/1]).
-export([start_channel/3, ack/3, write/2, ack_write/2, close_stdin/1]).
-export([send_request/2, cancel_async/1, close_async/1]).
-export([start_link/3, init/1, handle_continue/2, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, format_status/1]).
-export_type([t/0, result/0]).

-opaque t() :: {transport, pid(), reference()} | {transport, pid(), reference(), pid()}.
-type result() :: {ok, map()} | {error, map()}.
-define(CLEANUP_MS, 900).
-define(WAITERS, 16).

-spec run(binary(), [binary()], map()) -> result().
run(Executable, Arguments, Options) ->
    case start(Executable, Arguments, Options) of
        {ok, Handle} ->
            try await(Handle, infinity)
            after _ = close(Handle)
            end;
        Error -> Error
    end.

-spec start(binary(), [binary()], map()) -> {ok, t()} | {error, map()}.
start(Executable, Arguments, Options) ->
    start(Executable, Arguments, Options, oneshot).

%% Private lifetime lane: one unacknowledged chunk per stream and one write
%% completion awaiting consumption. Only the initiating process advances them.
%% The startup deadline ends at exec acknowledgement, not application readiness.
%% Callers own their later readiness deadline and public admission boundary.
-spec start_channel(binary(), [binary()], map()) -> {ok, t()} | {error, map()}.
start_channel(Executable, Arguments, Options) when is_map(Options) ->
    case maps:without([startup_timeout_ms, cwd, env, inherit_env], Options) of
        Empty when map_size(Empty) =:= 0 ->
            Timeout = maps:get(startup_timeout_ms, Options, 900),
            Config = (maps:remove(startup_timeout_ms, Options))#{
                timeout_ms => Timeout, max_stdout => 8192, max_stderr => 8192},
            start(Executable, Arguments, Config, channel);
        _ -> {error, #{code => invalid_argument, outcome => not_started}}
    end;
start_channel(_, _, _) -> {error, #{code => invalid_argument, outcome => not_started}}.

-spec ack(t(), stdout | stderr, pos_integer()) -> ok | {error, map()}.
ack({transport, _, _, Owner}, _, _) when Owner =/= self() ->
    {error, #{code => not_owner}};
ack({transport, _, _, _} = Handle, Stream, Sequence)
  when (Stream =:= stdout orelse Stream =:= stderr),
                                 is_integer(Sequence, 1, 18446744073709551615) ->
    request(Handle, {ack, Stream, Sequence}, ?CLEANUP_MS);
ack(_, _, _) -> {error, #{code => invalid_argument}}.

-spec write(t(), binary()) -> {ok, non_neg_integer()} | {error, map()}.
write({transport, _, _, Owner}, _) when Owner =/= self() ->
    {error, #{code => not_owner}};
write({transport, _, _, _} = Handle, Bytes)
  when is_binary(Bytes), byte_size(Bytes) > 0,
                          byte_size(Bytes) =< 8192 ->
    request(Handle, {write, Bytes}, ?CLEANUP_MS);
write(_, _) -> {error, #{code => invalid_argument}}.

-spec ack_write(t(), non_neg_integer()) -> ok | {error, map()}.
ack_write({transport, _, _, Owner}, _) when Owner =/= self() ->
    {error, #{code => not_owner}};
ack_write({transport, _, _, _} = Handle, Id) when is_integer(Id, 0, 4294967295) ->
    request(Handle, {ack_write, Id}, ?CLEANUP_MS);
ack_write(_, _) -> {error, #{code => invalid_argument}}.

-spec close_stdin(t()) -> ok | {error, map()}.
close_stdin({transport, _, _, Owner}) when Owner =/= self() ->
    {error, #{code => not_owner}};
close_stdin({transport, _, _, _} = Handle) -> request(Handle, close_stdin, ?CLEANUP_MS);
close_stdin(_) -> {error, #{code => invalid_argument}}.

start(Executable, Arguments, Options, Mode) ->
    maybe
        {ok, Config} ?= prepare(Executable, Arguments, Options),
        {ok, _} ?= start_application(),
        Token = make_ref(),
        Child = #{id => Token, start => {?MODULE, start_link, [self(), Token, Config#{mode => Mode}]},
                  restart => temporary, shutdown => 1000},
        case supervisor:start_child(tmux_sup, Child) of
            {ok, Pid} when Mode =:= channel -> {ok, {transport, Pid, Token, self()}};
            {ok, Pid} -> {ok, {transport, Pid, Token}};
            {error, _} -> {error, #{code => transport_unavailable, outcome => not_started}}
        end
    end.

-spec await(t(), timeout()) -> result().
await(Handle, Timeout) -> request(Handle, await, Timeout).

-spec await_started(t(), timeout()) -> result().
await_started(Handle, Timeout) -> request(Handle, started, Timeout).

-spec cancel(t()) -> {ok, cancel_requested | already_finished} | {error, map()}.
cancel(Handle) -> request(Handle, cancel, ?CLEANUP_MS).

-spec close(t()) -> ok | {error, map()}.
close(Handle) ->
    request(Handle, close, ?CLEANUP_MS + 100).

-spec status(t()) -> result().
status(Handle) -> request(Handle, status, ?CLEANUP_MS).

-spec send_request(t(), await | retired) -> gen_server:request_id().
send_request({transport, Pid, Token}, Kind) when Kind =:= await; Kind =:= retired ->
    gen_server:send_request(Pid, {Token, Kind, make_ref()});
send_request({transport, Pid, Token, _}, Kind) ->
    send_request({transport, Pid, Token}, Kind).

-spec cancel_async(t()) -> ok.
cancel_async({transport, Pid, Token}) -> gen_server:cast(Pid, {Token, cancel});
cancel_async({transport, Pid, Token, _}) -> cancel_async({transport, Pid, Token}).

-spec close_async(t()) -> ok.
close_async({transport, Pid, Token}) -> gen_server:cast(Pid, {Token, close});
close_async({transport, Pid, Token, _}) -> close_async({transport, Pid, Token}).

request({transport, Pid, Token, _}, Kind, Timeout) ->
    request({transport, Pid, Token}, Kind, Timeout);
request({transport, Pid, Token}, Kind, Timeout)
  when is_pid(Pid), is_reference(Token),
       (Timeout =:= infinity orelse is_integer(Timeout, 0, 4294967295)) ->
    Tag = make_ref(),
    Request = gen_server:send_request(Pid, {Token, Kind, Tag}),
    case gen_server:receive_response(Request, Timeout) of
        {reply, Reply} -> Reply;
        timeout ->
            gen_server:cast(Pid, {Token, unwait, Tag}),
            {error, #{code => await_timeout}};
        {error, _} -> {error, #{code => operation_expired}}
    end;
request(_, _, _) -> {error, #{code => invalid_argument}}.

-spec start_link(pid(), reference(), map()) -> gen_server:start_ret().
start_link(Owner, Token, Config) ->
    gen_server:start_link(?MODULE, {Owner, Token, Config}, []).

-spec init({pid(), reference(), map()}) -> {ok, map(), {continue, launch}}.
init({Owner, Token, Config}) ->
    process_flag(trap_exit, true),
    Input = maps:get(stdin, Config),
    State = #{owner => Owner, owner_monitor => monitor(process, Owner), owner_alive => true,
              token => Token, config => Config, mode => maps:get(mode, Config),
              phase => queued, port => none,
              helper_pid => none, child_pid => none, sent => false,
              stdout => stream(maps:get(max_stdout, Config)),
              stderr => stream(maps:get(max_stderr, Config)),
              stdin => Input, input_size => byte_size(Input), input_offset => 0,
              input_delivered => 0, pending_write => none, write_id => 0,
              write_acknowledged => -1,
              input_closed => Input =:= <<>> andalso maps:get(mode, Config) =:= oneshot,
              cause => none, terminal => none,
              result => none, cleanup => pending, closing => false, waiters => #{},
              deadline_timer => none, cleanup_timer => none, retention_timer => none},
    {ok, State, {continue, launch}}.

-spec handle_continue(launch, map()) -> {noreply, map()}.
handle_continue(launch, State) ->
    #{config := Config, owner := Owner} = State,
    Remaining = maps:get(deadline, Config) - now_ms(),
    case {is_process_alive(Owner), Remaining > 0} of
        {false, _} -> {noreply, before_send(owner_down, State)};
        {_, false} -> {noreply, before_send(timeout, State)};
        {true, true} -> {noreply, launch(Remaining, State)}
    end.

-spec handle_call(term(), gen_server:from(), map()) ->
    {reply, term(), map()} | {noreply, map()} | {stop, normal, term(), map()}.
handle_call({Token, Kind, Tag}, From, #{token := Token} = State) ->
    case Kind of
        status -> {reply, {ok, public_status(State)}, State};
        cancel ->
            case maps:get(result, State) of
                none -> {reply, {ok, cancel_requested}, stop_child(#{code => cancelled}, State)};
                _ -> {reply, {ok, already_finished}, State}
            end;
        close -> close_request(Tag, From, State);
        await -> await_request(await, Tag, From, State);
        retired -> await_request(retired, Tag, From, State);
        started -> await_request(started, Tag, From, State);
        {ack, Stream, Seq} -> channel_call({ack, Stream, Seq}, From, State);
        {write, Bytes} -> channel_call({write, Bytes}, From, State);
        {ack_write, Id} -> channel_call({ack_write, Id}, From, State);
        close_stdin -> channel_call(close_stdin, From, State);
        _ -> {reply, {error, #{code => invalid_argument}}, State}
    end;
handle_call(_, _, State) -> {reply, {error, #{code => operation_expired}}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_cast({Token, unwait, Tag}, #{token := Token} = State) ->
    {noreply, remove_waiter(Tag, State)};
handle_cast({Token, cancel}, #{token := Token} = State) ->
    continue(stop_child(#{code => cancelled}, State));
handle_cast({Token, close}, #{token := Token} = State) ->
    continue(stop_child(#{code => cancelled}, State#{closing => true}));
handle_cast(_, State) -> {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({Port, {data, Bytes}}, #{port := Port, terminal := none} = State) ->
    Next = case tmux_transport_codec:decode(Bytes) of
        {ok, Event} -> event(Event, State);
        {error, Error} -> stop_child(Error, State)
    end,
    continue(Next);
handle_info({Port, {data, _}}, #{port := Port} = State) ->
    continue(set_cause(#{code => invalid_helper_frame}, State));
handle_info({Port, {exit_status, Status}}, #{port := Port} = State) ->
    continue(helper_exit(Status, State#{port => none}));
handle_info({'EXIT', Port, normal}, #{port := Port} = State) ->
    {noreply, State};
handle_info({'EXIT', Port, _Reason}, #{port := Port} = State) when is_port(Port) ->
    continue(incomplete(#{code => helper_exit}, State#{port => none}));
handle_info({'DOWN', Monitor, process, _, _}, #{owner_monitor := Monitor} = State) ->
    continue(stop_child(#{code => owner_down}, State#{owner_alive => false}));
handle_info({'DOWN', Monitor, process, _, _}, State) ->
    Waiters = maps:filter(fun(_, {_, _, Ref}) -> Ref =/= Monitor end,
                         maps:get(waiters, State)),
    {noreply, State#{waiters => Waiters}};
handle_info({timeout, Timer, deadline}, #{deadline_timer := Timer, terminal := none} = State) ->
    continue(stop_child(#{code => timeout}, State#{deadline_timer => none}));
handle_info({timeout, Timer, cleanup}, #{cleanup_timer := Timer, cleanup := pending} = State) ->
    continue(incomplete(#{code => cleanup_incomplete}, State#{cleanup_timer => none}));
handle_info({timeout, Timer, expire}, #{retention_timer := Timer, cleanup := complete} = State) ->
    {stop, normal, State};
handle_info(_, State) -> {noreply, State}.

-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun
        (state, State) -> public_status(State);
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (_, Value) -> Value
    end, maps:without([log], Status)).

-spec terminate(term(), map()) -> ok.
terminate(_, #{port := none}) -> ok;
terminate(_, #{port := Port, cleanup := complete}) ->
    try port_close(Port) catch error:badarg -> false end,
    ok;
terminate(_, #{port := Port, terminal := Terminal}) ->
    Frame = case Terminal of none -> <<$Q>>; _ -> <<$T>> end,
    _ = send_frame(Port, Frame),
    shutdown_drain(Port, now_ms() + ?CLEANUP_MS).

start_application() ->
    case application:ensure_all_started(libtmux_erlang) of
        {ok, Apps} -> {ok, Apps};
        {error, _} -> {error, #{code => application_unavailable, outcome => not_started}}
    end.

prepare(Executable, Arguments, Options) when is_map(Options) ->
    Started = now_ms(),
    Allowed = [timeout_ms, max_stdout, max_stderr, stdin, cwd, env, inherit_env],
    Defaults = #{timeout_ms => 2500, max_stdout => 1048576, max_stderr => 65536,
                 stdin => <<>>, env => #{}, inherit_env => true},
    Config = maps:merge(Defaults, Options),
    #{timeout_ms := Timeout, max_stdout := Out, max_stderr := Err,
      stdin := Input, env := Env, inherit_env := Inherit} = Config,
    Valid = maps:without(Allowed, Options) =:= #{} andalso
            is_integer(Timeout, 1, 600000) andalso is_integer(Out, 0, 1048576) andalso
            is_integer(Err, 0, 65536) andalso is_binary(Input) andalso
            byte_size(Input) =< 1048576 andalso is_map(Env) andalso is_boolean(Inherit),
    case Valid of
        false -> {error, #{code => invalid_argument, outcome => not_started}};
        true ->
            maybe
                {ok, Cwd} ?= cwd(Options),
                {ok, Environment} ?= environment(Env, Inherit),
                {ok, Open} ?= tmux_transport_codec:open(#{executable => Executable,
                    args => Arguments, cwd => Cwd, env => Environment,
                    stdin_open => Input =/= <<>>, timeout_ms => Timeout}),
                {ok, #{open => Open, deadline => Started + Timeout, stdin => Input,
                       max_stdout => Out, max_stderr => Err}}
            end
    end;
prepare(_, _, _) -> {error, #{code => invalid_argument, outcome => not_started}}.

cwd(#{cwd := <<$/, _/binary>> = Cwd}) -> {ok, Cwd};
cwd(#{cwd := _}) -> {error, #{code => invalid_argument}};
cwd(_) ->
    case file:get_cwd() of
        {ok, Cwd} -> {ok, unicode:characters_to_binary(Cwd)};
        {error, _} -> {error, #{code => invalid_cwd}}
    end.

environment(Overrides, Inherit) ->
    Valid = map_size(Overrides) =< 256 andalso maps:fold(fun(Key, Value, Acc) ->
        Acc andalso is_binary(Key) andalso byte_size(Key) > 0 andalso
        byte_size(Key) =< 32768 andalso binary:match(Key, [<<0>>, <<"=">>]) =:= nomatch andalso
        (Value =:= false orelse (is_binary(Value) andalso byte_size(Value) =< 32768))
    end, true, Overrides),
    case Valid of
        false -> {error, #{code => invalid_environment}};
        true ->
            Base = case Inherit of
                false -> #{};
                true -> maps:from_list([begin
                    [Key, Value] = binary:split(unicode:characters_to_binary(Entry), <<"=">>),
                    {Key, Value}
                end || Entry <- os:getenv()])
            end,
            Merged = maps:without([<<"TMUX">>, <<"TMUX_PANE">>], maps:merge(Base, Overrides)),
            EncodedSize = maps:fold(fun
                (_, false, Sum) -> Sum;
                (Key, Value, Sum) -> Sum + byte_size(Key) + byte_size(Value) + 3
            end, 0, Merged),
            case EncodedSize =< 32768 of
                true -> {ok, [<<Key/binary, $=, Value/binary>>
                             || {Key, Value} <- lists:sort(maps:to_list(Merged)), Value =/= false]};
                false -> {error, #{code => command_limit}}
            end
    end.

stream(Limit) -> #{limit => Limit, size => 0, chunks => [], buffer => <<>>,
                   sequence => 0, acknowledged => 0, credit => 0, eof => false}.

launch(Remaining, #{config := Config} = State) ->
    Helper = filename:join(code:priv_dir(libtmux_erlang), "tmux_owned_io"),
    try open_port({spawn_executable, Helper}, [binary, {packet, 2}, exit_status,
            use_stdio, {busy_limits_port, {32768, 65536}},
            {busy_limits_msgq, {32768, 65536}}]) of
        Port ->
            {os_pid, Pid} = erlang:port_info(Port, os_pid),
            <<$O, 3, Input, _:32, Tail/binary>> = maps:get(open, Config),
            Timer = erlang:start_timer(Remaining, self(), deadline),
            Next = State#{port => Port, helper_pid => Pid, config => #{},
                          phase => starting, deadline_timer => Timer},
            {OpenInput, Lifetime} = case maps:get(mode, State) of
                channel -> {1, 0};
                oneshot -> {Input, Remaining}
            end,
            case send_frame(Port, <<$O, 3, OpenInput, Lifetime:32, Tail/binary>>) of
                true -> Next#{sent => true};
                false -> stop_child(#{code => transport_busy}, Next)
            end
    catch error:_ -> before_send(helper_unavailable, State)
    end.

before_send(Code, State) ->
    publish({error, #{code => Code, outcome => not_started, cleanup => complete,
                      stdout => <<>>, stderr => <<>>, stdin_delivered => 0}},
            State#{cleanup => complete, phase => retired, config => #{}, stdin => <<>>}).

event({started, Pid}, #{child_pid := none, phase := Phase} = State) ->
    Ready = case maps:get(mode, State) of
        channel ->
            cancel_timer(maps:get(deadline_timer, State)),
            State#{deadline_timer => none};
        oneshot -> State
    end,
    Next = notify_started(Ready#{child_pid => Pid}),
    case Phase of
        starting -> input_next(grant(stderr, grant(stdout, Next#{phase => running})));
        _ -> Next
    end;
event({data, Stream, Bytes}, #{mode := channel} = State) ->
    Slot = maps:get(Stream, State),
    #{credit := Credit, size := Size, sequence := Seq, acknowledged := Acked} = Slot,
    case byte_size(Bytes) =< Credit andalso Credit > 0 andalso Seq =:= Acked of
        false -> stop_child(#{code => invalid_helper_frame}, State);
        true ->
            channel_event({data, Stream, Seq + 1, Bytes}, State),
            State#{Stream => Slot#{credit => 0, sequence => Seq + 1,
                                  size => Size + byte_size(Bytes)}}
    end;
event({data, Stream, Bytes}, State) ->
    Slot = maps:get(Stream, State),
    #{credit := Credit, size := Size, limit := Limit} = Slot,
    Received = byte_size(Bytes),
    case Received =< Credit andalso Credit > 0 of
        false -> stop_child(#{code => invalid_helper_frame}, State);
        true when Size + Received > Limit ->
            stop_child(#{code => output_limit, stream => Stream},
                       State#{Stream => Slot#{credit => 0}});
        true ->
            grant(Stream, State#{Stream => append_output(Bytes, Slot#{credit => 0,
                                                                      size => Size + Received})})
    end;
event({eof, Stream}, State) ->
    Slot = maps:get(Stream, State),
    case maps:get(credit, Slot) > 0 andalso not maps:get(eof, Slot) of
        true ->
            case maps:get(mode, State) of
                channel -> channel_event({eof, Stream}, State);
                oneshot -> ok
            end,
            State#{Stream => Slot#{credit => 0, eof => true}};
        false -> stop_child(#{code => invalid_helper_frame}, State)
    end;
event({write_ack, Id, Delivered, Failed}, #{pending_write := {Id, Size}} = State)
  when Delivered =< Size ->
    Next = State#{pending_write => none,
                  input_delivered => maps:get(input_delivered, State) + Delivered},
    case Failed orelse Delivered =/= Size of
        true -> stop_child(#{code => stdin_write_failed}, Next);
        false ->
            case maps:get(mode, State) of
                channel ->
                    channel_event({write_ack, Id, Delivered}, Next),
                    Next#{pending_write => {ack, Id}};
                oneshot -> input_next(Next)
            end
    end;
event(stdin_closed, #{input_closed := sent} = State) -> State#{input_closed => true};
event({retired, _, _} = Terminal, State) -> terminal(Terminal, State);
event({failed, 4, Errno}, State) -> incomplete(#{code => cleanup_incomplete, errno => Errno}, State);
event({failed, _, _} = Terminal, State) -> terminal(Terminal, State);
event(_, State) -> stop_child(#{code => invalid_helper_frame}, State).

grant(Stream, #{phase := running, port := Port} = State) ->
    #{limit := Limit, size := Size, credit := 0, eof := false} = Slot = maps:get(Stream, State),
    %% One byte beyond the configured limit distinguishes exact EOF from overflow.
    Credit = case maps:get(mode, State) of
        channel -> 8192;
        oneshot -> min(8192, max(1, Limit - Size))
    end,
    case send_frame(Port, tmux_transport_codec:credit(Stream, Credit)) of
        true -> State#{Stream => Slot#{credit => Credit}};
        false -> stop_child(#{code => transport_busy}, State)
    end;
grant(_, State) -> State.

input_next(#{mode := channel} = State) -> State;
input_next(#{phase := running, pending_write := none, input_closed := false,
             stdin := Input, input_offset := Offset, write_id := Id, port := Port} = State) ->
    case byte_size(Input) - Offset of
        0 ->
            case send_frame(Port, <<$C>>) of
                true -> State#{input_closed => sent, stdin => <<>>};
                false -> stop_child(#{code => transport_busy}, State)
            end;
        Left ->
            Size = min(8192, Left),
            Bytes = binary:part(Input, Offset, Size),
            case send_frame(Port, tmux_transport_codec:write(Id, Bytes)) of
                true -> State#{input_offset => Offset + Size, pending_write => {Id, Size},
                               write_id => Id + 1};
                false -> stop_child(#{code => transport_busy}, State)
            end
    end;
input_next(State) -> State.

channel_event(Event, #{owner := Owner, token := Token}) ->
    Owner ! {tmux_transport, {transport, self(), Token, Owner}, Event},
    ok.

channel_call(_, {Caller, _}, #{owner := Owner} = State) when Caller =/= Owner ->
    {reply, {error, #{code => not_owner}}, State};
channel_call(_, _, #{mode := oneshot} = State) ->
    {reply, {error, #{code => invalid_argument}}, State};
channel_call(_, _, #{phase := Phase} = State) when Phase =/= running ->
    {reply, {error, #{code => channel_closed}}, State};
channel_call({ack, Stream, Seq}, _, State) ->
    #{sequence := Last, acknowledged := Acked} = Slot = maps:get(Stream, State),
    case Seq of
        _ when Seq =< Acked -> {reply, ok, State};
        Last -> {reply, ok, grant(Stream, State#{Stream => Slot#{acknowledged => Seq}})};
        _ -> {reply, {error, #{code => invalid_ack}}, State}
    end;
channel_call({ack_write, Id}, _, #{pending_write := {ack, Id}} = State) ->
    {reply, ok, State#{pending_write => none, write_acknowledged => Id}};
channel_call({ack_write, Id}, _, #{write_acknowledged := Acked} = State) when Id =< Acked ->
    {reply, ok, State};
channel_call({ack_write, _}, _, State) ->
    {reply, {error, #{code => invalid_ack}}, State};
channel_call({write, Bytes}, _, #{pending_write := none, input_closed := false,
                                 port := Port, write_id := Id} = State)
  when Id =< 4294967295 ->
    case send_frame(Port, tmux_transport_codec:write(Id, Bytes)) of
        true -> {reply, {ok, Id}, State#{pending_write => {Id, byte_size(Bytes)},
                                        write_id => Id + 1}};
        false -> {reply, {error, #{code => transport_busy}},
                  stop_child(#{code => transport_busy}, State)}
    end;
channel_call({write, _}, _, #{write_id := Id} = State) when Id > 4294967295 ->
    {reply, {error, #{code => write_limit}}, stop_child(#{code => write_limit}, State)};
channel_call(close_stdin, _, #{pending_write := none, input_closed := false,
                              port := Port} = State) ->
    case send_frame(Port, <<$C>>) of
        true -> {reply, ok, State#{input_closed => sent}};
        false -> {reply, {error, #{code => transport_busy}},
                  stop_child(#{code => transport_busy}, State)}
    end;
channel_call(close_stdin, _, #{input_closed := Closed} = State) when Closed =/= false ->
    {reply, ok, State};
channel_call({write, _}, _, #{input_closed := Closed} = State) when Closed =/= false ->
    {reply, {error, #{code => stdin_closed}}, State};
channel_call(_, _, State) -> {reply, {error, #{code => busy}}, State}.

send_frame(Port, Frame) ->
    try erlang:port_command(Port, Frame, [nosuspend])
    catch error:badarg -> false
    end.

stop_child(Cause, #{cleanup := complete} = State) ->
    _ = Cause,
    State;
stop_child(Cause, #{terminal := Terminal} = State) when Terminal =/= none ->
    _ = Cause,
    State;
stop_child(Cause, #{phase := Phase, port := Port} = State) ->
    case Phase =/= stopping andalso Phase =/= reaping andalso Port =/= none of
        true -> _ = send_frame(Port, <<$Q>>);
        false -> ok
    end,
    cleanup_timer(set_cause(Cause, State#{phase => stopping})).

set_cause(Cause, #{cause := none} = State) -> State#{cause => Cause};
set_cause(_, State) -> State.

cleanup_timer(#{cleanup_timer := none} = State) ->
    State#{cleanup_timer => erlang:start_timer(?CLEANUP_MS, self(), cleanup)};
cleanup_timer(State) -> State.

terminal(Terminal, #{port := Port} = State) ->
    cancel_timer(maps:get(deadline_timer, State)),
    _ = send_frame(Port, <<$T>>),
    cleanup_timer(State#{terminal => Terminal, phase => retiring, stdin => <<>>}).

helper_exit(Status, #{terminal := none} = State) ->
    incomplete(#{code => helper_exit, helper_status => Status}, State);
helper_exit(Status, State) ->
    cancel_timer(maps:get(deadline_timer, State)),
    cancel_timer(maps:get(cleanup_timer, State)),
    Next = State#{cleanup => complete, phase => retired, stdin => <<>>},
    Result = case Status of
        0 -> result(Next);
        _ -> {error, maps:merge(details(Next), #{code => helper_exit, helper_status => Status,
                                                outcome => unknown})}
    end,
    publish(Result, Next).

result(#{terminal := Terminal, cause := Cause} = State) ->
    Details = details(State),
    Error = case {Terminal, Cause} of
        {{failed, 2, Errno}, _} -> #{code => exec_failed, errno => Errno, outcome => not_started};
        {_, Existing} when is_map(Existing) -> Existing#{outcome => outcome(State)};
        {{failed, Kind, Errno}, _} -> #{code => helper_failure, kind => Kind, errno => Errno,
                                      outcome => unknown};
        {{retired, 0, _}, _} when map_get(mode, State) =:= channel -> none;
        {{retired, 0, _}, _} ->
            case maps:get(input_size, State) =:= maps:get(input_delivered, State) of
                true -> none;
                false -> #{code => stdin_write_failed, outcome => unknown}
            end;
        {{retired, 1, _}, _} -> #{code => cancelled, outcome => unknown};
        {{retired, 2, _}, _} -> #{code => timeout, outcome => unknown};
        _ -> #{code => helper_failure, outcome => unknown}
    end,
    case Error of
        none -> {retired, 0, Status} = Terminal, {ok, Details#{exit_status => Status}};
        _ -> {error, maps:merge(Details, Error)}
    end.

outcome(#{sent := false}) -> not_started;
outcome(_) -> unknown.

details(#{mode := channel} = State) ->
    #{stdout_bytes => maps:get(size, maps:get(stdout, State)),
      stderr_bytes => maps:get(size, maps:get(stderr, State)),
      stdin_delivered => maps:get(input_delivered, State), cleanup => maps:get(cleanup, State)};
details(State) ->
    #{stdout => output(stdout, State), stderr => output(stderr, State),
      stdin_delivered => maps:get(input_delivered, State), cleanup => maps:get(cleanup, State)}.

output(Stream, State) ->
    #{chunks := Chunks, buffer := Buffer} = maps:get(Stream, State),
    iolist_to_binary(lists:reverse([Buffer | Chunks])).

append_output(Bytes, #{chunks := Chunks, buffer := Buffer} = Slot) ->
    case <<Buffer/binary, Bytes/binary>> of
        <<Chunk:8192/binary, Tail/binary>> ->
            Slot#{chunks => [binary:copy(Chunk) | Chunks], buffer => binary:copy(Tail)};
        Tail -> Slot#{buffer => Tail}
    end.

incomplete(Cause, State) ->
    Next = set_cause(Cause, State#{cleanup => incomplete, phase => reaping, stdin => <<>>}),
    Error = maps:merge(details(Next), #{code => cleanup_incomplete, outcome => outcome(Next),
                                      cause => maps:get(cause, Next)}),
    publish({error, Error}, Next).

publish(Result, State) ->
    Next = notify_result(State#{result => Result}),
    case maps:get(cleanup, Next) =:= complete andalso maps:get(retention_timer, Next) =:= none of
        true -> Next#{retention_timer => erlang:start_timer(60000, self(), expire),
                      stdout => release_output(maps:get(stdout, Next)),
                      stderr => release_output(maps:get(stderr, Next))};
        false -> Next
    end.

release_output(Slot) -> Slot#{chunks => [], buffer => <<>>}.

await_request(started, _Tag, _From, #{child_pid := Pid} = State) when is_integer(Pid) ->
    {reply, {ok, public_status(State)}, State};
await_request(retired, Tag, From, #{cleanup := Cleanup} = State) when Cleanup =/= complete ->
    add_waiter(retired, Tag, From, State);
await_request(_, _Tag, _From, #{result := Result} = State) when Result =/= none ->
    {reply, Result, State};
await_request(Kind, Tag, From, State) -> add_waiter(Kind, Tag, From, State).

close_request(_Tag, _From, #{cleanup := complete} = State) ->
    {stop, normal, ok, State};
close_request(_Tag, _From, #{cleanup := incomplete, result := Result} = State) ->
    {reply, Result, State#{closing => true}};
close_request(Tag, From, State) ->
    add_waiter(close, Tag, From, stop_child(#{code => cancelled}, State#{closing => true})).

add_waiter(Kind, Tag, {Pid, _} = From, #{waiters := Waiters} = State)
  when map_size(Waiters) < ?WAITERS ->
    Monitor = monitor(process, Pid),
    {noreply, State#{waiters => Waiters#{Tag => {Kind, From, Monitor}}}};
add_waiter(_, _, _, State) -> {reply, {error, #{code => too_many_waiters}}, State}.

remove_waiter(Tag, #{waiters := Waiters} = State) ->
    case maps:take(Tag, Waiters) of
        {{_, _, Monitor}, Rest} ->
            demonitor(Monitor, [flush]), State#{waiters => Rest};
        error -> State
    end.

notify_started(State) ->
    maps:fold(fun(Tag, {Kind, From, _}, Acc) ->
        case Kind of
            started -> gen_server:reply(From, {ok, public_status(Acc)}), remove_waiter(Tag, Acc);
            _ -> Acc
        end
    end, State, maps:get(waiters, State)).

notify_result(State) ->
    maps:fold(fun(Tag, {Kind, From, _}, Acc) ->
        case {Kind, maps:get(cleanup, Acc)} of
            {retired, Cleanup} when Cleanup =/= complete -> Acc;
            {close, complete} ->
                gen_server:reply(From, ok), remove_waiter(Tag, Acc);
            _ ->
                gen_server:reply(From, maps:get(result, Acc)), remove_waiter(Tag, Acc)
        end
    end, State, maps:get(waiters, State)).

public_status(State) ->
    (maps:with([phase, helper_pid, child_pid, cleanup, cause], State))#{
        worker => self(), waiters => map_size(maps:get(waiters, State)),
        stdout_bytes => maps:get(size, maps:get(stdout, State)),
        stderr_bytes => maps:get(size, maps:get(stderr, State))}.

continue(#{cleanup := complete, owner_alive := false} = State) -> {stop, normal, State};
continue(#{cleanup := complete, closing := true} = State) -> {stop, normal, State};
continue(State) -> {noreply, State}.

cancel_timer(none) -> ok;
cancel_timer(Timer) -> _ = erlang:cancel_timer(Timer), ok.

shutdown_drain(Port, Deadline) ->
    Remaining = max(0, Deadline - now_ms()),
    receive
        {Port, {exit_status, _}} -> ok;
        {Port, {data, Bytes}} ->
            case tmux_transport_codec:decode(Bytes) of
                {ok, {retired, _, _}} -> _ = send_frame(Port, <<$T>>);
                {ok, {failed, Kind, _}} when Kind < 4 -> _ = send_frame(Port, <<$T>>);
                _ -> ok
            end,
            shutdown_drain(Port, Deadline);
        {'EXIT', Port, _} -> ok
    after Remaining -> ok
    end.

now_ms() -> erlang:monotonic_time(millisecond).
