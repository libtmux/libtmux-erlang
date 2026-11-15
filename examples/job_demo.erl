-module(job_demo).
-moduledoc "Capture a job that acknowledges terminal parsing before it exits.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"jobs">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            {ok, Window} = tmux_window:create(Session,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
            {ok, _} = tmux_option:set(
                Window, <<"remain-on-exit-format">>, <<>>),
            Escript = os:find_executable("escript"),
            JobFile = filename:absname("examples/terminal_job.erl"),
            Launch = #{argv => [list_to_binary(Escript),
                list_to_binary(JobFile)]},
            {ok, Job} = tmux_pane:split(Window, #{launch => Launch}),
            {ok, #{exit := {status, 0}, pane := Completed}} =
                tmux_pane:wait_exit(Job, #{deadline_ms => 5000}),
            true = tmux_model:get(dead, Completed),
            {ok, <<"build complete\n">>} = tmux_pane:capture(
                Completed, #{start => 0, 'end' => 0}),
            Deadline = #{deadline_ms => 6000},
            {ok, Never} = tmux_command:raw(
                <<"wait-for">>, [<<"not-signalled">>]),
            {ok, Operation} = tmux_operation:start(Server, Never, Deadline),
            {error, #{code := await_timeout}} =
                tmux_operation:await(Operation, 0),
            {ok, _} = tmux_operation:await_started(Operation, 900),
            {ok, cancel_requested} = tmux_operation:cancel(Operation),
            {error, #{outcome := unknown, cleanup := complete}} =
                tmux_operation:await(Operation, 900),
            #{output => <<"build complete\n">>, job_status => 0,
              await_timeout_kept_operation => true,
              cancelled_outcome => unknown}
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
