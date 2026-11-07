-module(tmux_test_fixture).
-compile(nowarn_missing_spec).
-behaviour(gen_server).
-export([start/1, info/1, command/2, start_command/2, close/1, ensure_closed/1,
         process_identity/1, same_process/2, track_process/2, with_server/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start(Executable) -> gen_server:start(?MODULE, {self(), Executable}, []).
info(Fixture) -> gen_server:call(Fixture, info, 900).
close(Fixture) -> gen_server:call(Fixture, close, 1000).
track_process(Fixture, Pid) -> gen_server:call(Fixture, {track_process, Pid}, 900).

with_server(Executable, Function) ->
    {ok, Fixture} = start(Executable),
    try
        #{socket := Socket} = info(Fixture),
        {ok, Server} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try Function(Server, Fixture)
        after ok = tmux_server:close(Server)
        end
    after ok = ensure_closed(Fixture)
    end.

ensure_closed(Fixture) ->
    case is_process_alive(Fixture) of
        true -> close(Fixture);
        false -> ok
    end.

command(Fixture, Arguments) ->
    #{executable := Executable, socket := Socket} = info(Fixture),
    tmux_transport:run(Executable, [<<"-N">>, <<"-S">>, Socket | Arguments], #{}).

start_command(Fixture, Arguments) ->
    #{executable := Executable, socket := Socket} = info(Fixture),
    tmux_transport:start(Executable, [<<"-N">>, <<"-S">>, Socket | Arguments],
                         #{timeout_ms => 5000}).

init({Owner, Executable}) ->
    Monitor = monitor(process, Owner),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    Directory = binary_to_list(<<"/tmp/ltm-erlang-", Suffix/binary>>),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    try create(Executable, Directory) of
        State -> {ok, State#{owner_monitor => Monitor, cleaned => false,
                            tracked_processes => #{}}}
    catch Class:Reason:Stack ->
        ok = file:del_dir_r(Directory),
        erlang:raise(Class, Reason, Stack)
    end.

create(Executable, Directory) ->
    Socket = list_to_binary(filename:join(Directory, "s")),
    Script = filename:join(filename:dirname(code:which(?MODULE)), "tmux_fixture_watch.py"),
    Watcher = open_port({spawn_executable, "/usr/bin/python3"},
        [binary, {line, 64}, exit_status, use_stdio, {args, [Script, Socket]}]),
    try
        watch_line(Watcher, <<"armed">>),
        {ok, Handle} = tmux_transport:start(Executable,
            [<<"-D">>, <<"-S">>, Socket, <<"-f">>, <<"/dev/null">>],
            #{timeout_ms => 30000, max_stdout => 0}),
        try
            {ok, #{child_pid := Pid, helper_pid := HelperPid}} =
                tmux_transport:await_started(Handle, 900),
            watch_line(Watcher, <<"ready">>),
            receive {Watcher, {exit_status, 0}} -> ok
            after 900 -> error(watcher_exit_timeout)
            end,
            #{executable => Executable, socket => Socket, directory => Directory,
              transport => Handle, server_pid => Pid, server_identity => process_identity(Pid),
              helper_pid => HelperPid, helper_identity => process_identity(HelperPid)}
        catch Class:Reason:Stack ->
            _ = tmux_transport:close(Handle),
            erlang:raise(Class, Reason, Stack)
        end
    after
        case erlang:port_info(Watcher) of
            undefined -> ok;
            _ ->
                true = erlang:port_command(Watcher, <<"Q">>),
                receive {Watcher, {exit_status, _}} -> ok
                after 900 -> error(watcher_exit_timeout)
                end
        end
    end.

watch_line(Watcher, Line) ->
    receive
        {Watcher, {data, {eol, Line}}} -> ok;
        {Watcher, {exit_status, Status}} -> error({watcher_exit, Status})
    after 900 -> error(watcher_event_timeout)
    end.

handle_call(info, _From, State) -> {reply, maps:without([transport, owner_monitor], State), State};
handle_call({track_process, Pid}, _From, State) ->
    Identity = process_identity(Pid),
    Tracked = maps:get(tracked_processes, State),
    {reply, ok, State#{tracked_processes => Tracked#{Pid => Identity}}};
handle_call(close, _From, State) ->
    Cleaned = cleanup(State),
    {stop, normal, ok, Cleaned}.

handle_cast(_, State) -> {noreply, State}.

handle_info({'DOWN', Monitor, process, _, _}, #{owner_monitor := Monitor} = State) ->
    {stop, normal, cleanup(State)};
handle_info(_, State) -> {noreply, State}.

terminate(_, #{cleaned := true}) -> ok;
terminate(_, State) -> _ = cleanup(State), ok.

cleanup(#{transport := Handle, directory := Directory, server_pid := Server,
          server_identity := ServerIdentity, helper_pid := Helper,
          helper_identity := HelperIdentity} = State) ->
    ok = tmux_transport:close(Handle),
    false = same_process(Server, ServerIdentity),
    false = same_process(Helper, HelperIdentity),
    maps:foreach(fun(Pid, Identity) ->
        false = same_process(Pid, Identity)
    end, maps:get(tracked_processes, State)),
    ok = file:del_dir_r(Directory),
    State#{cleaned => true}.

process_identity(Pid) ->
    {ok, Stat} = file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat"),
    {Position, 2} = lists:last(binary:matches(Stat, <<") ">>)),
    Tail = binary:part(Stat, Position + 2, byte_size(Stat) - Position - 2),
    lists:nth(20, binary:split(Tail, <<" ">>, [global])).

same_process(Pid, Identity) ->
    try process_identity(Pid) =:= Identity
    catch error:{badmatch, {error, enoent}} -> false
    end.
