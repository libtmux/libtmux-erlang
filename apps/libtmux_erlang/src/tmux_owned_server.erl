-module(tmux_owned_server).
-moduledoc false.
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([start/1, stop/1, prepare_stop/0, start_link/3, init/1, handle_continue/2,
         handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-spec start(map()) -> {ok, tmux_server:t(), tmux_server:ownership()} | {error, map()}.
start(Options) ->
    maybe
        {ok, Config} ?= options(Options),
        {ok, _} ?= application:ensure_all_started(libtmux_erlang),
        Token = make_ref(),
        Child = #{id => Token, start => {?MODULE, start_link, [self(), Token, Config]},
                  restart => temporary, shutdown => 1000},
        case supervisor:start_child(tmux_sup, Child) of
            {ok, Pid} ->
                Handle = {owned_server, Pid, Token},
                case request(Handle, ready, maps:get(startup_timeout_ms, Config) + 1100) of
                    {error, #{code := await_timeout}} ->
                        gen_server:cast(Pid, {Token, abort}),
                        {error, #{code => startup_timeout, cleanup => incomplete,
                                  ownership => Handle, resources => unverified}};
                    Result -> Result
                end;
            {error, _} -> {error, #{code => owned_server_unavailable}}
        end
    end.

-spec stop(tmux_server:ownership()) -> ok | {error, map()}.
stop(Handle) -> request(Handle, stop, 1000).

request({owned_server, Pid, Token}, Kind, Timeout) when is_pid(Pid), is_reference(Token) ->
    Tag = make_ref(),
    Req = gen_server:send_request(Pid, {Token, Kind, Tag}),
    case gen_server:receive_response(Req, Timeout) of
        {reply, Reply} -> Reply;
        timeout ->
            gen_server:cast(Pid, {Token, unwait, Tag}),
            {error, #{code => await_timeout, cleanup => incomplete}};
        {error, _} -> {error, #{code => ownership_expired, cleanup => unverified}}
    end;
request(_, _, _) -> {error, #{code => invalid_ownership}}.

%% Run before supervisor shutdown while endpoint and transport owners can reply.
-spec prepare_stop() -> ok | {error, map()}.
prepare_stop() ->
    Requests = [gen_server:send_request(Pid, shutdown)
        || {_, Pid, worker, [Module]} <- supervisor:which_children(tmux_sup),
           is_pid(Pid), Module =:= ?MODULE],
    Deadline = now_ms() + 1000,
    Results = [gen_server:receive_response(Req, max(0, Deadline - now_ms())) || Req <- Requests],
    Errors = [shutdown_error(Result) || Result <- Results, Result =/= {reply, ok}],
    case Errors of
        [] -> ok;
        _ -> {error, #{code => owned_cleanup_incomplete, reports => Errors}}
    end.

shutdown_error({reply, {error, Error}}) -> Error;
shutdown_error(_) -> #{code => cleanup_incomplete, cleanup => unverified,
                       recovery_report => unconfirmed}.

-spec start_link(pid(), reference(), map()) -> gen_server:start_ret().
start_link(Owner, Token, Config) -> gen_server:start_link(?MODULE, {Owner, Token, Config}, []).

-spec init({pid(), reference(), map()}) -> {ok, map(), {continue, launch}}.
init({Owner, Token, Config}) ->
    State = #{owner => Owner, monitor => monitor(process, Owner), owner_alive => true,
        token => Token, config => Config, deadline => now_ms() + maps:get(startup_timeout_ms, Config),
        phase => starting, startup_timer => none, cleanup_timer => none, expire_timer => none,
        directory => none, directory_identity => none, socket => none, socket_identity => none,
        channel => none, endpoint => none, probe => none, probe_retired => true,
        channel_retired => true, endpoint_retired => true,
        requests => gen_server:reqids_new(), readiness => <<>>, ready_result => none,
        failure => none, waiters => #{}, stop_result => none,
        handoff_on_incomplete => false, recovery_report => none, native_processes => #{}},
    {ok, State, {continue, launch}}.

-spec handle_continue(launch, map()) -> {noreply, map()}.
handle_continue(launch, State) ->
    {noreply, launch(State)}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()} | {noreply, map()}.
handle_call({Token, ready, Tag}, From, #{token := Token, ready_result := none} = State) ->
    case map_size(maps:get(waiters, State)) < 16 of
        true -> {noreply, add_waiter(Tag, ready, From, State)};
        false -> {reply, {error, #{code => too_many_waiters}}, State}
    end;
handle_call({Token, ready, _}, _, #{token := Token, ready_result := Result} = State) ->
    {reply, Result, State};
handle_call({Token, stop, Tag}, From, #{token := Token} = State) ->
    stop_call(Tag, From, State);
handle_call(shutdown, From, State) ->
    stop_call(make_ref(), From, State#{handoff_on_incomplete => true});
handle_call(_, _, State) -> {reply, {error, #{code => invalid_ownership}}, State}.

stop_call(Tag, From, State) ->
    Next = advance(begin_stop(State)),
    case maps:get(stop_result, Next) of
        none when map_size(map_get(waiters, Next)) < 16 ->
            {noreply, add_waiter(Tag, stop, From, Next)};
        none -> {reply, {error, #{code => too_many_waiters}}, Next};
        {error, _} ->
            Reported = incomplete(Next),
            {reply, maps:get(stop_result, Reported), Reported};
        Result -> {reply, Result, Next}
    end.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({Token, abort}, #{token := Token} = State) ->
    {noreply, advance(begin_stop(State))};
handle_cast({Token, unwait, Tag}, #{token := Token} = State) ->
    {noreply, remove_waiter(Tag, State)};
handle_cast(_, State) -> {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({tmux_transport, Handle, {data, stdout, Seq, Bytes}},
            #{channel := Handle, phase := starting} = State) ->
    {noreply, readiness(Seq, Bytes, State)};
handle_info({tmux_transport, Handle, {data, stderr, _, Bytes}}, #{channel := Handle} = State) ->
    {noreply, advance(fail(#{code => bootstrap_error,
        stderr => binary:part(Bytes, 0, min(4096, byte_size(Bytes)))}, State))};
handle_info({timeout, Timer, startup}, #{startup_timer := Timer, phase := starting} = State) ->
    {noreply, advance(fail(#{code => startup_timeout}, State#{startup_timer => none}))};
handle_info({timeout, Timer, cleanup}, #{cleanup_timer := Timer} = State) ->
    Next = incomplete(State#{cleanup_timer => none}),
    {noreply, Next};
handle_info({timeout, Timer, expire}, #{expire_timer := Timer, phase := stopped} = State) ->
    {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, #{monitor := Monitor} = State) ->
    finish(advance(begin_stop(State#{owner_alive => false})));
handle_info({'DOWN', Monitor, process, _, _} = Message, State) ->
    case response(Message, State) of
        none -> {noreply, remove_monitor(Monitor, State)};
        Next -> finish(advance(Next))
    end;
handle_info(Message, State) ->
    case response(Message, State) of
        none -> {noreply, State};
        Next -> finish(advance(Next))
    end.

-spec format_status(map()) -> map().
format_status(Status) -> maps:map(fun
    (state, State) -> maps:with([phase, channel_retired, endpoint_retired, stop_result], State);
    (message, _) -> redacted;
    (reason, _) -> redacted;
    (_, Value) -> Value
end, maps:without([log], Status)).

-spec terminate(term(), map()) -> ok.
terminate(_, #{phase := stopped}) -> ok;
terminate(_, State) ->
    _ = handoff(State),
    ok.

options(Options) when is_map(Options) ->
    Executable = maps:get(executable, Options, case os:find_executable("tmux") of
        false -> none;
        Path -> unicode:characters_to_binary(Path)
    end),
    Timeout = maps:get(startup_timeout_ms, Options, 2500),
    case maps:without([executable, startup_timeout_ms], Options) =:= #{} andalso
         is_integer(Timeout, 1, 600000) of
        false -> {error, #{code => invalid_owned_options}};
        true ->
            case Executable of
                <<$/, _/binary>> when byte_size(Executable) =< 32768 ->
                    case binary:match(Executable, <<0>>) of
                        nomatch -> {ok, #{executable => Executable, startup_timeout_ms => Timeout}};
                        _ -> {error, #{code => invalid_executable}}
                    end;
                _ -> {error, #{code => invalid_executable}}
            end
    end;
options(_) -> {error, #{code => invalid_owned_options}}.

launch(State) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    Directory = <<"/tmp/ltm-owned-", Suffix/binary>>,
    case file:make_dir(Directory) of
        {error, Reason} -> advance(fail(#{code => namespace_unavailable, reason => Reason}, State));
        ok ->
            Next = State#{directory => Directory, socket => <<Directory/binary, "/s">>},
            case {file:change_mode(Directory, 8#700), file:read_link_info(Directory)} of
                {ok, {ok, Info}} -> start_channel(Next#{directory_identity => identity(Info)});
                _ -> advance(fail(#{code => namespace_unavailable}, Next))
            end
    end.

start_channel(#{config := Config, socket := Socket, deadline := Deadline} = State) ->
    Remaining = Deadline - now_ms(),
    case Remaining > 0 of
        false -> advance(fail(#{code => startup_timeout}, State));
        true ->
            Args = [<<"-u">>, <<"-S">>, Socket, <<"-f">>, <<"/dev/null">>,
                <<"start-server">>, <<";">>, <<"set-option">>, <<"-s">>, <<"exit-empty">>, <<"off">>,
                <<";">>, <<"display-message">>, <<"-p">>, <<"#{pid}\t#{version}">>,
                <<";">>, <<"wait-for">>, <<"owned-lifetime">>],
            case tmux_transport:start_channel(maps:get(executable, Config), Args,
                                               #{startup_timeout_ms => min(600000, Remaining)}) of
                {ok, Channel} ->
                    Requests = add_request(tmux_transport:send_request(Channel, await), result,
                        add_request(tmux_transport:send_request(Channel, retired), retired,
                                    maps:get(requests, State))),
                    State#{channel => Channel, channel_retired => false, requests => Requests,
                        startup_timer => erlang:start_timer(Remaining, self(), startup)};
                {error, Error} -> advance(fail(Error, State))
            end
    end.

readiness(Seq, Bytes, #{readiness := Acc, channel := Channel} = State) ->
    Joined = <<Acc/binary, Bytes/binary>>,
    case byte_size(Joined) =< 128 of
        false -> advance(fail(#{code => invalid_readiness}, State));
        true ->
            case binary:split(Joined, <<"\n">>) of
                [Line, <<>>] -> bind_endpoint(Line, State#{readiness => <<>>});
                [_] ->
                    case tmux_transport:ack(Channel, stdout, Seq) of
                        ok -> State#{readiness => Joined};
                        {error, Error} -> advance(fail(Error, State))
                    end;
                _ -> advance(fail(#{code => invalid_readiness}, State))
            end
    end.

bind_endpoint(Line, #{socket := Socket, directory := Directory, config := Config} = State) ->
    case {same_path(Directory, maps:get(directory_identity, State)), file:read_link_info(Socket)} of
        {true, {ok, #file_info{type = other} = Info}} ->
            Next = State#{socket_identity => identity(Info)},
            EndpointConfig = #{socket_path => Socket, executable => maps:get(executable, Config)},
            start_probe(Line, EndpointConfig, Next);
        _ -> advance(fail(#{code => namespace_changed}, State))
    end.

start_probe(Line, Config, State) ->
    Remaining = maps:get(deadline, State) - now_ms(),
    case Remaining > 0 of
        false -> advance(fail(#{code => startup_timeout}, State));
        true ->
            Args = [<<"-u">>, <<"-N">>, <<"-S">>, maps:get(socket_path, Config),
                    <<"display-message">>, <<"-p">>, <<"#{pid}\t#{version}">>],
            case tmux_transport:start(maps:get(executable, Config), Args,
                #{timeout_ms => min(Remaining, 600000), max_stdout => 128, max_stderr => 4096}) of
                {ok, Probe} ->
                    Requests = add_request(tmux_transport:send_request(Probe, await), probe,
                        add_request(tmux_transport:send_request(Probe, retired), probe_retired,
                                    maps:get(requests, State))),
                    Processes = native_processes(maps:get(channel, State)),
                    State#{probe => Probe, probe_retired => false, expected_probe => Line,
                           native_processes => Processes,
                           endpoint_config => Config, requests => Requests};
                {error, Error} -> advance(fail(Error, State))
            end
    end.

complete_binding(#{expected_probe := Line, endpoint_config := EndpointConfig} = State) ->
    case same_namespace(State) andalso now_ms() < maps:get(deadline, State) of
        true ->
            Opened = try tmux_server:open_observed(self(), EndpointConfig, Line)
                     catch exit:_ -> {error, #{code => endpoint_unavailable}}
                     end,
            case Opened of
                {ok, Endpoint} ->
                    Requests = add_request(tmux_server:send_request(Endpoint, retired),
                                           endpoint_retired, maps:get(requests, State)),
                    Bound = State#{endpoint => Endpoint, endpoint_retired => false,
                                   requests => Requests},
                    case now_ms() < maps:get(deadline, State) andalso
                         is_process_alive(maps:get(owner, State)) andalso
                         same_namespace(State) of
                        true ->
                            cancel_timer(maps:get(startup_timer, State)),
                            Result = {ok, Endpoint, {owned_server, self(), maps:get(token, State)}},
                            reply_kind(ready, Result, Bound#{phase => running,
                                startup_timer => none, ready_result => Result});
                        false -> advance(fail(#{code => startup_binding_changed}, Bound))
                    end;
                {error, Error} -> advance(fail(Error, State))
            end;
        false -> advance(fail(#{code => startup_binding_changed}, State))
    end.

same_namespace(#{directory := Directory, directory_identity := DirIdentity,
                 socket := Socket, socket_identity := SocketIdentity}) ->
    same_path(Directory, DirIdentity) andalso same_path(Socket, SocketIdentity).

fail(Error, #{failure := none} = State) ->
    ok = tmux_log:owned(owned_server_failure, State, Error),
    begin_stop(State#{failure => Error});
fail(_, State) -> begin_stop(State).

begin_stop(#{phase := stopped} = State) -> State;
begin_stop(#{phase := stopping} = State) -> State;
begin_stop(State) ->
    cancel_timer(maps:get(startup_timer, State)),
    case maps:get(channel, State) of
        none -> ok;
        Channel -> ok = tmux_transport:cancel_async(Channel)
    end,
    case maps:get(probe, State) of
        none -> ok;
        Probe -> ok = tmux_transport:cancel_async(Probe)
    end,
    Requests = case {maps:get(endpoint, State), maps:get(endpoint_retired, State)} of
        {none, _} -> maps:get(requests, State);
        {_, true} -> maps:get(requests, State);
        {Endpoint, false} ->
            add_request(tmux_server:send_request(Endpoint, close), endpoint_close,
                        maps:get(requests, State))
    end,
    State#{phase => stopping, requests => Requests, startup_timer => none,
           cleanup_timer => erlang:start_timer(900, self(), cleanup)}.

response(Message, #{requests := Requests} = State) ->
    case gen_server:check_response(Message, Requests, true) of
        {{reply, Result}, Label, Rest} -> response_result(Label, Result, State#{requests => Rest});
        {{error, _}, endpoint_close, Rest} -> State#{requests => Rest};
        {{error, _}, _Label, Rest} -> incomplete(begin_stop(State#{requests => Rest}));
        _ -> none
    end.

response_result(retired, {_, #{cleanup := complete}}, State) ->
    fail_if_running(State#{channel_retired => true});
response_result(result, {error, #{cleanup := complete} = Error}, State) -> fail(Error, State);
response_result(result, {_, #{cleanup := complete}}, State) -> fail_if_running(State);
response_result(result, _, State) -> incomplete(begin_stop(State));
response_result(probe, {ok, #{cleanup := complete, exit_status := 0, stdout := Bytes}},
                #{phase := starting, expected_probe := Line} = State) ->
    Next = State#{probe_retired => true},
    case Bytes =:= <<Line/binary, $\n>> of
        true -> complete_binding(Next);
        false -> fail(#{code => startup_binding_changed}, Next)
    end;
response_result(probe, {_, #{cleanup := complete}}, State) ->
    fail(#{code => startup_probe_failed}, State#{probe_retired => true});
response_result(probe, _, State) -> incomplete(begin_stop(State));
response_result(probe_retired, {_, #{cleanup := complete}}, State) -> State#{probe_retired => true};
response_result(endpoint_retired, ok, State) -> State#{endpoint_retired => true};
response_result(endpoint_close, _, State) -> State;
response_result(_, _, State) -> incomplete(State).

fail_if_running(#{phase := stopping} = State) -> State;
fail_if_running(State) -> fail(#{code => bootstrap_exited}, State).

advance(#{phase := stopping, channel_retired := true, endpoint_retired := true,
          probe_retired := true} = State) ->
    cancel_timer(maps:get(cleanup_timer, State)),
    case cleanup_namespace(State) of
        ok ->
            case maps:get(channel, State) of
                none -> ok;
                Channel -> ok = tmux_transport:close_async(Channel)
            end,
            case maps:get(probe, State) of
                none -> ok;
                Probe -> ok = tmux_transport:close_async(Probe)
            end,
            Result = startup_failure(complete, State),
            Next = reply_kind(stop, ok, State#{phase => stopped, cleanup_timer => none,
                stop_result => ok, expire_timer => erlang:start_timer(60000, self(), expire)}),
            maybe_ready(Result, Next);
        {error, Reason} -> incomplete(State#{cleanup_timer => none,
                                             namespace_failure => Reason})
    end;
advance(State) -> State.

incomplete(State) ->
    Reported = case maps:get(handoff_on_incomplete, State) of
        true -> handoff(State);
        false -> State
    end,
    Detail = #{code => cleanup_incomplete,
        process_cleanup => case maps:get(channel_retired, State) of true -> complete; false -> incomplete end,
        endpoint_cleanup => case maps:get(endpoint_retired, State) of true -> complete; false -> incomplete end,
        probe_cleanup => case maps:get(probe_retired, State) of true -> complete; false -> incomplete end,
        namespace_cleanup => maps:get(namespace_failure, State, pending), cleanup => incomplete,
        ownership => {owned_server, self(), maps:get(token, State)},
        resources => maps:with([directory, directory_identity, socket, socket_identity,
                               native_processes], State),
        recovery_report => maps:get(recovery_report, Reported)},
    Result = {error, Detail},
    case maps:get(stop_result, State) of
        none -> ok = tmux_log:owned(owned_server_cleanup_incomplete, State, Detail);
        _ -> ok
    end,
    maybe_ready(Result, reply_kind(stop, Result, Reported#{stop_result => Result})).

%% Recovery reports are observations, never permission to signal a PID or path.
handoff(#{recovery_report := Report} = State) when Report =/= none -> State;
handoff(State) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    Directory = <<"/tmp/ltm-recovery-", Suffix/binary>>,
    File = <<Directory/binary, "/cleanup.json">>,
    Data = maps:with([phase, directory, directory_identity, socket, socket_identity,
        native_processes, channel_retired, probe_retired, endpoint_retired,
        namespace_failure], State),
    Document = wire(Data#{version => 1, recorded_at => erlang:system_time(second),
        controller => self(), process_cleanup => maps:get(channel_retired, State),
        automatic_recovery => false}),
    Result = maybe
        ok ?= file:make_dir(Directory),
        ok ?= file:change_mode(Directory, 8#700),
        {ok, Descriptor} ?= file:open(File, [write, binary, exclusive]),
        Written = try maybe
            ok ?= file:change_mode(File, 8#600),
            ok ?= file:write(Descriptor, json:encode(Document)),
            file:sync(Descriptor)
        end
        after _ = file:close(Descriptor)
        end,
        ok ?= Written,
        {ok, File}
    end,
    case Result of
        {ok, _} -> State#{recovery_report => Result};
        _Error ->
            ok = tmux_log:owned(owned_server_recovery_report_failed, State,
                #{code => recovery_report_write_failed}),
            State#{recovery_report => {error, recovery_report_write_failed}}
    end.

wire(Map) when is_map(Map) -> maps:map(fun(_, Value) -> wire(Value) end, Map);
wire(Tuple) when is_tuple(Tuple) -> [wire(Value) || Value <- tuple_to_list(Tuple)];
wire(Pid) when is_pid(Pid) -> list_to_binary(pid_to_list(Pid));
wire(Value) -> Value.

native_processes(Handle) ->
    case tmux_transport:status(Handle) of
        {ok, Status} -> maps:map(fun(_, Pid) ->
            #{pid => Pid, incarnation => case tmux_identity:observe(Pid) of
                {ok, Identity} -> Identity;
                _ -> unverified
            end}
        end, maps:with([helper_pid, child_pid], Status));
        _ -> #{}
    end.

startup_failure(Cleanup, State) ->
    Reason = case maps:get(failure, State) of none -> #{code => startup_cancelled}; Error -> Error end,
    {error, Reason#{cleanup => Cleanup}}.

maybe_ready(Result, #{ready_result := none} = State) ->
    reply_kind(ready, Result, State#{ready_result => Result});
maybe_ready(_, State) -> State.

cleanup_namespace(#{directory := none}) -> ok;
cleanup_namespace(#{directory := Directory, directory_identity := DirIdentity,
                    socket := Socket, socket_identity := SocketIdentity}) ->
    case same_path(Directory, DirIdentity) of
        false -> {error, directory_changed};
        true ->
            case file:read_link_info(Socket) of
                {error, enoent} -> remove_directory(Directory, DirIdentity);
                {ok, Info} when SocketIdentity =/= none ->
                    case identity(Info) =:= SocketIdentity of
                        true ->
                            case file:delete(Socket) of
                                ok -> remove_directory(Directory, DirIdentity);
                                {error, Reason} -> {error, {socket_delete, Reason}}
                            end;
                        false -> {error, socket_changed}
                    end;
                _ -> {error, socket_unverified}
            end
    end.

remove_directory(Directory, Identity) ->
    case same_path(Directory, Identity) of
        false -> {error, directory_changed};
        true ->
            case file:del_dir(Directory) of
                ok -> ok;
                {error, Reason} -> {error, {directory_delete, Reason}}
            end
    end.

identity(#file_info{type = Type, inode = Inode, major_device = Major, minor_device = Minor}) ->
    {Type, Major, Minor, Inode}.

same_path(Path, Expected) ->
    case file:read_link_info(Path) of
        {ok, Info} -> identity(Info) =:= Expected;
        _ -> false
    end.

add_request(Request, Label, Requests) -> gen_server:reqids_add(Request, Label, Requests).

add_waiter(Tag, Kind, {Pid, _} = From, #{waiters := Waiters} = State) ->
    State#{waiters => Waiters#{Tag => {Kind, From, monitor(process, Pid)}}}.

reply_kind(Kind, Result, State) ->
    maps:fold(fun(Tag, {K, From, _}, Acc) when K =:= Kind ->
        gen_server:reply(From, Result), remove_waiter(Tag, Acc);
        (_, _, Acc) -> Acc
    end, State, maps:get(waiters, State)).

remove_waiter(Tag, #{waiters := Waiters} = State) ->
    case maps:take(Tag, Waiters) of
        {{_, _, Monitor}, Rest} -> demonitor(Monitor, [flush]), State#{waiters => Rest};
        error -> State
    end.

remove_monitor(Monitor, State) ->
    maps:fold(fun(Tag, {_, _, Ref}, Acc) ->
        case Ref =:= Monitor of true -> remove_waiter(Tag, Acc); false -> Acc end
    end, State, maps:get(waiters, State)).

finish(#{phase := stopped, owner_alive := false} = State) -> {stop, normal, State};
finish(State) -> {noreply, State}.

cancel_timer(none) -> ok;
cancel_timer(Timer) -> _ = erlang:cancel_timer(Timer), ok.
now_ms() -> erlang:monotonic_time(millisecond).
