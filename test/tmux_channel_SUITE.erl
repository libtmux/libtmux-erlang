-module(tmux_channel_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, duplex_credit/1,
         ownership_and_cancellation/1, owner_death/1]).

%% Outer: native duplex I/O and helper retirement, without tmux attachment.
all() -> [duplex_credit, ownership_and_cancellation, owner_death].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Config.
end_per_suite(_) -> ok = application:stop(libtmux_erlang).

duplex_credit(_) ->
    Script = <<"import os
os.write(1,b'ready'+bytes([10]))
os.write(2,b'notice')
",
               "while chunk:=os.read(0,8192):
",
               " os.write(1,chunk)
 os.write(2,b'W')
">>,
    {ok, Handle} = tmux_transport:start_channel(<<"/usr/bin/python3">>,
        [<<"-c">>, Script], #{}),
    try
        {ok, _} = tmux_transport:await_started(Handle, 900),
        {ReadySeq, <<"ready\n">>} = data(Handle, stdout),
        {NoticeSeq, <<"notice">>} = data(Handle, stderr),
        ok = tmux_transport:ack(Handle, stdout, ReadySeq),
        ok = tmux_transport:ack(Handle, stderr, NoticeSeq),
        First = binary:copy(<<0, 255, 10, 65>>, 1024),
        write(Handle, First),
        {FirstSeq, First} = data(Handle, stdout),
        {MarkerSeq, <<"W">>} = data(Handle, stderr),
        ok = tmux_transport:ack(Handle, stderr, MarkerSeq),
        Second = binary:copy(<<66>>, 4096),
        write(Handle, Second),
        {LastMarkerSeq, <<"W">>} = data(Handle, stderr),
        ok = tmux_transport:ack(Handle, stderr, LastMarkerSeq),
        ok = tmux_transport:ack(Handle, stdout, ReadySeq),
        receive
            {tmux_transport, Handle, {data, stdout, _, _}} ->
                ct:fail(read_without_credit)
        after 0 -> ok
        end,
        {ok, #{stdout_bytes := 4102}} = tmux_transport:status(Handle),
        ok = tmux_transport:ack(Handle, stdout, FirstSeq),
        {SecondSeq, Second} = data(Handle, stdout),
        ok = tmux_transport:ack(Handle, stdout, SecondSeq),
        ok = tmux_transport:close_stdin(Handle),
        eof(Handle, stdout),
        eof(Handle, stderr),
        {ok, #{exit_status := 0, cleanup := complete, stdin_delivered := 8192,
               stdout_bytes := 8198, stderr_bytes := 8}} =
            tmux_transport:await(Handle, 900)
    after ok = tmux_transport:close(Handle)
    end.

ownership_and_cancellation(_) ->
    {error, #{code := invalid_argument, outcome := not_started}} =
        tmux_transport:start_channel(<<"/bin/true">>, [], #{startup_timeout_ms => 0}),
    {error, #{code := invalid_argument}} =
        tmux_transport:start_channel(<<"/bin/true">>, [], #{max_stdout => 100}),
    {ok, Missing} = tmux_transport:start_channel(<<"/no-such-channel-program">>, [], #{}),
    try
        {error, #{code := exec_failed, cleanup := complete}} =
            tmux_transport:await_started(Missing, 900)
    after ok = tmux_transport:close(Missing)
    end,
    {ok, Handle} = blocked_channel(),
    try
        {ok, #{worker := Worker, child_pid := Child, helper_pid := Helper}} =
            tmux_transport:await_started(Handle, 900),
        ChildIdentity = tmux_test_fixture:process_identity(Child),
        HelperIdentity = tmux_test_fixture:process_identity(Helper),
        {Seq, Bytes} = data(Handle, stdout),
        true = byte_size(Bytes) =< 8192,
        {error, #{code := invalid_ack}} = tmux_transport:ack(Handle, stdout, Seq + 1),
        {error, #{code := invalid_ack}} = tmux_transport:ack_write(Handle, 0),
        {error, #{code := invalid_argument}} = tmux_transport:write(Handle, <<>>),
        {error, #{code := invalid_argument}} =
            tmux_transport:write(Handle, binary:copy(<<0>>, 8193)),
        ok = sys:suspend(Worker),
        try
            Parent = self(),
            {Caller, Monitor} = spawn_monitor(fun() ->
                Results = [tmux_transport:write(Handle, binary:copy(<<1>>, 8192)),
                           tmux_transport:ack(Handle, stdout, Seq),
                           tmux_transport:ack_write(Handle, 0),
                           tmux_transport:close_stdin(Handle)],
                Parent ! {foreign_results, self(), Results}
            end),
            receive {foreign_results, Caller, Results} ->
                lists:foreach(fun({error, #{code := not_owner}}) -> ok end, Results)
            after 900 -> ct:fail(foreign_payload_entered_mailbox)
            end,
            receive {'DOWN', Monitor, process, Caller, normal} -> ok
            after 900 -> ct:fail(foreign_caller_alive)
            end
        after ok = sys:resume(Worker)
        end,
        {ok, cancel_requested} = tmux_transport:cancel(Handle),
        {error, #{code := cancelled, cleanup := complete, stdout_bytes := Size}} =
            tmux_transport:await(Handle, 900),
        Size = byte_size(Bytes),
        false = tmux_test_fixture:same_process(Child, ChildIdentity),
        false = tmux_test_fixture:same_process(Helper, HelperIdentity)
    after ok = tmux_transport:close(Handle)
    end.

owner_death(_) ->
    Parent = self(),
    {Owner, OwnerMonitor} = spawn_monitor(fun() ->
        {ok, Handle} = blocked_channel(),
        {ok, Status} = tmux_transport:await_started(Handle, 900),
        {_, _} = data(Handle, stdout),
        Parent ! {slow_owner_ready, self(), Status},
        receive finish -> ok end
    end),
    try
        receive
            {slow_owner_ready, Owner, #{worker := Worker, child_pid := Child,
                                        helper_pid := Helper}} ->
                ChildIdentity = tmux_test_fixture:process_identity(Child),
                HelperIdentity = tmux_test_fixture:process_identity(Helper),
                Monitor = monitor(process, Worker),
                exit(Owner, kill),
                receive {'DOWN', Monitor, process, Worker, normal} -> ok
                after 900 -> ct:fail(channel_owner_cleanup_timeout)
                end,
                false = tmux_test_fixture:same_process(Child, ChildIdentity),
                false = tmux_test_fixture:same_process(Helper, HelperIdentity)
        after 900 -> ct:fail(channel_owner_start_timeout)
        end,
        receive {'DOWN', OwnerMonitor, process, Owner, killed} -> ok
        after 900 -> ct:fail(channel_owner_alive)
        end
    after exit(Owner, kill)
    end.

blocked_channel() ->
    tmux_transport:start_channel(<<"/usr/bin/python3">>, [<<"-c">>,
        <<"import os,signal; os.write(1,b'x'*65536); signal.pause()">>], #{}).

data(Handle, Stream) ->
    receive {tmux_transport, Handle, {data, Stream, Seq, Bytes}} -> {Seq, Bytes}
    after 900 -> ct:fail({channel_data_timeout, Stream})
    end.

write(Handle, Bytes) ->
    {ok, Id} = tmux_transport:write(Handle, Bytes),
    receive
        {tmux_transport, Handle, {write_ack, Id, Size}} ->
            Size = byte_size(Bytes),
            {error, #{code := busy}} = tmux_transport:write(Handle, <<42>>),
            {error, #{code := busy}} = tmux_transport:close_stdin(Handle),
            ok = tmux_transport:ack_write(Handle, Id),
            ok = tmux_transport:ack_write(Handle, Id)
    after 900 -> ct:fail(channel_write_timeout)
    end.

eof(Handle, Stream) ->
    receive {tmux_transport, Handle, {eof, Stream}} -> ok
    after 900 -> ct:fail({channel_eof_timeout, Stream})
    end.
