-module(tmux_pane_exit_owner).
-moduledoc false.
-behaviour(gen_server).
-export([start/4, check/1, release/1, start_link/5, init/1,
         handle_continue/2, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, format_status/1]).

-spec start(tmux_server:t(), binary(), pos_integer(), binary()) ->
    {ok, pid(), tmux_operation:t()} | {error, map()}.
start(Server, Target, Deadline, Tty) ->
    Token = make_ref(),
    Child = #{id => Token, start => {?MODULE, start_link,
        [self(), Server, Target, Deadline, Tty]}, restart => temporary, shutdown => 1000},
    try supervisor:start_child(tmux_sup, Child) of
        {ok, Pid} ->
            try gen_server:call(Pid, ready, min(900, Deadline)) of
                {ok, Operation} -> {ok, Pid, Operation};
                {error, _} = Error -> release(Pid), Error
            catch
                exit:_ ->
                    gen_server:cast(Pid, release),
                    {error, #{code => deadline}}
            end;
        {error, _} -> {error, #{code => pane_wait_unavailable}}
    catch exit:_ -> {error, #{code => pane_wait_unavailable}}
    end.

-spec check(pid()) -> ok | {error, map()}.
check(Pid) ->
    try gen_server:call(Pid, check, 900)
    catch exit:_ -> {error, #{code => pane_terminal_unavailable}}
    end.

-spec release(pid()) -> ok.
release(Pid) ->
    try gen_server:stop(Pid, normal, 900)
    catch exit:_ -> ok
    end.

-spec start_link(pid(), tmux_server:t(), binary(), pos_integer(), binary()) ->
    gen_server:start_ret().
start_link(Owner, Server, Target, Deadline, Tty) ->
    gen_server:start_link(?MODULE, {Owner, Server, Target, Deadline, Tty}, []).

-spec init({pid(), tmux_server:t(), binary(), pos_integer(), binary()}) ->
    {ok, map(), {continue, prepare}}.
init({Owner, Server, Target, Deadline, Tty}) ->
    process_flag(trap_exit, true),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Hook = <<"pane-died[", (integer_to_binary(1000000000 + rand:uniform(1000000000)))/binary, "]">>,
    {ok, #{owner_monitor => monitor(process, Owner), server => Server, target => Target,
        deadline => Deadline, tty => Tty, hook => Hook, channel => <<"libtmux-exit-", Suffix/binary>>,
        holder => none, pin => none, operation => none, native => false,
        ready_deadline => erlang:monotonic_time(millisecond) + min(900, Deadline),
        ready => none}, {continue, prepare}}.

-spec handle_continue(prepare, map()) -> {noreply, map()}.
handle_continue(prepare, State) ->
    {Result, Next} = prepare(State),
    {noreply, Next#{ready => Result}}.

prepare(#{server := Server, deadline := Deadline} = State) ->
    case wait_command(State) of
        {ok, Wait, Native} ->
            start_wait(Wait, State#{native => Native}, Server, Deadline);
        {error, _} = Error -> {Error, State}
    end.

wait_command(#{server := Server, target := Target, channel := Channel}) ->
    maybe
        {ok, Version} ?= tmux_server:version(Server),
        {ok, #{supported := Native}} ?= tmux_capability:decision(Version, pane_exit_events),
        {ok, Wait} ?= case Native of
            true ->
                Filter = <<"#{==:#{pane},", Target/binary, "}">>,
                tmux_command:raw(<<"wait-for">>,
                    [<<"-E">>, <<"-F">>, Filter, <<"pane-died">>]);
            false -> tmux_command:wait_for(Channel, wait)
        end,
        {ok, Wait, Native}
    end.

start_wait(Wait, State, Server, Deadline) ->
    case tmux_operation:start(Server, Wait, #{deadline_ms => Deadline}) of
        {ok, Operation} ->
            Next = State#{operation => Operation},
            case pin_terminal(Next) of
                {ok, Pinned} -> {signal_on_exit(Pinned), Pinned};
                {error, Error, Failed} ->
                    {{error, #{code => pane_generation_unavailable, cause => Error}}, Failed}
            end;
        {error, _} = Error -> {Error, State}
    end.

pin_terminal(#{tty := Tty} = State) ->
    Helper = unicode:characters_to_binary(filename:absname(filename:join(
        code:priv_dir(libtmux_erlang), "tmux_owned_io"))),
    case tmux_transport:start_channel(Helper, [<<"--hold-program-tty">>, Tty],
            #{startup_timeout_ms => 900}) of
        {ok, Holder} ->
            Next = State#{holder => Holder},
            receive
                {tmux_transport, Holder, {data, stdout, Sequence, <<"R">>}} ->
                    maybe
                        ok ?= tmux_transport:ack(Holder, stdout, Sequence),
                        {ok, #{child_pid := Pid}} ?= tmux_transport:status(Holder),
                        {ok, Identity} ?= tmux_identity:observe(Pid),
                        {ok, Next#{pin => {Pid, Identity}}}
                    else
                        {error, Detail} -> {error, Detail, Next}
                    end;
                {tmux_transport, Holder, _} ->
                    {error, #{code => pane_terminal_unavailable}, Next}
            after 900 -> {error, #{code => pane_terminal_unavailable}, Next}
            end;
        {error, Detail} -> {error, Detail, State}
    end.

signal_on_exit(#{native := true, operation := Operation, ready_deadline := Until} = State) ->
    Remaining = max(0, Until - erlang:monotonic_time(millisecond)),
    maybe
        {ok, _} ?= tmux_operation:await_started(Operation, Remaining),
        TimeLeft = max(0, Until - erlang:monotonic_time(millisecond)),
        case tmux_operation:client_pid(Operation, TimeLeft) of
            {ok, Pid} ->
                Client = <<"client-", (integer_to_binary(Pid))/binary>>,
                native_registered(Client, State);
            {error, _} -> completed_wait(Operation)
        end
    end;
%% Register and check together so a published exit cannot fall between them.
signal_on_exit(#{server := Server, target := Target, channel := Channel,
                 hook := Hook, operation := Operation}) ->
    Signal = <<"wait-for -S ", Channel/binary>>,
    Ready = <<"#{&&:#{pane_dead},",
              "#{||:#{!=:#{pane_dead_status},},#{!=:#{pane_dead_signal},}}}">>,
    maybe
        {ok, Set} ?= tmux_command:raw(<<"set-hook">>,
            [<<"-p">>, <<"-t">>, Target, <<"--">>, Hook, Signal]),
        {ok, Check} ?= tmux_command:raw(<<"if-shell">>,
            [<<"-F">>, <<"-t">>, Target, <<"--">>, Ready, Signal]),
        {ok, Sequence} ?= tmux_command:sequence([Set, Check]),
        {ok, _} ?= tmux_target:submit(Server, Sequence, #{deadline_ms => 900}),
        {ok, Operation}
    end.

%% The native listing proves this exact client registered, rather than merely exec'd.
native_registered(Client, #{server := Server, operation := Operation,
                            ready_deadline := Until} = State) ->
    case Until - erlang:monotonic_time(millisecond) of
        Remaining when Remaining > 0 ->
            maybe
                {ok, #{stdout := Output}} ?= tmux_target:run(Server, <<"wait-for">>,
                    [<<"-E">>, <<"-l">>, <<"pane-died">>],
                    #{deadline_ms => Remaining, max_stdout => 8192}),
                case lists:member(Client, binary:split(Output, <<"\n">>, [global])) of
                    true -> {ok, Operation};
                    false ->
                        case completed_wait(Operation) of
                            {error, #{code := await_timeout}} -> native_registered(Client, State);
                            Result -> Result
                        end
                end
            end;
        _ -> {error, #{code => deadline}}
    end.

completed_wait(Operation) ->
    case tmux_operation:status(Operation) of
        {ok, #{outcome := pending}} -> {error, #{code => await_timeout}};
        {ok, #{outcome := success, cleanup := complete}} -> {ok, Operation};
        {ok, _} ->
            case tmux_operation:await(Operation, 900) of
                {ok, _} -> {ok, Operation};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(ready, _, #{ready := Ready} = State) -> {reply, Ready, State};
handle_call(check, _, #{pin := {Pid, Identity}} = State) ->
    Result = case tmux_identity:check(Identity, Pid) of
        ok -> ok;
        _ -> {error, #{code => pane_terminal_unavailable}}
    end,
    {reply, Result, State};
handle_call(_, _, State) -> {reply, {error, #{code => invalid_pane_wait}}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_cast(release, State) -> {stop, normal, State};
handle_cast(_, State) -> {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({'DOWN', Monitor, process, _, _}, #{owner_monitor := Monitor} = State) ->
    {stop, normal, State};
handle_info(_, State) -> {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_, #{server := Server, target := Target, hook := Hook,
               operation := Operation, holder := Holder, native := Native}) ->
    case Native of
        true -> ok;
        false ->
            _ = tmux_target:run(Server, <<"set-hook">>,
                [<<"-p">>, <<"-u">>, <<"-t">>, Target, <<"--">>, Hook], #{deadline_ms => 900}),
            ok
    end,
    case Operation of
        none -> ok;
        _ ->
            _ = tmux_operation:cancel(Operation),
            _ = tmux_operation:await(Operation, 900),
            ok
    end,
    case Holder of none -> ok; _ -> _ = tmux_transport:close(Holder), ok end.

-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun
        (state, _) -> redacted;
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (_, Value) -> Value
    end, maps:remove(log, Status)).
