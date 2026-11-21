-module(check_daemon_floor).
-mode(compile).
-moduledoc """
Check that opening a private older tmux daemon refuses before changing it.
Compile the test profile and pass both binaries and their expected versions.
""".
-export([main/1]).

-define(SESSION, <<"floor-check">>).

-spec main([string()]) -> ok.
main([DaemonPath, ClientPath, DaemonRelease, ClientRelease]) ->
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Build = filename:join(Root, "_build/test"),
    ok = code:add_pathsa([filename:join(Build, Path) || Path <-
        ["lib/libtmux_erlang/ebin", "extras/test", "extras/scripts"]]),
    Release = release(DaemonRelease),
    ClientVersion = release(ClientRelease),
    Receipt = filename:join([Root, "_build/checks",
        "daemon-floor-" ++ DaemonRelease ++ "-client-" ++ ClientRelease ++ ".json"]),
    ok = filelib:ensure_dir(Receipt),
    ok = file:write_file(Receipt, json:format(#{result => 'UNVERIFIED',
        daemon_version => Release, client_version => ClientVersion})),
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Daemon = unicode:characters_to_binary(DaemonPath),
    Client = unicode:characters_to_binary(ClientPath),
    ClientVersion = client_version(Client),
    {Micros, Result} = timer:tc(fun() ->
        tmux_test_sandbox:with(fun() -> check(Daemon, Client, Release, ClientVersion) end)
    end),
    Output = json:format(Result#{seconds => Micros / 1000000}),
    ok = file:write_file(Receipt, Output),
    io:put_chars(Output).

release(Name) ->
    Value = list_to_binary(Name),
    {ok, Version} = tmux_version:parse(<<"tmux ", Value/binary>>),
    Value = tmux_version:format(Version).

check(Daemon, Client, Release, ClientVersion) ->
    {ok, Fixture} = tmux_test_fixture:start(Daemon, #{seed_session => ?SESSION}),
    #{socket := Socket, server_pid := Pid, server_identity := Identity, directory := Directory} =
        tmux_test_fixture:info(Fixture),
    Result = try
        Before = observe(Daemon, Socket),
        #{release := Release, server_pid := Pid, pane_pid := Pane,
          sessions := <<"$0|floor-check|1|0\n">>, clients := <<>>} = Before,
        PaneIdentity = tmux_test_fixture:process_identity(Pane),
        ok = tmux_test_fixture:track_process(Fixture, Pane),
        Error = case tmux_server:open(#{executable => Client, socket_path => Socket}) of
            {error, Detail} -> Detail;
            {ok, Server} ->
                ok = tmux_server:close(Server),
                error(opened_below_floor)
        end,
        Refusal = checked_refusal(Error, Release, ClientVersion, Pid),
        Before = observe(Daemon, Socket),
        true = tmux_test_fixture:same_process(Pid, Identity),
        true = tmux_test_fixture:same_process(Pane, PaneIdentity),
        #{result => 'PASS', client_version => ClientVersion, daemon_version => Release,
          refusal => Refusal, snapshot => Before, unchanged => true}
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end,
    false = filelib:is_dir(Directory),
    Result#{cleanup => complete}.

observe(Executable, Socket) ->
    [Server, Version, Pane] = binary:split(string:trim(query(Executable, Socket,
        [<<"display-message">>, <<"-p">>, <<"-t">>, ?SESSION,
         <<"#{pid}\t#{version}\t#{pane_pid}">>])), <<"\t">>, [global]),
    #{server_pid => binary_to_integer(Server), release => Version, pane_pid => binary_to_integer(Pane),
      sessions => query(Executable, Socket, [<<"list-sessions">>, <<"-F">>,
        <<"#{session_id}|#{session_name}|#{session_windows}|#{session_attached}">>]),
      clients => query(Executable, Socket, [<<"list-clients">>, <<"-F">>, <<"#{client_pid}">>])}.

query(Executable, Socket, Arguments) ->
    %% The older clients used to inspect the fixture predate -N.
    stdout(Executable, [<<"-S">>, Socket | Arguments]).

client_version(Executable) ->
    <<"tmux ", Version/binary>> = string:trim(stdout(Executable, [<<"-V">>])),
    Version.

stdout(Executable, Arguments) ->
    {ok, #{exit_status := 0, stdout := Output}} = tmux_transport:run(Executable, Arguments,
        #{timeout_ms => 900, max_stdout => 512}),
    Output.

checked_refusal(#{code := unsupported_tmux_version, component := client,
                  required := <<"3.3a">>, found := Version}, Version, Version, _) ->
    unsupported_client;
checked_refusal(#{code := unsupported_tmux_version, component := daemon,
                  required := <<"3.3a">>, found := Version}, Version, <<"3.3a">>, _) ->
    unsupported_daemon;
checked_refusal(#{code := Code, stdout := <<>>,
                  stderr := <<"server version is too old for client\n">>, cleanup := complete},
                <<"3.0a">>, <<"3.3a">>, _)
  when Code =:= timeout; Code =:= command_error ->
    incompatible_client_protocol;
checked_refusal(#{code := timeout, stdout := Output, stderr := <<>>, cleanup := complete},
                <<"3.1c">>, <<"3.3a">>, Pid) ->
    Output = <<(integer_to_binary(Pid))/binary, "\t3.1c\n">>,
    older_identity_client_timeout;
checked_refusal(Error, Version, ClientVersion, _) ->
    error({unexpected_floor_refusal, ClientVersion, Version, Error}).
