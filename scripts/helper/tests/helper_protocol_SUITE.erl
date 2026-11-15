-module(helper_protocol_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         missing_children_rejects_before_fork/1, independent_credits/1,
         stdout_stderr_and_exit_status/1, partial_write_is_accounted/1,
         reaps_a_descendant_outside_the_group/1, parent_eof_retires_the_child/1,
         timeout_keeps_its_reason/1, oversized_header_retires/1,
         exec_error_is_not_an_exit_status/1, vanished_process_has_no_identity/1]).

%% Outer: the helper's byte credits, writes and owned retirement, driven over
%% its framed stdio protocol. LIBTMUX_TEST_HELPER selects a sanitizer build.
all() -> [missing_children_rejects_before_fork, independent_credits,
          stdout_stderr_and_exit_status, partial_write_is_accounted,
          reaps_a_descendant_outside_the_group, parent_eof_retires_the_child,
          timeout_keeps_its_reason, oversized_header_retires,
          exec_error_is_not_an_exit_status, vanished_process_has_no_identity].

-define(DEADLINE, 900).
-define(FRAME_LIMIT, 8194).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Helper = case os:getenv("LIBTMUX_TEST_HELPER") of
        false -> filename:join(code:priv_dir(libtmux_erlang), "tmux_owned_io");
        Path -> Path
    end,
    [{helper, Helper}, {root, repository_root()} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

repository_root() ->
    Directory = filename:dirname(code:which(?MODULE)),
    find_root(Directory).

find_root("/") -> error(repository_root_not_found);
find_root(Directory) ->
    case filelib:is_file(filename:join(Directory, "rebar.config")) of
        true -> Directory;
        false -> find_root(filename:dirname(Directory))
    end.

%% Cases

missing_children_rejects_before_fork(Config) ->
    %% Link-time injection leaves the host procfs and the packaged helper intact.
    script_util:with_tmp_dir("tmux-erlang-capability", fun(Directory) ->
        Executable = build_missing_children_helper(proplists:get_value(root, Config), Directory),
        with_helper(Executable, fun(Helper0) ->
            {Terminal, Helper1} = configure(Helper0, [<<"/bin/true">>], 0),
            <<"F", 5, 2:32>> = Terminal,
            acknowledge(Terminal, Helper1)
        end)
    end).

independent_credits(Config) ->
    Payload = <<0, 6, "E", 0, 0, 0, 0, 0, "%end\n">>,
    with_helper(proplists:get_value(helper, Config), fun(Helper0) ->
        {Started, Helper1} = shell(Helper0,
            "printf '\\000\\006E\\000\\000\\000\\000\\000%%end\\n'; printf ready >&2; exec sleep 3600"),
        <<"S", _:32>> = Started,
        Helper2 = credit(Helper1, 2, 5),
        {<<"D", 2, "ready">>, Helper3} = frame(Helper2),
        none = pending(Helper3),
        {Received, Helper4} = drain(Helper3, byte_size(Payload), <<>>),
        Payload = Received,
        {_, Terminal, Helper5} = stop(Helper4),
        <<"E", 1, _/binary>> = Terminal,
        acknowledge(Terminal, Helper5)
    end).

stdout_stderr_and_exit_status(Config) ->
    with_helper(proplists:get_value(helper, Config), fun(Helper0) ->
        {<<"S", _:32>>, Helper1} = configure(Helper0,
            [<<"/bin/sh">>, <<"-c">>, <<"printf output; printf diagnostic >&2; exit 7">>], 0),
        Helper2 = credit(credit(Helper1, 1, 8192), 2, 8192),
        {Streams, Closed, Terminal, Helper3} = collect(Helper2, #{1 => <<>>, 2 => <<>>}, []),
        #{1 := <<"output">>, 2 := <<"diagnostic">>} = Streams,
        [1, 2] = lists:sort(Closed),
        <<"E", 0, 7:32>> = Terminal,
        acknowledge(Terminal, Helper3)
    end).

%% The child never reads its input, so the pipe fills. The write that does not
%% fit stays pending until the stop, which must account for the bytes it took.
partial_write_is_accounted(Config) ->
    with_helper(proplists:get_value(helper, Config), fun(Helper0) ->
        {<<"S", _:32>>, Helper1} = configure(Helper0, [<<"/bin/sleep">>, <<"3600">>], 0),
        Helper2 = fill_pipe(Helper1, 1),
        {Packets, Terminal, Helper3} = stop(Helper2),
        <<"E", 1, _/binary>> = Terminal,
        [{_, Delivered}] = [{Id, Count} || <<"A", Id:32, Count:16, 1>> <- Packets],
        true = Delivered < 8192,
        acknowledge(Terminal, Helper3)
    end).

reaps_a_descendant_outside_the_group(Config) ->
    with_helper(proplists:get_value(helper, Config), fun(Helper0) ->
        {<<"S", _:32>>, Helper1} = shell(Helper0, "setsid sleep 3600 & echo $!; wait"),
        Helper2 = credit(Helper1, 1, 8192),
        {<<"D", 1, Pid/binary>>, Helper3} = frame(Helper2),
        Helper4 = track(Helper3, binary_to_integer(string:trim(Pid))),
        {_, Terminal, Helper5} = stop(Helper4),
        <<"E", 1, _/binary>> = Terminal,
        acknowledge(Terminal, Helper5)
    end).

%% Closing the port ends the helper's input; it must retire its child by itself.
parent_eof_retires_the_child(Config) ->
    Helper0 = open(proplists:get_value(helper, Config)),
    {<<"S", _:32>>, Helper1} = configure(Helper0, [<<"/bin/sleep">>, <<"3600">>], 0),
    #{os_pid := HelperPid, port := Port} = Helper1,
    Gone = wait_for_exit(HelperPid),
    true = port_close(Port),
    ok = receive {Gone, {exit_status, 0}} -> ok
         after ?DEADLINE -> ct:fail(helper_did_not_retire) end,
    ok = children_retired(Helper1).

timeout_keeps_its_reason(Config) ->
    with_helper(proplists:get_value(helper, Config), fun(Helper0) ->
        {<<"S", _:32>>, Helper1} = configure(Helper0, [<<"/bin/sleep">>, <<"3600">>], 40),
        {Terminal, Helper2} = frame(Helper1),
        <<"E", 2, _/binary>> = Terminal,
        acknowledge(Terminal, Helper2)
    end).

oversized_header_retires(Config) ->
    with_helper(proplists:get_value(helper, Config), fun(Helper0) ->
        {<<"S", _:32>>, Helper1} = configure(Helper0, [<<"/bin/sleep">>, <<"3600">>], 0),
        true = port_command(maps:get(port, Helper1), <<32769:16>>),
        {Terminal, Helper2} = frame(Helper1),
        <<"F", 1, _/binary>> = Terminal,
        acknowledge(Terminal, Helper2)
    end).

exec_error_is_not_an_exit_status(Config) ->
    script_util:with_tmp_dir("tmux-erlang-missing", fun(Directory) ->
        with_helper(proplists:get_value(helper, Config), fun(Helper0) ->
            Missing = list_to_binary(filename:join(Directory, "missing")),
            {Terminal, Helper1} = configure(Helper0, [Missing], 0),
            <<"F", 2, _/binary>> = Terminal,
            acknowledge(Terminal, Helper1)
        end)
    end).

vanished_process_has_no_identity(_Config) ->
    gone = identity(4194303),
    {Parent, _Start, _State} = identity(list_to_integer(os:getpid())),
    true = is_integer(Parent).

%% Helper session

open(Executable) ->
    Port = open_port({spawn_executable, Executable},
        [binary, exit_status, use_stdio, {env, [{"TMUX", false}, {"TMUX_PANE", false}]}]),
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    #{port => Port, os_pid => OsPid, buffer => <<>>, tracked => []}.

with_helper(Executable, Fun) ->
    Helper = open(Executable),
    try Fun(Helper)
    after
        #{port := Port} = Helper,
        case erlang:port_info(Port) of
            undefined -> ok;
            _ -> port_close(Port)
        end
    end.

configure(Helper, Arguments, Timeout) ->
    {ok, Cwd} = file:get_cwd(),
    Open = <<"O", 4, 1, Timeout:32, (string(list_to_binary(Cwd)))/binary,
             (length(Arguments)):16, (<< <<(string(Argument))/binary>> || Argument <- Arguments >>)/binary,
             0:16>>,
    Next = send(Helper, Open),
    {Packet, Final} = frame(Next),
    case Packet of
        <<"S", Pid:32>> -> {Packet, track(Final, Pid)};
        _ -> {Packet, Final}
    end.

shell(Helper, Script) ->
    configure(Helper, [<<"/bin/sh">>, <<"-c">>, list_to_binary(Script)], 0).

string(Value) -> <<(byte_size(Value)):16, Value/binary>>.

send(#{port := Port} = Helper, Payload) ->
    true = port_command(Port, <<(byte_size(Payload)):16, Payload/binary>>),
    Helper.

credit(Helper, Stream, Count) -> send(Helper, <<"R", Stream, Count:16>>).

%% Read one frame, bounded by the helper event deadline.
frame(#{buffer := <<Size:16, Packet:Size/binary, Rest/binary>>} = Helper)
  when Size > 0, Size =< ?FRAME_LIMIT ->
    {Packet, Helper#{buffer := Rest}};
frame(#{buffer := <<Size:16, _/binary>>}) when Size =:= 0; Size > ?FRAME_LIMIT ->
    ct:fail({invalid_output_frame_size, Size});
frame(#{port := Port, buffer := Buffer} = Helper) ->
    receive
        {Port, {data, Chunk}} -> frame(Helper#{buffer := <<Buffer/binary, Chunk/binary>>});
        {Port, {exit_status, Status}} -> ct:fail({helper_exited_before_its_terminal_proof, Status})
    after ?DEADLINE -> ct:fail(helper_event_deadline_exceeded)
    end.

frame_within(#{buffer := <<Size:16, _:Size/binary, _/binary>>} = Helper, _) -> frame(Helper);
frame_within(#{port := Port, buffer := Buffer} = Helper, Milliseconds) ->
    receive
        {Port, {data, Chunk}} ->
            frame_within(Helper#{buffer := <<Buffer/binary, Chunk/binary>>}, Milliseconds)
    after Milliseconds -> {timeout, Helper}
    end.

%% Nothing is waiting on the port or in the buffer.
pending(#{port := Port, buffer := <<>>}) ->
    receive {Port, {data, _}} -> ct:fail(unrequested_output) after 0 -> none end;
pending(_) -> ct:fail(unrequested_output).

drain(Helper, Total, Acc) when byte_size(Acc) >= Total -> {Acc, Helper};
drain(Helper0, Total, Acc) ->
    Helper1 = credit(Helper0, 1, 3),
    {<<"D", 1, Bytes/binary>>, Helper2} = frame(Helper1),
    true = byte_size(Bytes) =< 3,
    drain(Helper2, Total, <<Acc/binary, Bytes/binary>>).

collect(Helper0, Streams, Closed) ->
    {Packet, Helper1} = frame(Helper0),
    case Packet of
        <<"D", Stream, Bytes/binary>> ->
            Updated = maps:update_with(Stream, fun(Old) -> <<Old/binary, Bytes/binary>> end, Streams),
            collect(credit(Helper1, Stream, 8192), Updated, Closed);
        <<"Z", Stream>> -> collect(Helper1, Streams, [Stream | Closed]);
        Terminal -> {Streams, Closed, Terminal, Helper1}
    end.

%% Send full-size writes while each is acknowledged at once. The first write
%% that is not acknowledged within the settling time is the pending one.
fill_pipe(Helper0, Id) ->
    Helper1 = send(Helper0, <<"W", Id:32, (binary:copy(<<"x">>, 8192))/binary>>),
    case frame_within(Helper1, 300) of
        {<<"A", Id:32, 8192:16, 0>>, Helper2} -> fill_pipe(Helper2, Id + 1);
        {timeout, Helper2} -> Helper2
    end.

stop(Helper0) -> stop(send(Helper0, <<"Q">>), []).

stop(Helper0, Packets) ->
    {Packet, Helper1} = frame(Helper0),
    case Packet of
        <<Kind, _/binary>> when Kind =:= $E; Kind =:= $F -> {lists:reverse(Packets), Packet, Helper1};
        _ -> stop(Helper1, [Packet | Packets])
    end.

acknowledge(<<Kind, _/binary>> = Terminal, #{port := Port} = Helper)
  when Kind =:= $E; Kind =:= $F ->
    case Terminal of
        <<"F", 4, _/binary>> -> ct:fail(cleanup_incomplete);
        _ -> ok
    end,
    _ = send(Helper, <<"T">>),
    ok = receive {Port, {exit_status, 0}} -> ok
         after ?DEADLINE -> ct:fail(helper_did_not_exit_after_acknowledgement) end,
    ok = children_retired(Helper).

%% Process identity from procfs: parent, start time and state.

identity(Pid) ->
    case file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat") of
        {ok, Stat} ->
            {Position, 2} = lists:last(binary:matches(Stat, <<") ">>)),
            Tail = binary:part(Stat, Position + 2, byte_size(Stat) - Position - 2),
            [State, Parent | _] = Fields = binary:split(Tail, <<" ">>, [global]),
            {binary_to_integer(Parent), lists:nth(20, Fields), State};
        {error, enoent} -> gone;
        {error, esrch} -> gone
    end.

%% Track a reported process only when it descends from this helper.
track(#{os_pid := HelperPid, tracked := Tracked} = Helper, Pid) ->
    case identity(Pid) of
        gone -> Helper;
        {_, Start, _} = Before ->
            true = descends(element(1, Before), HelperPid),
            Helper#{tracked := [{Pid, Start} | Tracked]}
    end.

descends(HelperPid, HelperPid) -> true;
descends(Ancestor, HelperPid) when Ancestor > 1 ->
    case identity(Ancestor) of
        gone -> true;
        {Parent, _, _} -> descends(Parent, HelperPid)
    end;
descends(_, _) -> ct:fail(reported_process_is_outside_the_owned_helper_tree).

%% Every tracked process is gone, a zombie or replaced once the helper is
%% retired. A zombie of a reparented process waits for its new parent to reap it.
children_retired(#{tracked := Tracked}) ->
    Deadline = erlang:monotonic_time(millisecond) + ?DEADLINE,
    lists:foreach(fun({Pid, Start}) -> until_retired(Pid, Start, Deadline) end, Tracked).

until_retired(Pid, Start, Deadline) ->
    case identity(Pid) of
        gone -> ok;
        {_, Other, _} when Other =/= Start -> ok;
        {_, _, <<"Z">>} -> ok;
        {_, _, <<"X">>} -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> receive after 5 -> until_retired(Pid, Start, Deadline) end;
                false -> ct:fail({owned_child_outlived_the_retired_helper, Pid})
            end
    end.

%% Block until an operating-system process ends, without polling from Erlang.
wait_for_exit(OsPid) ->
    open_port({spawn_executable, os:find_executable("tail")},
        [binary, exit_status, use_stdio,
         {args, ["--pid=" ++ integer_to_list(OsPid), "-s", "0.02", "-f", "/dev/null"]}]).

%% A helper variant that hides /proc children and traps any fork.
build_missing_children_helper(Root, Directory) ->
    Shim = filename:join(Directory, "missing_children.c"),
    ok = file:write_file(Shim, <<
        "#define _GNU_SOURCE\n#include <errno.h>\n#include <stdio.h>\n#include <string.h>\n"
        "#include <sys/types.h>\n#include <unistd.h>\n"
        "FILE *__real_fopen(const char *, const char *);\n"
        "FILE *__wrap_fopen(const char *path, const char *mode) {\n"
        "    char children[80];\n"
        "    snprintf(children, sizeof children, \"/proc/self/task/%ld/children\", (long)getpid());\n"
        "    if (strcmp(path, children) == 0) { errno = ENOENT; return NULL; }\n"
        "    return __real_fopen(path, mode);\n}\n"
        "pid_t __wrap_fork(void) { _exit(99); }\n">>),
    Executable = filename:join(Directory, "tmux_owned_io"),
    Compiler = case os:getenv("LIBTMUX_TEST_CC") of false -> "cc"; Cc -> Cc end,
    Flags = case os:getenv("LIBTMUX_TEST_CFLAGS") of false -> []; Text -> string:tokens(Text, " ") end,
    Source = filename:join([Root, "apps", "libtmux_erlang", "c_src", "owned_io.c"]),
    #{status := 0} = script_util:run(Compiler,
        Flags ++ ["-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic", Source, Shim,
                  "-Wl,--wrap=fopen", "-Wl,--wrap=fork", "-o", Executable],
        #{timeout_ms => 60000}),
    Executable.
