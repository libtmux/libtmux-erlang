-module(tmux_program_owner).
-moduledoc false.
-behaviour(gen_server).
-export([start/2, prepare/4, request/3, send_text/2, start_link/7, init/1, handle_continue/2, handle_call/3,
         handle_cast/2, handle_info/2, format_status/1]).
-export_type([t/0]).
-opaque t() :: {program, pid(), reference(), tmux_admission:t()}.
-type response() :: {ok, map()} | {error, map()}.
-type callback() :: fun(({pid(), reference()}) -> response()).
-define(INPUT_BYTES, 2000).
-define(REQUEST_MS, 900).
-define(RESOURCES, [version_probe, ownership, terminal_holder]).

-spec start(integer(), callback()) -> {ok, t()} | {error, map()}.
start(Deadline, Function) ->
    StartBy = min(Deadline, now_ms() + ?REQUEST_MS),
    maybe
        {ok, Pool} ?= tmux_registry:program_pool(),
        {ok, Lease} ?= tmux_admission:reserve(Pool, self(), 1, StartBy),
        await_preparation(Pool, Lease, StartBy, Deadline, Function)
    else
        {error, #{code := busy}} -> {error, #{code => program_busy, outcome => not_started}};
        {error, #{code := admission_expired}} -> {error, #{code => deadline, outcome => not_started}};
        {error, Detail} -> {error, Detail#{outcome => not_started}}
    end.

await_preparation(Pool, Lease, StartBy, Deadline, Function) ->
    Reply = erlang:alias([reply]),
    try tmux_admission:deliver(Pool, Lease, 1, {program, Reply, StartBy, Deadline, Function}) of
        ok ->
            receive
                {Reply, {ok, {program, Pid, Token, _} = Program}} ->
                    gen_server:cast(Pid, {Token, activate}),
                    {ok, Program};
                {Reply, {error, _} = Error} -> Error
            after max(0, StartBy - now_ms()) ->
                {error, #{code => deadline, outcome => not_started}}
            end;
        {error, Detail} -> {error, Detail#{outcome => not_started}}
    after
        _ = erlang:unalias(Reply),
        discard_reply(Reply)
    end.

-spec prepare(pid(), integer(), integer(), callback()) -> {ok, pid(), t()} | {error, map()}.
prepare(Owner, StartBy, Deadline, Function) ->
    try start_slot(tmux_registry:program_slots(), {Owner, StartBy, Deadline, Function}) of
        {ok, _, _} = Result -> Result;
        {error, Code} when Code =:= program_busy; Code =:= deadline ->
            {error, #{code => Code, outcome => not_started}};
        {error, _} -> {error, #{code => program_owner_unavailable, outcome => not_started}}
    catch
        exit:_ -> {error, #{code => program_owner_unavailable, outcome => not_started}}
    end.

start_slot([], _) -> {error, program_busy};
start_slot([Slot | Rest], {_, StartBy, _, _} = Request) ->
    case now_ms() < StartBy of
        true ->
            case prepare_slot(Slot, Request) of
                {error, slot_occupied} -> start_slot(Rest, Request);
                Result -> Result
            end;
        false -> {error, deadline}
    end.

prepare_slot(Slot, {Owner, StartBy, Deadline, Function}) ->
    Token = make_ref(),
    Ready = erlang:alias([reply]),
    Args = [Owner, Token, StartBy, Deadline, Function, Ready, Slot],
    Child = #{id => {?MODULE, Slot}, start => {?MODULE, start_link, Args},
              restart => temporary, shutdown => 1000},
    try supervisor:start_child(tmux_sup, Child) of
        {ok, Pid} -> await_slot(Pid, Token, Ready, Slot, StartBy);
        {error, {already_started, _}} -> {error, slot_occupied};
        {error, already_present} -> {error, slot_occupied};
        Error -> Error
    after
        _ = erlang:unalias(Ready),
        discard_reply(Ready)
    end.

await_slot(Pid, Token, Ready, Slot, StartBy) ->
    %% The previous controller sends its start requests and exit signal to
    %% the same supervisor. Check the resource IDs after claiming this slot.
    case resources_retired(Slot) of
        false ->
            gen_server:cast(Pid, {Token, discard}),
            {error, slot_occupied};
        true ->
            receive
                {Ready, Admission} ->
                    case now_ms() < StartBy of
                        true -> {ok, Pid, {program, Pid, Token, Admission}};
                        false -> {error, deadline}
                    end
            after max(0, StartBy - now_ms()) -> {error, deadline}
            end
    end.

resources_retired(Slot) ->
    lists:all(fun(Resource) ->
        supervisor:get_childspec(tmux_sup, resource_id(Slot, Resource)) =:= {error, not_found}
    end, ?RESOURCES).

resource_id(Slot, Resource) -> {?MODULE, Slot, Resource}.

-spec request(t(), started | await | stop | release, timeout()) -> term().
request({program, Pid, Token, _}, Kind, Timeout)
  when is_pid(Pid), is_reference(Token),
       (Timeout =:= infinity orelse is_integer(Timeout, 0, 4294967295)) ->
    Tag = make_ref(),
    Request = gen_server:send_request(Pid, {Token, Kind, Tag}),
    case gen_server:receive_response(Request, Timeout) of
        {reply, Reply} -> Reply;
        timeout ->
            gen_server:cast(Pid, {Token, unwait, Tag}),
            {error, #{code => await_timeout}};
        {error, _} -> {error, #{code => program_expired}}
    end;
request(_, _, _) -> {error, #{code => invalid_program}}.

-spec send_text(t(), binary()) -> {ok, #{bytes := non_neg_integer()}} | {error, map()}.
send_text(_, Text) when not is_binary(Text) ->
    {error, #{code => invalid_text, outcome => not_started}};
send_text(_, Text) when byte_size(Text) > ?INPUT_BYTES ->
    {error, #{code => command_limit, outcome => not_started}};
send_text({program, Pid, _, Admission}, Text) when is_pid(Pid), node(Pid) =:= node() ->
    Deadline = now_ms() + ?REQUEST_MS,
    case tmux_admission:reserve(Admission, self(), byte_size(Text), Deadline) of
        {ok, Lease} -> input_request(Pid, Admission, Lease, Text, Deadline);
        {error, #{code := busy}} -> {error, #{code => program_input_busy, outcome => not_started}};
        {error, #{code := server_closed}} ->
            Code = case is_process_alive(Pid) of true -> program_not_running; false -> program_expired end,
            {error, #{code => Code, outcome => not_started}};
        {error, Detail} -> {error, Detail#{outcome => not_started}}
    end;
send_text(_, _) -> {error, #{code => invalid_program, outcome => not_started}}.

input_request(Pid, Admission, Lease, Text, Deadline) ->
    Reply = monitor(process, Pid, [{alias, demonitor}]),
    try tmux_admission:deliver(Admission, Lease, byte_size(Text), {input, binary:copy(Text), Reply}) of
        ok ->
            receive
                {Reply, Result} -> Result;
                {'DOWN', Reply, process, Pid, _} -> input_unknown()
            after max(0, Deadline - now_ms()) -> input_unknown()
            end;
        {error, Detail} -> {error, Detail#{outcome => not_started}}
    after
        demonitor(Reply, [flush]),
        discard_reply(Reply)
    end.

discard_reply(Alias) ->
    receive {Alias, _} -> ok
    after 0 -> ok
    end.

input_unknown() -> {error, #{code => input_unconfirmed, outcome => unknown}}.

-spec start_link(pid(), reference(), integer(), integer(), callback(), reference(), pos_integer()) ->
    gen_server:start_ret().
start_link(Owner, Token, StartBy, Deadline, Function, Ready, Slot) ->
    gen_server:start_link(?MODULE, {Owner, Token, StartBy, Deadline, Function, Ready, Slot}, []).

-spec init({pid(), reference(), integer(), integer(), callback(), reference(), pos_integer()}) ->
    {ok, map()} | {stop, deadline}.
init({Owner, Token, StartBy, Deadline, Function, Ready, Slot}) ->
    case StartBy - now_ms() of
        Time when Time > 0 -> initialize(Owner, Token, {StartBy, Deadline, Function}, Ready, Slot);
        _ -> {stop, deadline}
    end.

initialize(Owner, Token, {StartBy, Deadline, Function}, Ready, Slot) ->
    process_flag(trap_exit, true),
    Activation = erlang:start_timer(StartBy, self(), activate, [{abs, true}]),
    Admission = tmux_admission:new(Token, 1, ?INPUT_BYTES),
    Ready ! {Ready, Admission},
    {ok, #{owner => Owner, owner_monitor => monitor(process, Owner), owner_alive => true, slot => Slot,
           token => Token, activation => {Activation, StartBy, Deadline, Function}, timer => none,
           expiry => none, waiters => #{}, input_admission => Admission, input_sweep => none,
           version_probe => none, ownership => none, terminal_holder => none, terminal_ready => false,
           stopping => none, started => false, target => none, input => none,
           primary => none, result => none, cleanup => none, cleanup_timer => none, unconfirmed => [],
           requests => gen_server:reqids_new()}}.

-spec handle_continue(callback(), map()) -> {noreply, map()}.
handle_continue(Function, #{token := Token} = State) ->
    Controller = self(),
    {Worker, Monitor} = spawn_opt(fun() ->
        Result = Function({Controller, Token}),
        Controller ! {Token, self(), result, Result}
    end, [link, monitor]),
    {noreply, State#{worker => Worker, worker_monitor => Monitor}}.

-spec handle_call(term(), gen_server:from(), map()) ->
    {reply, term(), map()} | {noreply, map()} | {stop, normal, term(), map()}.
handle_call({Token, _, _}, _, #{token := Token, result := expired} = State) ->
    {reply, {error, #{code => program_expired}}, State};
handle_call({Token, stop, _}, _, #{token := Token, result := none} = State) ->
    {reply, {ok, stop_requested}, request_stop(program_stopped, State)};
handle_call({Token, stop, _}, _, #{token := Token} = State) ->
    {reply, {ok, already_completed}, State};
handle_call({Token, release, _}, _, #{token := Token, result := none} = State) ->
    {reply, {error, #{code => program_active}}, State};
handle_call({Token, release, _}, _, #{token := Token, unconfirmed := []} = State) ->
    {stop, normal, ok, State};
handle_call({Token, release, _}, _, #{token := Token} = State) ->
    {reply, ok, forget_result(State)};
handle_call({Token, Kind, Tag}, From, #{token := Token, waiters := Waiters} = State)
  when Kind =:= started; Kind =:= await ->
    case answer(Kind, State) of
        none when map_size(Waiters) < 16 ->
            {Pid, _} = From,
            {noreply, State#{waiters => Waiters#{Tag => {Kind, From, monitor(process, Pid)}}}};
        none -> {reply, {error, #{code => too_many_waiters}}, State};
        Reply -> {reply, Reply, State}
    end;
handle_call(_, _, State) -> {reply, {error, #{code => invalid_program}}, State}.

-spec handle_cast(term(), map()) ->
    {noreply, map()} | {noreply, map(), {continue, callback()}} | {stop, normal, map()}.
handle_cast({Token, activate},
            #{token := Token, activation := {Activation, StartBy, Deadline, Function}} = State) ->
    case now_ms() < StartBy of
        true ->
            _ = erlang:cancel_timer(Activation),
            Timer = erlang:start_timer(Deadline, self(), deadline, [{abs, true}]),
            {noreply, sweep_input(State#{activation => none, timer => Timer}), {continue, Function}};
        false -> {stop, normal, State}
    end;
handle_cast({Token, discard}, #{token := Token, activation := Activation} = State) when Activation =/= none ->
    {stop, normal, State};
handle_cast({Token, unwait, Tag}, #{token := Token} = State) ->
    {noreply, remove_waiter(Tag, State)};
handle_cast(_, State) -> {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({tmux_admission, Token, Lease, Caller, {input, Text, Reply}},
            #{token := Token, input_admission := Admission} = State)
  when is_binary(Text), is_reference(Reply) ->
    case tmux_admission:claim(Admission, Lease, Caller, byte_size(Text)) of
        ok -> {noreply, submit_input(Lease, Text, Reply, State)};
        {error, _} ->
            _ = tmux_admission:expire(Admission),
            Reply ! {Reply, {error, #{code => admission_expired, outcome => not_started}}},
            {noreply, State}
    end;
handle_info({Token, Worker, permit, Stage, Detail}, #{token := Token, worker := Worker} = State) ->
    case permit(Stage, Detail, State) of
        {pending, Next} -> {noreply, Next};
        {Decision, Next} ->
            Worker ! {Token, Stage, Decision},
            {noreply, Next}
    end;
handle_info({Token, Worker, started, Target}, #{token := Token, worker := Worker,
            stopping := none, primary := none} = State) ->
    {noreply, reply_waiters(State#{started => true, target => Target})};
handle_info({tmux_transport, Holder, {data, stdout, Sequence, <<"R">>}},
            #{terminal_holder := Holder, stopping := none, terminal_ready := false} = State) ->
    Request = tmux_transport:send_request(Holder, {ack, stdout, Sequence}),
    {noreply, track(Request, terminal_ack, State)};
handle_info({tmux_transport, Holder, _}, #{terminal_holder := Holder, terminal_ready := false} = State) ->
    {noreply, terminal_notice({error, #{code => program_terminal_unavailable}}, State)};
handle_info({Token, Input, input_result, Result}, #{token := Token, input := {Input, _, _, _}} = State) ->
    advance(input_done(Result, State));
handle_info({Token, Worker, result, Result},
            #{token := Token, worker := Worker, primary := none, result := none} = State) ->
    primary_done(Result, State);
handle_info({'DOWN', Monitor, process, _, _},
            #{owner_monitor := Monitor, activation := Activation} = State) when Activation =/= none ->
    {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, #{owner_monitor := Monitor, result := none} = State) ->
    advance(request_stop(program_owner_exited, State#{owner_alive => false}));
handle_info({'DOWN', Monitor, process, _, _}, #{owner_monitor := Monitor} = State) ->
    advance(forget_result(State));
handle_info({'DOWN', Monitor, process, _, _},
            #{worker_monitor := Monitor, primary := none, result := none} = State) ->
    primary_done({error, #{code => program_worker_failed}}, State);
handle_info({'DOWN', Monitor, process, _, _}, #{input := {_, Monitor, _, _}} = State) ->
    advance(input_done(input_unknown(), State));
handle_info({timeout, Timer, activate}, #{activation := {Timer, _, _, _}} = State) -> {stop, normal, State};
handle_info({timeout, Timer, input_sweep}, #{input_sweep := Timer} = State) ->
    {noreply, sweep_input(State)};
handle_info({timeout, Timer, deadline}, #{timer := Timer, result := none} = State) ->
    advance(request_stop(deadline, State#{timer => none}));
handle_info({timeout, Timer, cleanup}, #{cleanup_timer := Timer, cleanup := Cleanup} = State) ->
    Unconfirmed = maps:map(fun
        (_, pending) -> {error, #{code => cleanup_timeout, cleanup => unverified}};
        (_, Reply) -> Reply
    end, Cleanup),
    cleanup_elapsed(State#{cleanup => Unconfirmed, cleanup_timer => none});
handle_info({timeout, Timer, expire}, #{expiry := Timer} = State) -> advance(forget_result(State));
handle_info(Message, #{requests := Requests} = State) ->
    case gen_server:check_response(Message, Requests, true) of
        {{reply, Reply}, Label, Rest} -> response(Label, Reply, State#{requests => Rest});
        {{error, _}, Label, Rest} ->
            Error = {error, #{code => resource_expired, cleanup => unverified}},
            response(Label, Error, State#{requests => Rest});
        _ -> {noreply, forget_waiter(Message, State)}
    end.

submit_input(Lease, Text, Reply, #{target := #{deadline := Deadline} = Target,
             input_admission := Admission, token := Token, input := none} = State) ->
    {ok, #{expires := InputDeadline}} = tmux_admission:lookup(Admission, Lease),
    Bounded = Target#{deadline := min(Deadline, InputDeadline)},
    Controller = self(),
    {Input, Monitor} = spawn_opt(fun() ->
        Result = tmux_program:submit_input(Bounded, Text),
        Controller ! {Token, self(), input_result, Result}
    end, [link, monitor]),
    State#{input => {Input, Monitor, Reply, Lease}};
submit_input(Lease, _, Reply, #{input_admission := Admission} = State) ->
    ok = tmux_admission:release(Admission, Lease),
    Reply ! {Reply, {error, #{code => program_not_running, outcome => not_started}}},
    State.

input_done(Result, #{input := {_, Monitor, Reply, Lease}, input_admission := Admission} = State) ->
    demonitor(Monitor, [flush]),
    ok = tmux_admission:release(Admission, Lease),
    Reply ! {Reply, Result},
    State#{input => none}.

sweep_input(#{input_admission := Admission} = State) ->
    _ = tmux_admission:expire(Admission),
    State#{input_sweep => erlang:start_timer(100, self(), input_sweep)}.

close_input(#{input_sweep := none} = State) -> State;
close_input(#{input_admission := Admission, input_sweep := Timer} = State) ->
    _ = erlang:cancel_timer(Timer),
    ok = tmux_admission:close(Admission),
    State#{input_sweep => none}.

permit(Stage, _, #{stopping := Reason} = State) when Reason =/= none ->
    {{error, #{code => Reason, stage => Stage, outcome => not_started}}, State};
permit(Stage, Detail, #{owner := Owner, worker := Worker} = State) ->
    case is_process_alive(Owner) andalso is_process_alive(Worker) of
        true -> allocate(Stage, Detail, State);
        false -> {{error, #{code => program_owner_exited, stage => Stage, outcome => not_started}}, State}
    end.

allocate(probe_version, {Executable, Timeout}, #{slot := Slot} = State) ->
    Options = #{timeout_ms => Timeout, max_stdout => 64, max_stderr => 4096},
    case tmux_transport:start(Executable, [<<"-V">>], Options, resource_id(Slot, version_probe)) of
        {ok, Probe} ->
            Request = tmux_transport:send_request(Probe, await),
            {pending, track(Request, probe_result, State#{version_probe => Probe})};
        {error, _} = Error -> {Error, State}
    end;
allocate(allocate, Options, #{slot := Slot} = State) ->
    case tmux_owned_server:open(Options, resource_id(Slot, ownership)) of
        {ok, Ownership, _} -> {{ok, Ownership}, State#{ownership => Ownership}};
        {error, _} = Error -> {Error, State}
    end;
allocate(hold_terminal, {Helper, Tty, Startup}, #{slot := Slot} = State) ->
    case tmux_transport:start_channel(Helper, [<<"--hold-program-tty">>, Tty],
                                      #{startup_timeout_ms => Startup}, resource_id(Slot, terminal_holder)) of
        {ok, Holder} -> {{ok, Holder}, State#{terminal_holder => Holder}};
        {error, _} = Error -> {Error, State}
    end;
allocate(release, _, State) -> {ok, State}.

terminal_notice(Reply, #{token := Token, worker := Worker, terminal_holder := Holder} = State) ->
    Worker ! {Token, Holder, Reply},
    State#{terminal_ready => true}.

probe_notice(Reply, #{token := Token, worker := Worker} = State) ->
    Worker ! {Token, probe_version, Reply},
    State.

request_stop(Reason, #{stopping := none, version_probe := Probe,
                       terminal_holder := Holder, terminal_ready := Ready} = State) ->
    Stopped = close_input(State#{stopping => Reason, target => none}),
    Cancelled = {error, #{code => Reason, outcome => not_started}},
    Next = if
        Probe =/= none -> probe_notice(Cancelled, Stopped);
        Holder =/= none, not Ready -> terminal_notice(Cancelled, Stopped);
        true -> Stopped
    end,
    begin_cleanup(Next);
request_stop(_, State) -> State.

cleanup_elapsed(#{stopping := Reason, primary := none, worker := Worker, ownership := Ownership} = State)
  when Reason =/= none ->
    exit(Worker, shutdown),
    Outcome = case Ownership of none -> not_started; _ -> unknown end,
    primary_done({error, #{code => Reason, outcome => Outcome}}, State);
cleanup_elapsed(State) -> advance(State).

primary_done(Result, #{timer := Timer} = State) ->
    ok = cancel_timer(Timer),
    advance(close_input(State#{primary => Result, timer => none, target => none})).

advance(#{result := expired, unconfirmed := []} = State) -> {stop, normal, State};
advance(#{result := Result} = State) when Result =/= none -> {noreply, State};
advance(#{primary := none} = State) -> {noreply, State};
advance(#{input := Input, stopping := none} = State) when Input =/= none -> {noreply, State};
advance(State) ->
    #{cleanup := Cleanup, primary := Primary} = Next = begin_cleanup(State),
    case lists:member(pending, maps:values(Cleanup)) of
        true -> {noreply, Next};
        false -> complete(cleanup_result(stop_result(Primary, Next), Next), Next)
    end.

begin_cleanup(#{cleanup := none} = State) ->
    Next = lists:foldl(fun retire/2, State#{cleanup => #{}}, ?RESOURCES),
    case map_size(maps:get(cleanup, Next)) of
        0 -> Next;
        _ -> Next#{cleanup_timer => erlang:start_timer(950, self(), cleanup)}
    end;
begin_cleanup(State) -> State.

retire(Resource, State) when map_get(Resource, State) =:= none -> State;
retire(ownership, #{ownership := Handle} = State) ->
    Retired = tmux_owned_server:send_request(Handle, retired),
    Stop = tmux_owned_server:send_request(Handle, stop),
    track_cleanup(ownership, Retired, Stop, State);
retire(Resource, State) ->
    Handle = map_get(Resource, State),
    Retired = tmux_transport:send_request(Handle, retired),
    Close = tmux_transport:send_request(Handle, close),
    track_cleanup(Resource, Retired, Close, State).

track_cleanup(Resource, Retired, Stop, #{cleanup := Cleanup, unconfirmed := Unconfirmed} = State) ->
    Next = track(Retired, {retired, Resource}, State),
    track(Stop, Resource, Next#{cleanup => Cleanup#{Resource => pending},
                                unconfirmed => [Resource | Unconfirmed]}).

track(Request, Label, #{requests := Requests} = State) ->
    State#{requests => gen_server:reqids_add(Request, Label, Requests)}.

response(terminal_ack, Reply, #{terminal_ready := false} = State) ->
    {noreply, terminal_notice(Reply, State)};
response(terminal_ack, _, State) -> {noreply, State};
response(probe_result, Reply, #{version_probe := Probe, cleanup := none} = State) ->
    Next = case Reply of
        {_, #{cleanup := complete}} ->
            ok = tmux_transport:close_async(Probe),
            State#{version_probe => none};
        _ -> State
    end,
    {noreply, probe_notice(Reply, Next)};
response(probe_result, _, State) -> {noreply, State};
response({retired, Resource}, Reply, State) ->
    case {Resource, Reply} of
        {ownership, ok} -> advance(confirmed(Resource, State));
        {Transport, {_, #{cleanup := complete}}} when Transport =:= version_probe; Transport =:= terminal_holder ->
            advance(confirmed(Resource, State));
        _ -> {noreply, State}
    end;
response(Resource, ok, State) -> advance(confirmed(Resource, State));
response(Resource, Reply, #{cleanup := Cleanup, unconfirmed := Unconfirmed} = State) ->
    case lists:member(Resource, Unconfirmed) of
        true -> advance(State#{cleanup => Cleanup#{Resource => Reply}});
        false -> {noreply, State}
    end.

confirmed(Resource, #{cleanup := Cleanup, unconfirmed := Unconfirmed} = State) ->
    State#{cleanup => Cleanup#{Resource => ok}, unconfirmed => lists:delete(Resource, Unconfirmed)}.

cleanup_result({Kind, Detail} = Primary, #{cleanup := Cleanup} = State) ->
    Errors = maps:filter(fun(_, Reply) -> Reply =/= ok end, Cleanup),
    case map_size(Errors) of
        0 -> {Kind, Detail#{cleanup => complete}};
        _ -> {error, #{code => program_cleanup_incomplete, cleanup => incomplete,
                      primary => Primary, causes => Errors, resources => maps:with(maps:keys(Errors), State)}}
    end.

complete(Result, #{cleanup_timer := CleanupTimer, owner_alive := Alive} = State) ->
    ok = cancel_timer(CleanupTimer),
    Next = reply_waiters(retire_input(State#{result => Result, cleanup_timer => none})),
    case Alive of
        true -> {noreply, Next#{expiry => erlang:start_timer(60000, self(), expire)}};
        false -> advance(forget_result(Next))
    end.

%% The public result can expire while native cleanup still owns the slot.
forget_result(#{expiry := Timer} = State) ->
    ok = cancel_timer(Timer),
    State#{result => expired, primary => none, expiry => none}.

retire_input(#{input := {Input, _, _, _}} = State) ->
    exit(Input, shutdown),
    input_done(input_unknown(), State);
retire_input(State) -> State.

stop_result({error, #{code := Reason}} = Result, #{stopping := Reason}) -> Result;
stop_result({error, Detail}, #{stopping := Reason}) when Reason =/= none ->
    Outcome = maps:get(outcome, Detail, unknown),
    {error, #{code => Reason, outcome => Outcome, cause => Detail}};
stop_result(Result, _) -> Result.

answer(started, #{started := true}) -> {ok, #{state => released}};
answer(started, #{result := {error, _} = Error}) -> Error;
answer(await, #{result := Result}) -> Result;
answer(started, _) -> none.

reply_waiters(#{waiters := Waiters} = State) ->
    maps:fold(fun(Tag, {Kind, From, _}, Current) ->
        case answer(Kind, Current) of
            none -> Current;
            Reply -> gen_server:reply(From, Reply), remove_waiter(Tag, Current)
        end
    end, State, Waiters).

remove_waiter(Tag, #{waiters := Waiters} = State) ->
    case maps:take(Tag, Waiters) of
        {{_, _, Monitor}, Rest} ->
            demonitor(Monitor, [flush]),
            State#{waiters => Rest};
        error -> State
    end.

forget_waiter({'DOWN', Monitor, process, _, _}, #{waiters := Waiters} = State) ->
    State#{waiters => maps:filter(fun(_, {_, _, Ref}) -> Ref =/= Monitor end, Waiters)};
forget_waiter(_, State) -> State.

-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun
        (state, State) -> maps:with([started, stopping], State);
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (_, Value) -> Value
    end, maps:without([log], Status)).

now_ms() -> erlang:monotonic_time(millisecond).

cancel_timer(none) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
