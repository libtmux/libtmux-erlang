-module(tmux_pipe_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         duplex_and_toggle/1, output_and_input/1]).

%% Outer: real PTY/pipe bytes, independent consumer ACKs and owned retirement.
all() -> [duplex_and_toggle, output_and_input].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

duplex_and_toggle(Config) ->
    with_probe(Config, fun(Server, Fixture, Session, Pane, PanePeer, Listener, Spec) ->
        {ok, _} = tmux_pane:pipe(Pane, Spec(both), #{direction => both}),
        Peer0 = consumer(Fixture, Listener),
        try
            Long = <<$%, (binary:copy(<<$a>>, 8191))/binary>>,
            {error, #{code := format_limit}} = tmux_pane:pipe(Pane, #{shell => Long}, #{}),
            exchange(PanePeer, Peer0),
            {ok, _} = tmux_pane:pipe(Pane, Spec(both),
                #{direction => both, toggle => true}),
            {ok, <<"E">>} = gen_tcp:recv(Peer0, 1, 900),
            closed_pipe(Fixture, Pane)
        after ok = gen_tcp:close(Peer0)
        end,
        {ok, _} = tmux_pane:pipe(Pane, Spec(both),
            #{direction => both, toggle => true}),
        Peer1 = consumer(Fixture, Listener),
        try
            exchange(PanePeer, Peer1),
            {ok, _} = tmux_pane:stop_pipe(Pane),
            {ok, <<"E">>} = gen_tcp:recv(Peer1, 1, 900),
            closed_pipe(Fixture, Pane),
            {ok, _} = tmux_pane:stop_pipe(Pane)
        after ok = gen_tcp:close(Peer1)
        end,
        {ok, Detached} = tmux_model:pane(#{id => tmux_model:get(id, Pane)}),
        {error, #{code := detached_reference}} = tmux_pane:pipe(Detached, Spec(output), #{}),
        {ok, _} = tmux_session:kill(Session),
        {error, #{code := target_gone}} = tmux_pane:stop_pipe(Pane),
        {error, #{code := target_gone}} = tmux_pane:pipe(Pane, Spec(output), #{}),
        {ok, _} = tmux_server:status(Server)
    end).

output_and_input(Config) ->
    with_probe(Config, fun(Server, Fixture, Session, Pane, PanePeer, Listener, Spec) ->
        {ok, _} = tmux_pane:pipe(Pane, Spec(output), #{}),
        Peer0 = consumer(Fixture, Listener),
        try
            ok = tmux_server:close(Server),
            ok = gen_tcp:send(Peer0, <<"R">>),
            ok = gen_tcp:send(PanePeer, <<"O">>),
            Bytes = bytes(),
            Bytes = received(Peer0),
            #{socket := Socket, executable := Executable} = tmux_test_fixture:info(Fixture),
            {ok, Current} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
            try
                {ok, Bound} = tmux_pane:get(Current, tmux_model:get(id, Pane)),
                {ok, _} = tmux_pane:pipe(Bound, Spec(input), #{direction => input}),
                Peer1 = consumer(Fixture, Listener),
                try
                    {ok, <<"E">>} = gen_tcp:recv(Peer0, 1, 900),
                    ok = gen_tcp:send(PanePeer, <<"I">>),
                    ok = gen_tcp:send(Peer1, <<"R">>),
                    Bytes = received(PanePeer),
                    {ok, _} = tmux_pane:stop_pipe(Bound),
                    closed_pipe(Fixture, Bound),
                    %% Input-only consumer awaits its own coordination socket:
                    %% closing the native pipe has not cancelled that process.
                    ok = gen_tcp:send(Peer1, <<"Q">>),
                    {ok, <<"E">>} = gen_tcp:recv(Peer1, 1, 900),
                    {error, #{code := stale_reference}} =
                        tmux_pane:pipe(Pane, Spec(output), #{}),
                    {ok, BoundSession} = tmux_session:get(Current, tmux_model:get(id, Session)),
                    {ok, _} = tmux_session:kill(BoundSession)
                after ok = gen_tcp:close(Peer1)
                end
            after ok = tmux_server:close(Current)
            end
        after ok = gen_tcp:close(Peer0)
        end
    end).

with_probe(Config, Function) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), fun(Server, Fixture) ->
        #{directory := Directory} = tmux_test_fixture:info(Fixture),
        PanePath = filename:join(Directory, "p"),
        PipePath = filename:join(Directory, "c"),
        PaneListener = listener(PanePath),
        PipeListener = listener(PipePath),
        try
            Script = <<"import os,socket,sys,tty\n"
                "tty.setraw(0)\ns=socket.socket(socket.AF_UNIX)\ns.connect(sys.argv[1])\n"
                "s.sendall(b'R')\n"
                "while True:\n c=s.recv(1)\n if not c: break\n"
                " if c==b'O': os.write(1,bytes(range(256)))\n"
                " if c==b'I':\n  data=b''\n"
                "  while len(data)<256:\n   part=os.read(0,256-len(data))\n"
                "   assert part\n   data+=part\n"
                "  s.sendall(len(data).to_bytes(4,'big')+data)\n  os.write(1,data)\n">>,
            {ok, Session} = tmux_session:create(Server, #{launch => #{argv =>
                [<<"/usr/bin/python3">>, <<"-c">>, Script, list_to_binary(PanePath)]}}),
            {ok, PanePeer} = gen_tcp:accept(PaneListener, 900),
            try
                {ok, <<"R">>} = gen_tcp:recv(PanePeer, 1, 900),
                {ok, Snapshot} = tmux_server:snapshot(Server),
                [Pane] = tmux_snapshot:panes(Snapshot),
                ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane)),
                File = filename:join(Directory, "consumer.py"),
                ok = file:write_file(File, consumer_script()),
                Spec = fun(Mode) ->
                    Words = [<<"exec /usr/bin/python3">>, quote(list_to_binary(File)),
                        quote(list_to_binary(PipePath)), quote(literal()), atom_to_binary(Mode)],
                    #{shell => iolist_to_binary(lists:join(<<" ">>, Words))}
                end,
                Function(Server, Fixture, Session, Pane, PanePeer, PipeListener, Spec)
            after ok = gen_tcp:close(PanePeer)
            end
        after
            ok = gen_tcp:close(PaneListener),
            ok = gen_tcp:close(PipeListener)
        end
    end).

listener(Path) ->
    {ok, Listener} = gen_tcp:listen(0,
        [local, {ifaddr, {local, Path}}, binary, {active, false}]),
    Listener.

consumer_script() ->
    <<"import os,socket,sys\ns=socket.socket(socket.AF_UNIX)\ns.connect(sys.argv[1])\n"
      "arg=os.fsencode(sys.argv[2])\ns.sendall(os.getpid().to_bytes(4,'big'))\n"
      "s.sendall(len(arg).to_bytes(4,'big')+arg)\nassert s.recv(1)==b'R'\n"
      "if sys.argv[3] in ('both','input'): os.write(1,bytes(range(256)))\n"
      "if sys.argv[3]=='input':\n assert s.recv(1)==b'Q'\n"
      "else:\n data=b''\n"
      " while len(data)<256:\n  part=os.read(0,256-len(data))\n"
      "  assert part\n  data+=part\n"
      " s.sendall(len(data).to_bytes(4,'big')+data)\n assert os.read(0,1)==b''\n"
      "s.sendall(b'E')\ns.close()\n">>.

consumer(Fixture, Listener) ->
    {ok, Peer} = gen_tcp:accept(Listener, 900),
    {ok, <<Pid:32>>} = gen_tcp:recv(Peer, 4, 900),
    ok = tmux_test_fixture:track_process(Fixture, Pid),
    Literal = literal(),
    Literal = received(Peer),
    Peer.

exchange(Pane, Consumer) ->
    ok = gen_tcp:send(Pane, <<"I">>),
    ok = gen_tcp:send(Consumer, <<"R">>),
    Bytes = bytes(),
    Bytes = received(Pane),
    Bytes = received(Consumer).

received(Peer) ->
    {ok, <<Size:32>>} = gen_tcp:recv(Peer, 4, 900),
    {ok, Bytes} = gen_tcp:recv(Peer, Size, 900),
    Bytes.

closed_pipe(Fixture, Pane) ->
    Id = tmux_model:get(id, Pane),
    Expected = <<Id/binary, "\t0\n">>,
    {ok, #{stdout := Expected, exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"display-message">>, <<"-p">>, <<"-t">>, Id, <<"#{pane_id}\t#{pane_pipe}">>]).

bytes() -> list_to_binary(lists:seq(0, 255)).
literal() ->
    <<"literal #[fg=red] ##[bg=blue] #{pane_id} %Y; $HOME ",
      (list_to_binary(lists:seq(1, 255)))/binary>>.
quote(Value) -> <<$\', (binary:replace(Value, <<$\'>>, <<"'\\''">>, [global]))/binary, $\'>>.
