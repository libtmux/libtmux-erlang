-module(tmux_key_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         registration/1, terminal_dispatch/1, terminal_failure/1, terminal_cancel/1]).

%% Bound for each terminal event; every wait ends on its event, not on this bound.
-define(WAIT_MS, 2000).

%% Outer: real bindings and terminal-client retirement need an isolated daemon.
%% erlexec, a test-profile dependency, supplies the PTY for the attached client.
all() -> [registration, terminal_dispatch, terminal_failure, terminal_cancel].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    {ok, _} = application:ensure_all_started(erlexec),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) ->
    ok = application:stop(erlexec),
    ok = application:stop(libtmux_erlang).

registration(Config) ->
    with_server(Config, fun(Server, _) ->
        {ok, Show} = tmux_command:raw(<<"display-message">>, [<<"bound">>]),
        Table = <<"owned table;$HOME#{session_id}">>,
        Options = #{table => Table, repeat => true, note => <<"literal $HOME; note">>},
        {ok, _} = tmux_key:bind(Server, <<";">>, Show, Options),
        %% 3.7c suppresses a single-entry view without an attached client.
        lists:foreach(fun(Key) ->
            {ok, _} = tmux_key:bind(Server, Key, Show,
                #{table => Table, note => <<"sentinel note">>})
        end, [<<"y">>, <<"z">>]),
        {ok, Listing} = tmux_key:listing(Server, #{table => Table}),
        true = binary:match(Listing, <<"display-message">>) =/= nomatch,
        true = binary:match(Listing, <<"-r ">>) =/= nomatch,
        {ok, Filtered} = tmux_key:listing(Server, #{table => Table, key => <<";">>}),
        {ok, Version} = tmux_server:version(Server),
        case Version of
            #{major := 3, minor := 7, patch := <<"c">>} -> <<>> = Filtered;
            _ -> true = binary:match(Filtered, <<"display-message">>) =/= nomatch
        end,
        {error, #{code := command_error}} =
            tmux_key:listing(Server, #{table => Table, key => <<"not-a-key">>}),
        {ok, Notes} = notes(Server, Table),
        true = lists:any(fun(Value) -> binary:match(Notes, Value) =/= nomatch end,
            [<<"literal $HOME; note">>, <<"literal \\$HOME; note">>]),
        {ok, Bad} = tmux_command:raw(<<"not-a-tmux-command">>, []),
        {error, #{code := command_error}} = tmux_key:bind(Server, <<";">>, Bad,
            #{table => Table}),
        {ok, Listing} = tmux_key:listing(Server, #{table => Table}),
        {error, #{code := command_error}} = tmux_key:bind(Server, <<"not-a-key">>, Show),
        {ok, _} = tmux_key:bind(Server, <<";">>, Show, #{table => Table}),
        {ok, Replaced} = tmux_key:listing(Server, #{table => Table}),
        nomatch = binary:match(Replaced, <<"-r ">>),
        {ok, RemainingNotes} = notes(Server, Table),
        nomatch = binary:match(RemainingNotes, <<"HOME">>),
        true = binary:match(RemainingNotes, <<"sentinel note">>) =/= nomatch,
        {ok, _} = tmux_key:unbind(Server, <<"q">>, #{table => Table}),
        {ok, _} = tmux_key:unbind(Server, <<";">>, #{table => Table}),
        {ok, _} = tmux_key:unbind(Server, <<"y">>, #{table => Table}),
        {ok, _} = tmux_key:unbind(Server, <<"z">>, #{table => Table}),
        {error, #{code := command_error}} = tmux_key:listing(Server, #{table => Table}),
        {ok, _} = tmux_key:bind(Server, <<"x">>, Show, #{table => Table}),
        {ok, _} = tmux_key:clear_table(Server, Table),
        {error, #{code := command_error}} = tmux_key:clear_table(Server, Table),
        {ok, Prefix} = tmux_key:listing(Server, #{table => <<"prefix">>}),
        true = byte_size(Prefix) > 0,
        {ok, _} = tmux_key:bind(Server, <<"F12">>, Show),
        {ok, _} = tmux_key:unbind(Server, <<"F12">>),
        ok = tmux_server:close(Server),
        {error, #{code := server_closed}} = tmux_key:bind(Server, <<"x">>, Show)
    end).

terminal_dispatch(Config) ->
    with_terminal(Config, fun(Server, Session, Driver) ->
        {ok, #{binding_signal := true, client_exit := 0}} = drive(Driver, <<"x">>),
        {ok, Bytes} = tmux_option:get(Session, <<"@bound">>, #{}),
        Bytes = bound_bytes(),
        {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
        0 = tmux_model:get(attached_count, Current)
    end).

terminal_failure(Config) ->
    with_terminal(Config, fun(Server, Session, Driver) ->
        %% An unbound key must fail the completion proof and retire the client.
        {error, #{reason := {signal_timeout, done}, terminal_tail := Tail}} =
            drive(Driver, <<"y">>),
        true = is_binary(Tail),
        none = tmux_option:get(Session, <<"@bound">>, #{}),
        {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
        0 = tmux_model:get(attached_count, Current)
    end).

terminal_cancel(Config) ->
    with_terminal(Config, fun(Server, Session, Driver) ->
        {ok, Wait} = tmux_command:wait_for(<<"terminal-ready">>, wait),
        {ok, Attached} = tmux_operation:start(Server, Wait, #{}),
        try
            %% The driver's readiness channel stays unsignalled after attachment.
            {Pid, Monitor} = spawn_monitor(fun() ->
                exit({driven, drive(Driver#{ready := <<"never-signalled">>}, <<"x">>)})
            end),
            {ok, #{cleanup := complete}} = tmux_operation:await(Attached, ?WAIT_MS),
            Pid ! cancel,
            receive
                {'DOWN', Monitor, process, Pid, {driven, {error, #{reason := cancelled}}}} -> ok
            after ?WAIT_MS -> exit(Pid, kill), ct:fail(driver_cancel_timeout)
            end,
            none = tmux_option:get(Session, <<"@bound">>, #{}),
            {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
            0 = tmux_model:get(attached_count, Current)
        after
            {ok, _} = tmux_operation:cancel(Attached),
            {ok, #{cleanup := complete}} = tmux_operation:await(Attached, 900)
        end
    end).

notes(Server, Table) ->
    {ok, Command} = tmux_command:raw(<<"list-keys">>, [<<"-N">>, <<"-T">>, Table]),
    maybe
        {ok, #{stdout := Output}} ?= tmux_server:command(Server, Command, #{}),
        {ok, Output}
    end.

bound_bytes() ->
    <<"$HOME ${USER} ~root #{session_id} #[red];\n  #end\n",
      (list_to_binary(lists:seq(1, 255)))/binary>>.

%% Attach one owned client on a 24x80 PTY, press Keys once the attach hook has
%% signalled, wait for the binding's signal, detach the client and require a
%% normal exit. Each wait ends on an event or at its deadline. Every process
%% started here is proven gone before this returns. A failure carries the tail
%% of the terminal output. A `cancel` message ends a wait for a signal.
drive(Driver, Keys) when byte_size(Keys) > 0, byte_size(Keys) =< 4096 ->
    with_os_process(fun() -> signal_wait(Driver, ready) end, fun(Ready) ->
        with_os_process(fun() -> attach(Driver) end, fun(Client) ->
            try
                ok = signalled(Ready, Client, ready),
                with_os_process(fun() -> signal_wait(Driver, done) end, fun(Done) ->
                    ok = exec:send(Client, Keys),
                    ok = signalled(Done, Client, done)
                end),
                {ok, #{exit_status := 0}} = detach(Driver, Client),
                ok = client_exit(Client),
                true = byte_size(terminal_output(Client)) =< 1048576,
                {ok, #{key_bytes => byte_size(Keys), client_exit => 0,
                       binding_signal => true}}
            catch error:Reason ->
                Output = terminal_output(Client),
                Tail = binary:part(Output, max(0, byte_size(Output) - 1024),
                                   min(1024, byte_size(Output))),
                {error, #{reason => Reason, terminal_tail => Tail}}
            end
        end)
    end).

with_os_process(Start, Fun) ->
    {OsPid, Identity} = Start(),
    try Fun(OsPid)
    after reap(OsPid, Identity)
    end.

environment() -> {env, [{"TERM", "xterm-256color"}, {"TMUX", false}, {"TMUX_PANE", false}]}.

base(#{executable := Executable, socket := Socket}) ->
    [Executable, <<"-N">>, <<"-S">>, Socket].

signal_wait(#{} = Driver, Channel) ->
    Name = maps:get(Channel, Driver),
    started(exec:run(base(Driver) ++ [<<"wait-for">>, Name],
                     [monitor, {kill_timeout, 1}, environment()])).

attach(#{session := Session} = Driver) ->
    started(exec:run(base(Driver) ++ [<<"-u">>, <<"attach-session">>, <<"-E">>,
                                      <<"-t">>, Session],
                     [stdin, stdout, {stderr, stdout}, pty, {winsz, {24, 80}}, monitor,
                      {kill_timeout, 1}, environment()])).

started({ok, _, OsPid}) -> {OsPid, identity(OsPid)}.

identity(OsPid) ->
    try tmux_test_fixture:process_identity(OsPid)
    catch error:{badmatch, {error, enoent}} -> gone
    end.

%% A signal client exits zero once its channel is signalled.
signalled(Waiter, Client, What) ->
    receive
        {'DOWN', Waiter, process, _, normal} -> ok;
        {'DOWN', Waiter, process, _, Status} -> error({signal_command_failed, What, Status});
        {'DOWN', Client, process, _, Status} -> error({client_exited_early, What, Status});
        cancel -> error(cancelled)
    after ?WAIT_MS -> error({signal_timeout, What})
    end.

detach(Driver, Client) ->
    {ok, #{exit_status := 0, stdout := Listing}} = tmux_transport:run(
        maps:get(executable, Driver), tl(base(Driver)) ++ [<<"list-clients">>, <<"-F">>,
            <<"#{client_pid} #{client_name}">>], #{timeout_ms => ?WAIT_MS}),
    Prefix = <<(integer_to_binary(Client))/binary, " ">>,
    [Name] = [Rest || <<Head:(byte_size(Prefix))/binary, Rest/binary>> <-
                          binary:split(Listing, <<"\n">>, [global]), Head =:= Prefix],
    tmux_transport:run(maps:get(executable, Driver), tl(base(Driver)) ++
        [<<"detach-client">>, <<"-t">>, Name], #{timeout_ms => ?WAIT_MS, max_stdout => 0}).

client_exit(Client) ->
    receive {'DOWN', Client, process, _, normal} -> ok
    after ?WAIT_MS -> error(client_exit_timeout)
    end.

%% Everything the client wrote to its terminal so far.
terminal_output(Client) ->
    receive {stdout, Client, Bytes} -> <<Bytes/binary, (terminal_output(Client))/binary>>
    after 0 -> <<>>
    end.

%% Stop the OS process if it still runs, then prove it is gone.
reap(OsPid, Identity) ->
    case exec:pid(OsPid) of
        Pid when is_pid(Pid) ->
            ok = exec:stop(OsPid),
            receive {'DOWN', OsPid, process, Pid, _} -> ok
            after 6000 -> error({os_process_survived, OsPid})
            end;
        _ -> ok
    end,
    false = tmux_test_fixture:same_process(OsPid, Identity).

with_terminal(Config, Fun) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"keys">>, launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        [Pane] = tmux_snapshot:panes(Snapshot),
        ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane)),
        Id = tmux_model:get(id, Session),
        Ready = <<"terminal-ready">>, Done = <<"key-applied">>,
        {ok, ReadySignal} = tmux_command:wait_for(Ready, signal),
        {ok, _} = tmux_hook:set(Session, {<<"client-attached">>, 0}, ReadySignal),
        {ok, Mark} = tmux_command:raw(<<"set-option">>,
            [<<"-t">>, Id, <<"@bound">>, bound_bytes()]),
        {ok, DoneSignal} = tmux_command:wait_for(Done, signal),
        Table = <<"owned table;$HOME#{session_id}">>,
        {ok, _} = tmux_key:bind(Server, <<"x">>, [Mark, DoneSignal], #{table => Table}),
        {ok, _} = tmux_option:set(Session, <<"key-table">>, Table),
        {ok, Table} = tmux_option:get(Session, <<"key-table">>, #{}),
        #{executable := Exe, socket := Socket} = tmux_test_fixture:info(Fixture),
        Fun(Server, Session, #{executable => Exe, socket => Socket, session => Id,
                               ready => Ready, done => Done})
    end).

with_server(Config, Fun) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), Fun).
