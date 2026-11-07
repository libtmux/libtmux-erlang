-module(job_demo).
-moduledoc "Capture a job that acknowledges terminal parsing before it exits.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    try
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"jobs">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        try
            {ok, Window} = tmux_window:create(Session,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            Target = [<<"-w">>, <<"-t">>, tmux_model:get(id, Window)],
            Deadline = #{deadline_ms => 2000},
            {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
            {ok, _} = tmux_option:set(
                Window, <<"remain-on-exit-format">>, <<>>),
            {ok, Hook} = tmux_command:raw(<<"set-hook">>,
                Target ++ [<<"pane-died">>, <<"wait-for -S job-finished">>]),
            {ok, _} = tmux_server:command(Server, Hook, #{}),
            {ok, Wait} = tmux_command:raw(<<"wait-for">>, [<<"job-finished">>]),
            {ok, Operation} = tmux_operation:start(Server, Wait, Deadline),
            {error, #{code := await_timeout}} =
                tmux_operation:await(Operation, 0),
            JobFile = filename:absname("examples/terminal_job.py"),
            Launch = #{argv => [<<"/usr/bin/python3">>,
                list_to_binary(JobFile)]},
            {ok, Job} = tmux_pane:split(Window, #{launch => #{shell => <<>>}}),
            {ok, _} = tmux_pane:respawn(Job, #{launch => Launch}),
            {ok, #{exit_status := 0, cleanup := complete}} =
                tmux_operation:await(Operation, 900),
            {ok, Completed} = tmux_pane:get(Server, tmux_model:get(id, Job)),
            true = tmux_model:get(dead, Completed),
            0 = tmux_model:get(exit_status, Completed),
            {ok, <<"build complete\n">>} = tmux_pane:capture(
                Completed, #{start => 0, 'end' => 0}),
            {ok, Never} = tmux_command:raw(
                <<"wait-for">>, [<<"not-signalled">>]),
            {ok, Cancelled} = tmux_operation:start(Server, Never, Deadline),
            {ok, _} = tmux_operation:await_started(Cancelled, 900),
            {ok, cancel_requested} = tmux_operation:cancel(Cancelled),
            {error, #{outcome := unknown, cleanup := complete}} =
                tmux_operation:await(Cancelled, 900),
            #{output => <<"build complete\n">>, job_status => 0,
              await_timeout_kept_operation => true,
              cancelled_outcome => unknown}
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
