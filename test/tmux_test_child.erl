-module(tmux_test_child).
-compile(nowarn_missing_spec).
-moduledoc """
Child programs the Common Test suites run inside panes and as helper children.

Each mode is one small program with a byte-exact contract; `command/2` builds
the argv that starts it in a fresh Erlang VM. Raw terminal modes read and write
the standard descriptors directly, so every byte value passes through.
""".
-export([command/2, shell_command/2, escript/0, main/1, fake_tmux/2]).

%% Argv: the VM binary and its arguments for one mode.
command(Mode, Arguments) ->
    Erl = list_to_binary(os:find_executable("erl")),
    Directory = list_to_binary(filename:dirname(code:which(?MODULE))),
    {Erl, [<<"+S">>, <<"1:1">>, <<"+fnl">>, <<"-noshell">>, <<"-noinput">>, <<"-pa">>, Directory,
           <<"-run">>, <<"tmux_test_child">>, <<"main">>, Mode | Arguments]}.

%% The same command as shell text, with every word single-quoted.
shell_command(Mode, Arguments) ->
    {Erl, Rest} = command(Mode, Arguments),
    iolist_to_binary(lists:join(<<" ">>, [quote(Word) || Word <- [Erl | Rest]])).

quote(Value) -> <<$\', (binary:replace(Value, <<$\'>>, <<"'\\''">>, [global]))/binary, $\'>>.

escript() -> list_to_binary(os:find_executable("escript")).

main([Mode | Arguments]) ->
    try run(Mode, Arguments) of
        ok -> halt(0)
    catch Class:Reason:Stack ->
        file:write_file("/dev/stderr", io_lib:format("~p:~p~n~p~n", [Class, Reason, Stack])),
        halt(1)
    end.

%% Modes

%% Announce readiness, then echo each stdin chunk with a marker on stderr.
run("echo-marked", []) ->
    {In, Out, Err} = {input(), output(), stream_error()},
    ok = emit(Out, <<"ready\n">>),
    ok = emit(Err, <<"notice">>),
    echo(In, Out, Err);
%% Write the text to standard output and standard error, then exit with the
%% status.
run("write", [Stdout, Stderr, Status]) ->
    ok = emit(output(), list_to_binary(Stdout)),
    ok = emit(stream_error(), list_to_binary(Stderr)),
    halt(list_to_integer(Status));
%% Fill the output pipe, then wait.
run("blocked", []) ->
    ok = emit(output(), binary:copy(<<"x">>, 65536)),
    forever();
%% Report the working directory and the variables the transport must control.
run("environment", []) ->
    Lines = [list_to_binary(element(2, file:get_cwd())), env("ONLY", <<"unset">>),
             env("TMUX", <<"missing">>), env("TMUX_PANE", <<"missing">>)],
    ok = emit(output(), [[Line, $\n] || Line <- Lines]);
%% Report argv, working directory bytes and one variable, read nine raw
%% terminal bytes and send them back.
run("launch-report", [Socket | Rest]) ->
    raw_terminal(),
    Peer = connect(Socket),
    Report = json:encode([[list_to_binary(A) || A <- Rest],
                          binary:encode_hex(list_to_binary(element(2, file:get_cwd())), lowercase),
                          env("LIBTMUX_VALUE", <<>>)]),
    ok = gen_tcp:send(Peer, [<<(iolist_size(Report)):32>>, Report]),
    ok = gen_tcp:send(Peer, take(input(), 9)),
    forever();
%% Report argv, working directory, one variable and the OS process ID.
run("respawn-report", [Socket, Argument, Key]) ->
    Peer = connect(Socket),
    Report = json:encode([list_to_binary(Argument),
                          list_to_binary(element(2, file:get_cwd())),
                          env(Key, <<"unset">>), list_to_integer(os:getpid())]),
    ok = gen_tcp:send(Peer, [<<(iolist_size(Report)):32>>, Report]),
    forever();
%% A pane program for pipe tests: signal ready, then on 'O' write every byte
%% value and on 'I' read 256 bytes, report them and write them back.
run("pane-probe", [Socket]) ->
    raw_terminal(),
    Peer = connect(Socket),
    ok = gen_tcp:send(Peer, <<"R">>),
    pane_probe(Peer, input(), output());
%% The process a pane pipes through: handshake over the socket, then write or
%% read 256 bytes according to the direction.
run("pipe-consumer", [Socket, Argument, Mode]) ->
    Peer = connect(Socket),
    Literal = list_to_binary(Argument),
    ok = gen_tcp:send(Peer, [<<(list_to_integer(os:getpid())):32>>,
                             <<(byte_size(Literal)):32>>, Literal]),
    {ok, <<"R">>} = gen_tcp:recv(Peer, 1),
    Out = output(),
    case Mode of
        M when M =:= "both"; M =:= "input" -> ok = emit(Out, list_to_binary(lists:seq(0, 255)));
        _ -> ok
    end,
    case Mode of
        "input" -> {ok, <<"Q">>} = gen_tcp:recv(Peer, 1);
        _ ->
            In = input(),
            Data = take(In, 256),
            ok = gen_tcp:send(Peer, [<<(byte_size(Data)):32>>, Data]),
            ok = end_of_input(In)
    end,
    ok = gen_tcp:send(Peer, <<"E">>),
    ok = gen_tcp:close(Peer);
%% Signal ready, then read the counted raw byte strings pasted into the pane.
run("paste-probe", [Socket, Counts]) ->
    raw_terminal(),
    Peer = connect(Socket),
    ok = gen_tcp:send(Peer, <<"R">>),
    In = input(),
    lists:foreach(fun(Count) ->
        Data = take(In, Count),
        ok = gen_tcp:send(Peer, [<<(byte_size(Data)):32>>, Data])
    end, json:decode(list_to_binary(Counts))),
    forever();
%% Connect to a socket, send one byte and wait: a program started by exec.
run("announce", [Socket]) ->
    Peer = connect(Socket),
    ok = gen_tcp:send(Peer, <<"R">>),
    ok = gen_tcp:close(Peer),
    forever().

%% A tmux stand-in for owned-server fault injection. It records the socket it
%% was given in the `socket` file beside the script and behaves as the `mode`
%% file there says: it answers the identity probe with a fixed identity, with
%% the real one, or after replacing the socket directory by a symlink; the
%% startup client prints a partial line, never answers, claims a socket it did
%% not create, or runs the real tmux unchanged.
fake_tmux(Real, Arguments) ->
    Root = filename:dirname(filename:absname(escript:script_name())),
    Socket = hd(tl(lists:dropwhile(fun(A) -> A =/= "-S" end, Arguments))),
    ok = file:write_file(filename:join(Root, "socket"), Socket),
    {ok, Mode} = file:read_file(filename:join(Root, "mode")),
    case lists:member("-N", Arguments) of
        true -> fake_probe(Real, Arguments, Root, Socket, Mode);
        false -> fake_client(Real, Arguments, Socket, Mode)
    end.

fake_probe(Real, Arguments, Root, Socket, Mode) ->
    {0, Output} = collect(open_port({spawn_executable, Real},
        [binary, exit_status, {args, Arguments}]), <<>>),
    [Pid, _] = binary:split(Output, <<"\t">>),
    Process = binary_to_integer(Pid),
    {ok, Stat} = file:read_file("/proc/" ++ integer_to_list(Process) ++ "/stat"),
    {Position, 2} = lists:last(binary:matches(Stat, <<") ">>)),
    Fields = binary:split(binary:part(Stat, Position + 2, byte_size(Stat) - Position - 2),
                          <<" ">>, [global]),
    ok = file:write_file(filename:join(Root, "probe"),
                         json:encode(#{pid => Process, start => lists:nth(20, Fields)})),
    case Mode of
        <<"directory">> ->
            Parent = filename:dirname(Socket),
            ok = file:rename(Parent, Parent ++ ".original"),
            ok = file:make_symlink(Parent ++ ".original", Parent),
            ok = emit(output(), Output);
        _ -> ok = emit(output(), <<"0\t3.3\n">>)
    end,
    halt(0).

fake_client(_, _, Socket, <<"namespace">>) ->
    ok = file:write_file(Socket, <<"preserve">>),
    ok = emit(output(), <<"123\t3.3\n">>),
    forever();
fake_client(_, _, _, <<"partial">>) ->
    ok = emit(output(), <<"123">>),
    halt(0);
fake_client(_, _, _, <<"timeout">>) -> forever();
fake_client(Real, Arguments, _, _) ->
    Port = open_port({spawn_executable, Real}, [binary, exit_status, {args, Arguments}]),
    Out = output(),
    forward(Port, Out).

forward(Port, Out) ->
    receive
        {Port, {data, Data}} -> ok = emit(Out, Data), forward(Port, Out);
        {Port, {exit_status, Status}} -> halt(Status)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
    end.

%% Streams and terminals

%% Standard output through a port: a pipe-pane child's output is a socket, which
%% cannot be reopened through /dev/stdout.
output() -> open_port({fd, 0, 1}, [binary, out]).

emit(Port, Data) ->
    true = port_command(Port, Data),
    ok.

stream_error() -> open_port({fd, 0, 2}, [binary, out]).

%% Standard input as a port, so a read returns what has arrived instead of
%% waiting for a full buffer. Bytes read past a request wait in the buffer.
input() ->
    put(input_buffer, <<>>),
    open_port({fd, 0, 1}, [binary, eof, in]).

take(Port, Count) ->
    Buffer = get(input_buffer),
    case Buffer of
        <<Data:Count/binary, Rest/binary>> ->
            put(input_buffer, Rest),
            Data;
        _ ->
            receive
                {Port, {data, More}} -> put(input_buffer, <<Buffer/binary, More/binary>>), take(Port, Count)
            end
    end.

end_of_input(Port) ->
    <<>> = get(input_buffer),
    receive {Port, eof} -> ok end.

%% Standard input, a terminal, gets raw unechoed input; -iexten keeps ^V and ^O
%% bytes literal, as termios raw mode does. The port child has no
%% controlling terminal, so stty reaches the device through this process.
raw_terminal() ->
    Port = open_port({spawn_executable, os:find_executable("stty")},
                     [exit_status, {args, ["-F", "/proc/" ++ os:getpid() ++ "/fd/0", "raw", "-echo", "-iexten"]}]),
    receive {Port, {exit_status, 0}} -> ok end.

echo(In, Out, Err) ->
    receive
        {In, {data, Chunk}} ->
            ok = emit(Out, Chunk),
            ok = emit(Err, <<"W">>),
            echo(In, Out, Err);
        {In, eof} -> ok
    end.

pane_probe(Peer, In, Out) ->
    case gen_tcp:recv(Peer, 1) of
        {ok, <<"O">>} ->
            ok = emit(Out, list_to_binary(lists:seq(0, 255))),
            pane_probe(Peer, In, Out);
        {ok, <<"I">>} ->
            Data = take(In, 256),
            ok = gen_tcp:send(Peer, [<<(byte_size(Data)):32>>, Data]),
            ok = emit(Out, Data),
            pane_probe(Peer, In, Out);
        {error, closed} -> ok
    end.

connect(Socket) ->
    {ok, Peer} = gen_tcp:connect({local, Socket}, 0, [local, binary, {active, false}]),
    Peer.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> list_to_binary(Value)
    end.

forever() -> receive after infinity -> ok end.
