-module(tmux_key_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         registration/1, terminal_dispatch/1, terminal_failure/1, terminal_cancel/1]).

%% Outer: real bindings and terminal-client retirement need an isolated daemon.
all() -> [registration, terminal_dispatch, terminal_failure, terminal_cancel].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

registration(Config) ->
    with_server(Config, fun(Server, _) ->
        {ok, Show} = tmux_command:raw(<<"display-message">>, [<<"bound">>]),
        Table = <<"owned table;$HOME#{session_id}">>,
        Options = #{table => Table, repeat => true, note => <<"literal $HOME; note">>},
        {ok, _} = tmux_key:bind(Server, <<";">>, Show, Options),
        {ok, Listing} = tmux_key:listing(Server, #{table => Table, key => <<";">>}),
        true = binary:match(Listing, Table) =/= nomatch,
        true = binary:match(Listing, <<"-r ">>) =/= nomatch,
        {ok, Notes} = notes(Server, Table),
        true = binary:match(Notes, <<"literal $HOME; note">>) =/= nomatch,
        {ok, Bad} = tmux_command:raw(<<"not-a-tmux-command">>, []),
        {error, #{code := command_error}} = tmux_key:bind(Server, <<";">>, Bad,
            #{table => Table}),
        {ok, Listing} = tmux_key:listing(Server, #{table => Table, key => <<";">>}),
        {error, #{code := command_error}} = tmux_key:bind(Server, <<"not-a-key">>, Show),
        {ok, _} = tmux_key:bind(Server, <<";">>, Show, #{table => Table}),
        {ok, Replaced} = tmux_key:listing(Server, #{table => Table}),
        nomatch = binary:match(Replaced, <<"-r ">>),
        {ok, <<>>} = notes(Server, Table),
        {ok, _} = tmux_key:unbind(Server, <<"y">>, #{table => Table}),
        {ok, _} = tmux_key:unbind(Server, <<";">>, #{table => Table}),
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
        {ok, #{exit_status := 0, stdout := Output, cleanup := complete}} =
            run_driver(Driver, <<"78">>),
        #{<<"binding_signal">> := true, <<"client_exit">> := 0} = json:decode(Output),
        {ok, Bytes} = tmux_option:get(Session, <<"@bound">>, #{}),
        Bytes = bound_bytes(),
        {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
        0 = tmux_model:get(attached_count, Current)
    end).

terminal_failure(Config) ->
    with_terminal(Config, fun(Server, Session, Driver) ->
        %% An unbound key must fail the completion proof and retire the client.
        {ok, #{exit_status := 1, cleanup := complete}} = run_driver(Driver, <<"79">>),
        none = tmux_option:get(Session, <<"@bound">>, #{}),
        {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
        0 = tmux_model:get(attached_count, Current)
    end).

terminal_cancel(Config) ->
    with_terminal(Config, fun(Server, Session, [Script, Exe, Socket, Id, _, Done]) ->
        {ok, Wait} = tmux_command:wait_for(<<"terminal-ready">>, wait),
        {ok, Attached} = tmux_operation:start(Server, Wait, #{}),
        try
            %% The driver's readiness channel stays unsignalled after attachment.
            {ok, Handle} = tmux_transport:start(<<"/usr/bin/python3">>,
                [Script, Exe, Socket, Id, <<"never-signalled">>, Done, <<"78">>],
                #{timeout_ms => 3000, max_stdout => 4096, max_stderr => 8192}),
            try
                {ok, #{cleanup := complete}} = tmux_operation:await(Attached, 900),
                {ok, _} = tmux_transport:cancel(Handle),
                {error, #{code := cancelled, cleanup := complete}} =
                    tmux_transport:await(Handle, 900),
                none = tmux_option:get(Session, <<"@bound">>, #{}),
                {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
                0 = tmux_model:get(attached_count, Current)
            after ok = tmux_transport:close(Handle)
            end
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

run_driver(Arguments, HexKeys) ->
    tmux_transport:run(<<"/usr/bin/python3">>, Arguments ++ [HexKeys],
        #{timeout_ms => 3000, max_stdout => 4096, max_stderr => 8192}).

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
        Table = <<"owned-keys">>,
        {ok, _} = tmux_key:bind(Server, <<"x">>, [Mark, DoneSignal], #{table => Table}),
        {ok, _} = tmux_option:set(Session, <<"key-table">>, Table),
        #{executable := Exe, socket := Socket} = tmux_test_fixture:info(Fixture),
        Script = list_to_binary(filename:join(proplists:get_value(data_dir, Config),
            "client.py")),
        Fun(Server, Session, [Script, Exe, Socket, Id, Ready, Done])
    end).

with_server(Config, Fun) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), Fun).
