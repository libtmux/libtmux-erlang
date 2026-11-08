-module(pipe_demo).
-moduledoc "Save terminal bytes after a consumer acknowledgement.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Directory = <<"/tmp/ltm-pipe-example-", Suffix/binary>>,
    ok = file:make_dir(Directory),
    tmux_scope:run_or_error(fun() ->
        ok = file:change_mode(Directory, 8#700),
        Log = <<Directory/binary, "/job.log">>,
        {ok, Server} = tmux_server:open(
            #{socket_path => Socket, executable => Executable}),
        tmux_scope:run_or_error(fun() ->
            Native = <<(quote(Executable))/binary,
                " -N -S ", (quote(Socket))/binary, " wait-for ">>,
            Start = <<"start-", Suffix/binary>>,
            Done = <<"consumed-", Suffix/binary>>,
            Producer = <<"stty -onlcr && ", Native/binary, Start/binary,
                " && printf 'build complete\\n' && exec /bin/cat">>,
            {ok, Session} = tmux_session:create(Server,
                #{name => <<"pipe-example">>, launch => #{argv =>
                    [<<"/bin/sh">>, <<"-c">>, Producer]}}),
            tmux_scope:run_or_error(fun() ->
                {ok, Snapshot} = tmux_server:snapshot(Server),
                [Pane] = tmux_snapshot:panes(Snapshot),
                Payload = <<"build complete\n">>,
                Size = integer_to_binary(byte_size(Payload)),
                Consumer = <<"/usr/bin/head -c ", Size/binary,
                    " > ", (quote(Log))/binary, " && ", Native/binary,
                    "-S ", Done/binary, " && exec /bin/cat >/dev/null">>,
                {ok, Wait} = tmux_command:wait_for(Done, wait),
                {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
                {ok, _} = tmux_pane:pipe(Pane, #{shell => Consumer}, #{}),
                {ok, Signal} = tmux_command:wait_for(Start, signal),
                {ok, _} = tmux_server:command(Server, Signal, #{}),
                {ok, #{cleanup := complete}} =
                    tmux_operation:await(Operation, 900),
                {ok, Payload} = file:read_file(Log),
                {ok, _} = tmux_pane:stop_pipe(Pane),
                #{log => Payload, bytes_written => byte_size(Payload),
                  consumer_acknowledged => true}
            end, fun() ->
                {ok, _} = tmux_session:kill(Session),
                ok
            end)
        end, fun() ->
            ok = tmux_server:close(Server)
        end)
    end, fun() ->
        ok = file:del_dir_r(Directory)
    end).

quote(Value) ->
    Escaped = binary:replace(Value, <<"'">>, <<"'\\''">>, [global]),
    <<"'", Escaped/binary, "'">>.
