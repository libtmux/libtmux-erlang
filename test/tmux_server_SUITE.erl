-module(tmux_server_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         borrowed_commands/1, cancellation/1, operation_owner/1, stale_endpoint/1,
         replacement_endpoint/1, retirement_requests/1,
         ownership_transfer/1, endpoint_owner/1, admission_limits/1, result_retention/1,
         admission_expiry/1, registry_restart/1]).

%% Outer: real tmux commands, operation ownership and borrowed-server survival.
all() -> [borrowed_commands, cancellation, operation_owner, stale_endpoint,
          replacement_endpoint, retirement_requests,
          ownership_transfer, endpoint_owner, admission_limits, result_retention,
          admission_expiry, registry_restart].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    true = is_list(Executable),
    [{executable, unicode:characters_to_binary(Executable)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

borrowed_commands(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        #{server_pid := Pid, socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, Origin} = tmux_server:origin(Server),
        {ok, Server} = tmux_server:from_origin(Origin),
        {ok, _} = tmux_server:version(Server),
        {error, #{code := stale_reference}} = tmux_server:from_origin(make_ref()),
        Expected = <<(integer_to_binary(Pid))/binary, $\n>>,
        {ok, #{stdout := Expected, cleanup := complete, outcome := success}} =
            tmux_server:command(Server, raw(<<"display-message">>, [<<"-p">>, <<"#{pid}">>]), #{}),
        {error, #{code := command_error, exit_status := 1, outcome := error,
                  cleanup := complete}} =
            tmux_server:command(Server, raw(<<"no-such-tmux-command">>, []), #{}),
        {error, #{code := unsupported_identity_guarantee}} =
            tmux_operation:start(Server, raw(<<"list-sessions">>, []),
                                 #{identity => same_connection}),
        Missing = <<Socket/binary, "-absent">>,
        {error, _} = tmux_server:open(#{socket_path => Missing,
                                      executable => proplists:get_value(executable, Config)}),
        {error, enoent} = file:read_file_info(Missing),
        ok = tmux_server:close(Server),
        ok = tmux_server:close(Server),
        {error, #{code := stale_reference}} = tmux_server:from_origin(Origin),
        {ok, #{stdout := Expected}} = tmux_test_fixture:command(Fixture,
            [<<"display-message">>, <<"-p">>, <<"#{pid}">>])
    end).

cancellation(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        Blocked = [begin
            {ok, Op} = tmux_operation:start(Server,
                raw(<<"wait-for">>, [integer_to_binary(N)]), #{deadline_ms => 5000}),
            {ok, #{phase := sent}} = tmux_operation:await_started(Op, 900),
            Op
        end || N <- lists:seq(1, 3)],
        {ok, Queued} = tmux_operation:start(Server,
            raw(<<"set-option">>, [<<"-g">>, <<"@queued">>, <<"ran">>]), #{}),
        {ok, #{phase := queued}} = tmux_operation:status(Queued),
        {error, #{code := await_timeout}} = tmux_operation:await(Queued, 0),
        {ok, cancelled_before_send} = tmux_operation:cancel(Queued),
        {error, #{outcome := cancelled_before_send, cleanup := complete}} =
            tmux_operation:await(Queued, 900),
        lists:foreach(fun(Op) ->
            {ok, cancel_requested} = tmux_operation:cancel(Op),
            {error, #{outcome := unknown, cleanup := complete}} = tmux_operation:await(Op, 900)
        end, Blocked),
        {ok, #{exit_status := 1}} = tmux_test_fixture:command(Fixture,
            [<<"show-option">>, <<"-gv">>, <<"@queued">>]),
        {ok, #{operations := 0, command_bytes := 0, active_bytes := 0}} =
            tmux_server:status(Server)
    end).

raw(Name, Arguments) -> {ok, Command} = tmux_command:raw(Name, Arguments), Command.

operation_owner(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        Parent = self(),
        {Owner, Monitor} = spawn_monitor(fun() ->
            {ok, Op} = tmux_operation:start(Server, raw(<<"wait-for">>, [<<"owner">>]),
                                           #{deadline_ms => 5000}),
            {ok, _} = tmux_operation:await_started(Op, 900),
            Parent ! {owned, self(), Op},
            receive finish -> ok end
        end),
        Op = receive {owned, Owner, Handle} -> Handle
             after 900 -> ct:fail(owner_start_timeout)
             end,
        {error, #{code := await_timeout}} = tmux_operation:await(Op, 0),
        exit(Owner, kill),
        receive {'DOWN', Monitor, process, Owner, killed} -> ok
        after 900 -> ct:fail(owner_exit_timeout)
        end,
        {error, #{code := owner_down, outcome := unknown, cleanup := complete}} =
            tmux_operation:await(Op, 900),
        {ok, #{operations := 0, active_bytes := 0}} = tmux_server:status(Server),
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"display-message">>, <<"-p">>, <<"#{pid}">>])
    end).

stale_endpoint(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, Origin} = tmux_server:origin(Server),
        ok = tmux_test_fixture:close(Fixture),
        {error, #{code := stale_server, submitted := false}} =
            tmux_server:command(Server, raw(<<"new-session">>, [<<"-d">>]), #{}),
        {error, #{code := stale_reference}} = tmux_server:from_origin(Origin),
        {ok, #{operations := 0, active_bytes := 0}} = tmux_server:status(Server)
    end).

replacement_endpoint(Config) ->
    with_server(Config, fun(OldServer, Fixture) ->
        #{socket := Socket, server_pid := OldPid} = tmux_test_fixture:info(Fixture),
        {ok, OldSession} = tmux_session:create(OldServer,
            #{name => <<"original">>, launch => #{argv => [<<"cat">>]}}),
        {ok, OldSnapshot} = tmux_server:snapshot(OldServer),
        [OldWindow] = tmux_snapshot:windows(OldSnapshot),
        [OldPane] = tmux_snapshot:panes(OldSnapshot),
        #tmux_model:session{id = SessionId} = OldSession,
        #tmux_model:window{id = WindowId} = OldWindow,
        #tmux_model:pane{id = PaneId} = OldPane,
        {ok, Origin} = tmux_server:origin(OldServer),
        ok = tmux_test_fixture:replace(Fixture),
        #{socket := Socket, server_pid := NewPid} = tmux_test_fixture:info(Fixture),
        true = NewPid =/= OldPid,
        Executable = proplists:get_value(executable, Config),
        {ok, NewServer} = tmux_server:open(#{socket_path => Socket,
                                           executable => Executable}),
        try
            {ok, #tmux_model:session{id = SessionId}} = tmux_session:create(NewServer,
                #{name => <<"replacement">>, launch => #{argv => [<<"cat">>]}}),
            {ok, NewSnapshot} = tmux_server:snapshot(NewServer),
            [#tmux_model:window{id = WindowId}] = tmux_snapshot:windows(NewSnapshot),
            [#tmux_model:pane{id = PaneId}] = tmux_snapshot:panes(NewSnapshot),
            {error, #{code := stale_server, submitted := false}} =
                tmux_session:rename(OldSession, <<"forbidden">>),
            {error, #{code := stale_reference}} = tmux_window:kill(OldWindow),
            {error, #{code := stale_reference}} = tmux_pane:kill(OldPane),
            {error, #{code := stale_reference}} = tmux_server:from_origin(Origin),
            ok = tmux_server:close(OldServer),
            Expected = <<(integer_to_binary(NewPid))/binary, $\n>>,
            {ok, #{stdout := Expected}} = tmux_test_fixture:command(Fixture,
                [<<"display-message">>, <<"-p">>, <<"#{pid}">>]),
            {ok, #tmux_model:session{name = <<"replacement">>}} =
                tmux_session:get(NewServer, SessionId),
            {ok, #tmux_model:window{id = WindowId}} = tmux_window:get(NewServer, WindowId),
            {ok, #tmux_model:pane{id = PaneId}} = tmux_pane:get(NewServer, PaneId)
        after ok = tmux_server:close(NewServer)
        end
    end).

retirement_requests(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, Op} = tmux_operation:start(Server,
            raw(<<"wait-for">>, [<<"retirement">>]), #{deadline_ms => 5000}),
        {ok, #{phase := sent}} = tmux_operation:await_started(Op, 900),
        {ok, #{owner := Endpoint}} = tmux_server:status(Server),
        [#{handle := Handle}] = maps:values(maps:get(operations, sys:get_state(Endpoint))),
        {ok, #{helper_pid := Helper}} = tmux_transport:status(Handle),
        Identity = tmux_test_fixture:process_identity(Helper),
        try
            signal_helper(Helper, Identity, <<"-STOP">>),
            Retired = tmux_server:send_request(Server, retired),
            {ok, #{phase := open}} = tmux_server:status(Server),
            Others = [tmux_server:send_request(Server, retired)
                      || _ <- lists:seq(1, 14)],
            Closing = tmux_server:send_request(Server, close),
            Overflow = tmux_server:send_request(Server, retired),
            {reply, {error, #{code := too_many_waiters}}} =
                gen_server:receive_response(Overflow, 900),
            {ok, #{phase := closing}} = tmux_server:status(Server),
            #{close_timer := Timer} = sys:get_state(Endpoint),
            %% Deliver the actual timer's event while native cleanup is paused.
            %% No elapsed-time wait is needed to exercise the deadline branch.
            Endpoint ! {timeout, Timer, close},
            {reply, {error, #{code := cleanup_incomplete}}} =
                gen_server:receive_response(Closing, 900),
            lists:foreach(fun(Request) ->
                timeout = gen_server:wait_response(Request, 0)
            end, [Retired | Others]),
            signal_helper(Helper, Identity, <<"-CONT">>),
            lists:foreach(fun(Request) ->
                {reply, ok} = gen_server:receive_response(Request, 900)
            end, [Retired | Others]),
            false = tmux_test_fixture:same_process(Helper, Identity),
            {ok, #{phase := closed, operations := 0}} = tmux_server:status(Server)
        after
            case tmux_test_fixture:same_process(Helper, Identity) of
                true -> signal_helper(Helper, Identity, <<"-CONT">>);
                false -> ok
            end
        end,
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, Full} = tmux_server:open(#{socket_path => Socket,
            executable => proplists:get_value(executable, Config)}),
        try
            Passive = [tmux_server:send_request(Full, retired)
                       || _ <- lists:seq(1, 16)],
            {ok, #{phase := open}} = tmux_server:status(Full),
            ok = tmux_server:close(Full),
            lists:foreach(fun(Request) ->
                {reply, ok} = gen_server:receive_response(Request, 900)
            end, Passive)
        after _ = tmux_server:close(Full)
        end
    end).

signal_helper(Pid, Identity, Signal) ->
    true = tmux_test_fixture:same_process(Pid, Identity),
    {ok, #{exit_status := 0, cleanup := complete}} = tmux_transport:run(
        <<"/bin/kill">>, [Signal, integer_to_binary(Pid)], #{}),
    ok.

ownership_transfer(Config) ->
    with_server(Config, fun(Server, _) ->
        Parent = self(),
        {NewOwner, NewMonitor} = spawn_monitor(fun() -> receive finish -> ok end end),
        {OldOwner, OldMonitor} = spawn_monitor(fun() ->
            {ok, Op} = tmux_operation:start(Server, raw(<<"wait-for">>, [<<"transfer">>]),
                                           #{deadline_ms => 5000}),
            {ok, _} = tmux_operation:await_started(Op, 900),
            ok = tmux_operation:transfer(Op, NewOwner),
            Parent ! {transferred, self(), Op}
        end),
        try
            Op = receive {transferred, OldOwner, Handle} -> Handle
                 after 900 -> ct:fail(transfer_timeout)
                 end,
            receive {'DOWN', OldMonitor, process, OldOwner, normal} -> ok
            after 900 -> ct:fail(old_owner_alive)
            end,
            {ok, #{owner := NewOwner, outcome := pending}} = tmux_operation:status(Op),
            exit(NewOwner, kill),
            receive {'DOWN', NewMonitor, process, NewOwner, killed} -> ok
            after 900 -> ct:fail(new_owner_alive)
            end,
            {error, #{code := owner_down, outcome := unknown, cleanup := complete}} =
                tmux_operation:await(Op, 900)
        after
            exit(OldOwner, kill), exit(NewOwner, kill)
        end
    end).

endpoint_owner(Config) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    Parent = self(),
    #{socket := Socket} = tmux_test_fixture:info(Fixture),
    Initiator = spawn(fun() ->
        {ok, Server} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        {ok, Op} = tmux_operation:start(Server, raw(<<"wait-for">>, [<<"endpoint">>]),
                                       #{deadline_ms => 5000}),
        {ok, _} = tmux_operation:await_started(Op, 900),
        {ok, #{owner := Owner}} = tmux_server:status(Server),
        {ok, Origin} = tmux_server:origin(Server),
        Parent ! {endpoint, self(), Owner, Origin},
        receive finish -> ok end
    end),
    try
        {Owner, Origin} = receive {endpoint, Initiator, Pid, Ref} -> {Pid, Ref}
                after 900 -> ct:fail(endpoint_start_timeout)
                end,
        Monitor = monitor(process, Owner),
        exit(Initiator, kill),
        receive {'DOWN', Monitor, process, Owner, normal} -> ok
        after 900 -> ct:fail(endpoint_cleanup_timeout)
        end,
        {error, #{code := stale_reference}} = tmux_server:from_origin(Origin),
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"display-message">>, <<"-p">>, <<"#{pid}">>])
    after
        exit(Initiator, kill),
        ok = tmux_test_fixture:ensure_closed(Fixture)
    end.

admission_limits(Config) ->
    with_server(Config, fun(Server, _) ->
        Blocking = raw(<<"wait-for">>, [<<"capacity">>]),
        Active = [begin
            {ok, Op} = tmux_operation:start(Server, Blocking, #{deadline_ms => 5000}),
            {ok, _} = tmux_operation:await_started(Op, 900), Op
        end || _ <- lists:seq(1, 3)],
        Pending = [begin
            {ok, Op} = tmux_operation:start(Server, Blocking, #{deadline_ms => 5000}), Op
        end || _ <- lists:seq(1, 61)],
        {error, #{code := busy}} = tmux_operation:start(Server, Blocking, #{}),
        {ok, #{operations := 64, active_bytes := Used}} = tmux_server:status(Server),
        true = Used =< 8388608,
        lists:foreach(fun(Op) ->
            {ok, cancelled_before_send} = tmux_operation:cancel(Op)
        end, Pending),
        {ok, Large} = tmux_operation:start(Server, Blocking,
            #{stdin => binary:copy(<<1>>, 200000)}),
        {error, #{code := busy}} = tmux_operation:start(Server, Blocking,
            #{stdin => binary:copy(<<2>>, 100000)}),
        {ok, cancelled_before_send} = tmux_operation:cancel(Large),
        lists:foreach(fun(Op) ->
            {ok, cancel_requested} = tmux_operation:cancel(Op),
            {error, #{cleanup := complete}} = tmux_operation:await(Op, 900)
        end, Active),
        {ok, #{operations := 0, command_bytes := 0, active_bytes := 0,
               retained_results := Count}} = tmux_server:status(Server),
        true = Count =< 64,
        {error, #{code := operation_expired}} = tmux_operation:status(hd(Pending))
    end).

result_retention(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        #{executable := Executable, socket := Socket} = tmux_test_fixture:info(Fixture),
        Bytes = binary:copy(<<"x">>, 1048576),
        {ok, #{exit_status := 0}} = tmux_transport:run(Executable,
            [<<"-N">>, <<"-S">>, Socket, <<"load-buffer">>, <<"-b">>, <<"retention">>, <<"-">>],
            #{stdin => Bytes}),
        Operations = [begin
            {ok, Op} = tmux_operation:start(Server,
                raw(<<"save-buffer">>, [<<"-b">>, <<"retention">>, <<"-">>]), #{}),
            {ok, #{stdout := Bytes, cleanup := complete}} = tmux_operation:await(Op, 900), Op
        end || _ <- lists:seq(1, 5)],
        {error, #{code := operation_expired}} = tmux_operation:status(hd(Operations)),
        {ok, #{operations := 0, active_bytes := 0, result_bytes := 4194304,
               retained_results := 4}} = tmux_server:status(Server)
    end).

admission_expiry(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, #{owner := Endpoint}} = tmux_server:status(Server),
        ok = sys:suspend(Endpoint),
        Op = try
            {ok, Handle} = tmux_operation:start(Server,
                raw(<<"set-option">>, [<<"-g">>, <<"@expired">>, <<"ran">>]),
                #{deadline_ms => 20}),
            Timer = erlang:start_timer(30, self(), operation_expired),
            receive {timeout, Timer, operation_expired} -> ok
            after 900 -> ct:fail(deadline_timer)
            end,
            Handle
        after ok = sys:resume(Endpoint)
        end,
        {error, #{outcome := cancelled_before_send, submitted := false, cleanup := complete}} =
            tmux_operation:await(Op, 900),
        {ok, #{exit_status := 1}} = tmux_test_fixture:command(Fixture,
            [<<"show-option">>, <<"-gv">>, <<"@expired">>]),
        {ok, #{operations := 0, command_bytes := 0}} = tmux_server:status(Server)
    end).

registry_restart(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, Origin} = tmux_server:origin(Server),
        {ok, Op} = tmux_operation:start(Server, raw(<<"wait-for">>, [<<"registry">>]),
                                       #{deadline_ms => 5000}),
        {ok, #{phase := sent}} = tmux_operation:await_started(Op, 900),
        ok = supervisor:terminate_child(tmux_sup, tmux_registry),
        {error, #{code := stale_reference}} = tmux_server:from_origin(Origin),
        {ok, _} = supervisor:restart_child(tmux_sup, tmux_registry),
        ok = tmux_server:close(Server),
        {ok, #{phase := closed, operations := 0}} = tmux_server:status(Server),
        {error, #{code := stale_reference}} = tmux_server:from_origin(Origin),
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, New} = tmux_server:open(#{socket_path => Socket,
                                     executable => proplists:get_value(executable, Config)}),
        try
            {ok, NewOrigin} = tmux_server:origin(New),
            true = NewOrigin =/= Origin,
            {ok, New} = tmux_server:from_origin(NewOrigin)
        after ok = tmux_server:close(New)
        end
    end).

with_server(Config, Fun) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, Server} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try Fun(Server, Fixture)
        after ok = tmux_server:close(Server)
        end
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end.
