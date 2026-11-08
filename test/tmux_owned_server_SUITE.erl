-module(tmux_owned_server_SUITE).
-compile(nowarn_missing_spec).
-include_lib("kernel/include/file.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1, owned_lifetime/1,
         namespace_replacement/1, owner_death/1, application_shutdown/1, startup_errors/1]).

%% Outer: public owned lifetime, borrowed close and actual daemon retirement.
all() -> [owned_lifetime, namespace_replacement, owner_death,
          application_shutdown, startup_errors].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    true = is_list(Executable),
    [{executable, unicode:characters_to_binary(Executable)} | Config].
end_per_suite(_) -> ok = application:stop(libtmux_erlang).

owned_lifetime(Config) ->
    {error, #{code := invalid_ownership}} = tmux_server:stop_owned(invalid),
    Executable = proplists:get_value(executable, Config),
    {ok, Server, Ownership} = tmux_server:start_owned(#{executable => Executable}),
    try
        {ok, #{endpoint := #{socket_path := Socket}}} =
            tmux_server:observation_context(Server),
        Directory = filename:dirname(Socket),
        {ok, #file_info{type = directory, mode = Mode}} =
            file:read_link_info(Directory),
        8#700 = Mode band 8#777,
        {ok, Snapshot} = tmux_server:snapshot(Server),
        [] = tmux_snapshot:sessions(Snapshot),
        [] = tmux_snapshot:windows(Snapshot),
        [] = tmux_snapshot:panes(Snapshot),
        {ok, Probe} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"#{pid}">>]),
        {ok, #{stdout := PidLine}} = tmux_server:command(Server, Probe, #{}),
        Pid = binary_to_integer(string:trim(PidLine)),
        {ok, Identity} = tmux_identity:observe(Pid),
        {ok, _} = tmux_session:create(Server,
            #{name => <<"owned">>, launch => #{argv => [<<"cat">>]}}),
        {error, #{code := invalid_ownership}} = tmux_server:stop_owned(Server),
        {ok, #{owner := Endpoint}} = tmux_server:status(Server),
        ok = tmux_server:close(Server),
        Monitor = monitor(process, Endpoint),
        #{retention_timer := Timer} = sys:get_state(Endpoint),
        Endpoint ! {timeout, Timer, expire},
        receive {'DOWN', Monitor, process, Endpoint, normal} -> ok
        after 900 -> ct:fail(endpoint_expiry_timeout)
        end,
        ok = tmux_identity:check(Identity, Pid),
        {ok, Borrowed} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try
            {ok, Fresh} = tmux_server:snapshot(Borrowed),
            [#tmux_model:session{name = <<"owned">>}] = tmux_snapshot:sessions(Fresh)
        after ok = tmux_server:close(Borrowed)
        end,
        ok = tmux_server:stop_owned(Ownership),
        {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid),
        {error, enoent} = file:read_link_info(Socket),
        {error, enoent} = file:read_link_info(Directory),
        ok = tmux_server:stop_owned(Ownership)
    after _ = tmux_server:stop_owned(Ownership)
    end.

namespace_replacement(Config) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Server, Ownership} = tmux_server:start_owned(#{executable => Executable}),
    {Socket, Directory, Pid, Identity} = observation(Server),
    Backup = <<Socket/binary, ".original">>,
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    #{socket := OtherSocket, server_pid := ReplacementPid} = tmux_test_fixture:info(Fixture),
    try
        ok = file:rename(Socket, Backup),
        ok = file:rename(OtherSocket, Socket),
        {error, #{code := cleanup_incomplete, process_cleanup := complete,
                  endpoint_cleanup := complete, namespace_cleanup := socket_changed}} =
            tmux_server:stop_owned(Ownership),
        {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid),
        {ok, Replacement} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try
            {ok, Probe} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"#{pid}">>]),
            Expected = <<(integer_to_binary(ReplacementPid))/binary, $\n>>,
            {ok, #{stdout := Expected}} = tmux_server:command(Replacement, Probe, #{}),
            {ok, _} = tmux_session:create(Replacement,
                #{name => <<"replacement-survives">>, launch => #{argv => [<<"cat">>]}})
        after ok = tmux_server:close(Replacement)
        end
    after
        restore(Socket, OtherSocket),
        restore(Backup, Socket),
        ok = tmux_test_fixture:ensure_closed(Fixture),
        ok = tmux_server:stop_owned(Ownership)
    end,
    {error, enoent} = file:read_link_info(Directory),
    {ok, Second, SecondOwnership} = tmux_server:start_owned(#{executable => Executable}),
    {_, SecondDirectory, SecondPid, SecondIdentity} = observation(Second),
    SavedDirectory = <<SecondDirectory/binary, ".original">>,
    Marker = <<SecondDirectory/binary, "/preserve">>,
    try
        ok = file:rename(SecondDirectory, SavedDirectory),
        ok = file:make_dir(SecondDirectory),
        ok = file:change_mode(SecondDirectory, 8#700),
        ok = file:write_file(Marker, <<"replacement">>),
        {error, #{code := cleanup_incomplete, process_cleanup := complete,
                  endpoint_cleanup := complete, namespace_cleanup := directory_changed}} =
            tmux_server:stop_owned(SecondOwnership),
        {ok, <<"replacement">>} = file:read_file(Marker),
        {error, #{code := stale_server}} = tmux_identity:check(SecondIdentity, SecondPid)
    after
        ok = file:delete(Marker),
        ok = file:del_dir(SecondDirectory),
        ok = file:rename(SavedDirectory, SecondDirectory),
        ok = tmux_server:stop_owned(SecondOwnership)
    end.

owner_death(Config) ->
    Parent = self(),
    Executable = proplists:get_value(executable, Config),
    {Owner, OwnerMonitor} = spawn_monitor(fun() ->
        {ok, Server, {owned_server, Controller, _}} =
            tmux_server:start_owned(#{executable => Executable}),
        {ok, _} = tmux_session:create(Server,
            #{name => <<"owner-death">>, launch => #{argv => [<<"cat">>]}}),
        Parent ! {owned_ready, self(), Controller, observation(Server)},
        receive finish -> ok end
    end),
    try
        receive
            {owned_ready, Owner, Controller, {Socket, Directory, Pid, Identity}} ->
                Monitor = monitor(process, Controller),
                exit(Owner, kill),
                receive {'DOWN', Monitor, process, Controller, normal} -> ok
                after 900 -> ct:fail(owned_retirement_timeout)
                end,
                {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid),
                {error, enoent} = file:read_link_info(Socket),
                {error, enoent} = file:read_link_info(Directory)
        after 900 -> ct:fail(owned_start_timeout)
        end,
        receive {'DOWN', OwnerMonitor, process, Owner, killed} -> ok
        after 900 -> ct:fail(initiator_alive)
        end
    after exit(Owner, kill)
    end.

application_shutdown(Config) ->
    {ok, Server, Ownership} = tmux_server:start_owned(
        #{executable => proplists:get_value(executable, Config)}),
    {Socket, Directory, Pid, Identity} = observation(Server),
    {ok, _} = tmux_session:create(Server,
        #{name => <<"shutdown">>, launch => #{argv => [<<"cat">>]}}),
    try
        ok = application:stop(libtmux_erlang),
        {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid),
        {error, enoent} = file:read_link_info(Socket),
        {error, enoent} = file:read_link_info(Directory),
        {error, #{code := ownership_expired}} = tmux_server:stop_owned(Ownership)
    after {ok, _} = application:ensure_all_started(libtmux_erlang)
    end,
    {ok, Unclean, Token} = tmux_server:start_owned(
        #{executable => proplists:get_value(executable, Config)}),
    {_, UncleanDirectory, UncleanPid, UncleanIdentity} = observation(Unclean),
    Marker = <<UncleanDirectory/binary, "/preserve">>,
    ok = file:write_file(Marker, <<"retain">>),
    {error, #{reports := Reports}} = tmux_owned_server:prepare_stop(),
    [#{recovery_report := {ok, Report}} | _] = Reports,
    RecoveryDirectory = filename:dirname(Report),
    try
        {ok, #file_info{mode = RecoveryMode}} = file:read_link_info(RecoveryDirectory),
        8#700 = RecoveryMode band 8#777,
        {ok, #file_info{mode = ReportMode}} = file:read_link_info(Report),
        8#600 = ReportMode band 8#777,
        {ok, Document} = file:read_file(Report),
        #{<<"automatic_recovery">> := false, <<"process_cleanup">> := true,
          <<"directory">> := UncleanDirectory} = json:decode(Document),
        ok = application:stop(libtmux_erlang),
        {ok, <<"retain">>} = file:read_file(Marker),
        {ok, Document} = file:read_file(Report),
        {error, #{code := stale_server}} = tmux_identity:check(UncleanIdentity, UncleanPid),
        {error, #{code := ownership_expired}} = tmux_server:stop_owned(Token)
    after
        {ok, _} = application:ensure_all_started(libtmux_erlang),
        ok = file:delete(Marker),
        ok = file:del_dir(UncleanDirectory),
        ok = file:delete(Report),
        ok = file:del_dir(RecoveryDirectory)
    end.

startup_errors(Config) ->
    Executable = proplists:get_value(executable, Config),
    {error, #{code := invalid_owned_options}} = tmux_server:start_owned(
        #{executable => Executable, socket_path => <<"/ignored">>}),
    {error, #{code := invalid_owned_options}} = tmux_server:start_owned(
        #{executable => Executable, startup_timeout_ms => 0}),
    {error, #{code := invalid_executable}} = tmux_server:start_owned(#{executable => <<"tmux">>}),
    {error, #{cleanup := complete}} = tmux_server:start_owned(
        #{executable => <<"/no-such-owned-tmux">>}),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    Directory = <<"/tmp/ltm-owned-fault-", Suffix/binary>>,
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    Fake = <<Directory/binary, "/tmux">>,
    Script = iolist_to_binary([
        <<"#!/usr/bin/python3\nimport json,os,pathlib,signal,subprocess,sys\nreal=">>,
        json:encode(Executable), <<"\nroot=pathlib.Path(__file__).parent\n",
        "args=sys.argv[1:]\nsock=args[args.index('-S')+1]\n",
        "(root/'socket').write_text(sock)\n",
        "if '-N' in args:\n",
        " result=subprocess.run([real,*args],capture_output=True,check=True)\n",
        " pid=int(result.stdout.split(bytes([9]))[0])\n",
        " stat=pathlib.Path('/proc/'+str(pid)+'/stat').read_text()\n",
        " start=stat.rsplit(') ',1)[1].split()[19]\n",
        " (root/'probe').write_text(json.dumps({'pid':pid,'start':start}))\n",
        " if (root/'mode').read_text()=='directory':\n",
        "  parent=str(pathlib.Path(sock).parent)\n",
        "  os.rename(parent,parent+'.original')\n  os.symlink(parent+'.original',parent)\n",
        "  os.write(1,result.stdout)\n",
        " else: os.write(1,b'0'+bytes([9])+b'3.3'+bytes([10]))\n",
        "else:\n mode=(root/'mode').read_text()\n",
        " if mode=='namespace':\n  pathlib.Path(sock).write_bytes(b'preserve')\n",
        "  os.write(1,b'123'+bytes([9])+b'3.3'+bytes([10]))\n  signal.pause()\n",
        " if mode=='partial':\n  os.write(1,b'123')\n  sys.exit(0)\n",
        " if mode=='timeout': signal.pause()\n",
        " os.execv(real,[real,*args])\n">>]),
    ok = file:write_file(Fake, Script),
    ok = file:change_mode(Fake, 8#700),
    try
        lists:foreach(fun(Mode) ->
            ok = file:write_file(<<Directory/binary, "/mode">>, Mode),
            Options = #{executable => Fake, startup_timeout_ms => 400},
            {error, #{cleanup := complete} = Error} = tmux_server:start_owned(Options),
            case Mode of
                <<"binding">> -> #{code := startup_binding_changed} = Error;
                <<"timeout">> -> #{code := startup_timeout} = Error;
                <<"partial">> -> ok
            end,
            {ok, Socket} = file:read_file(<<Directory/binary, "/socket">>),
            {error, enoent} = file:read_link_info(filename:dirname(Socket))
        end, [<<"binding">>, <<"partial">>, <<"timeout">>]),
        {ok, ProbeData} = file:read_file(<<Directory/binary, "/probe">>),
        #{<<"pid">> := Pid, <<"start">> := Start} = json:decode(ProbeData),
        false = tmux_test_fixture:same_process(Pid, Start),
        ok = file:write_file(<<Directory/binary, "/mode">>, <<"directory">>),
        Changed = tmux_server:start_owned(#{executable => Fake}),
        {ok, ChangedSocket} = file:read_file(<<Directory/binary, "/socket">>),
        ChangedDirectory = filename:dirname(ChangedSocket),
        try
            {error, #{code := cleanup_incomplete, namespace_cleanup := directory_changed}} = Changed,
            {ok, #file_info{type = symlink}} = file:read_link_info(ChangedDirectory)
        after
            ok = file:delete(ChangedDirectory),
            ok = file:rename(<<ChangedDirectory/binary, ".original">>, ChangedDirectory),
            ChangedToken = case Changed of
                {ok, _, Ownership} -> Ownership;
                {error, #{ownership := Ownership}} -> Ownership
            end,
            ok = tmux_server:stop_owned(ChangedToken)
        end,
        ok = file:write_file(<<Directory/binary, "/mode">>, <<"namespace">>),
        {error, #{code := cleanup_incomplete, ownership := Token,
                  process_cleanup := complete, resources := #{socket := UnknownSocket}}} =
            tmux_server:start_owned(#{executable => Fake}),
        try
            {ok, <<"preserve">>} = file:read_file(UnknownSocket),
            {error, #{namespace_cleanup := socket_unverified}} = tmux_server:stop_owned(Token),
            ok = file:delete(UnknownSocket),
            ok = tmux_server:stop_owned(Token),
            {error, enoent} = file:read_link_info(filename:dirname(UnknownSocket))
        after _ = tmux_server:stop_owned(Token)
        end
    after
        ok = file:del_dir_r(Directory)
    end.

observation(Server) ->
    {ok, #{endpoint := #{socket_path := Socket}}} = tmux_server:observation_context(Server),
    {ok, Command} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"#{pid}">>]),
    {ok, #{stdout := Raw}} = tmux_server:command(Server, Command, #{}),
    Pid = binary_to_integer(string:trim(Raw)),
    {ok, Identity} = tmux_identity:observe(Pid),
    {Socket, filename:dirname(Socket), Pid, Identity}.

restore(Source, Target) ->
    case file:read_link_info(Source) of
        {error, enoent} -> ok;
        {ok, _} -> ok = file:rename(Source, Target)
    end.
