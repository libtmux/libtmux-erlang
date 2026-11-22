-module(tmux_pane_text_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         notices_visible_text/1, cancel_and_deadline/1, refuses_respawn/1,
         retires_admitted_capture/1, endpoint_death_retires_result/1,
         borrowed_endpoint/1, borrowed_replacement/1]).

%% Outer: observe real text and lifetime changes on a private daemon.
all() -> [notices_visible_text, cancel_and_deadline, refuses_respawn,
          retires_admitted_capture, endpoint_death_retires_result,
          borrowed_endpoint, borrowed_replacement].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

borrowed_endpoint(Config) ->
    Executable = proplists:get_value(executable, Config),
    tmux_test_fixture:with_server(Executable, fun(Server, Fixture) ->
        Pane = start_pane(Server),
        Text = <<"borrowed-pane-ready">>,
        Options = #{deadline_ms => 900, max_bytes => 4096},
        {ok, Wait} = tmux_pane_text:start(Pane, Text, Options),
        {ok, _} = tmux_pane:send_text(Pane, Text),
        {ok, #{screen := Screen}} = tmux_pane_text:await(Wait, 900),
        {_, _} = binary:match(Screen, Text),
        ok = tmux_pane_text:release(Wait),
        {ok, Cancelled} = tmux_pane_text:start(Pane, <<"absent">>, Options),
        {ok, cancel_requested} = tmux_pane_text:cancel(Cancelled),
        {error, #{code := cancelled, cleanup := complete}} =
            tmux_pane_text:await(Cancelled, 900),
        ok = tmux_pane_text:release(Cancelled),
        {ok, #{owner := Endpoint, operations := 0}} = tmux_server:status(Server),
        #{closing_watchers := Watchers} = sys:get_state(Endpoint),
        0 = map_size(Watchers),
        ok = tmux_server:close(Server),
        {ok, #{stdout := Screen}} = tmux_test_fixture:command(Fixture,
            [<<"capture-pane">>, <<"-p">>, <<"-t">>, tmux_model:get(id, Pane)])
    end).

borrowed_replacement(Config) ->
    Executable = proplists:get_value(executable, Config),
    tmux_test_fixture:with_server(Executable, fun(Server, Fixture) ->
        Pane = start_pane(Server),
        {ok, Wait} = tmux_pane_text:start(Pane, <<"replacement">>,
                                         #{deadline_ms => 900}),
        Observer = element(2, Wait),
        ok = sys:suspend(Observer),
        try
            ok = tmux_test_fixture:replace(Fixture),
            #{socket := Socket} = tmux_test_fixture:info(Fixture),
            {ok, Replacement} = tmux_server:open(#{socket_path => Socket,
                                                  executable => Executable}),
            try
                NextPane = start_pane(Replacement),
                Id = tmux_model:get(id, Pane),
                Id = tmux_model:get(id, NextPane),
                {ok, _} = tmux_pane:send_text(NextPane, <<"replacement">>)
            after ok = tmux_server:close(Replacement)
            end
        after ok = sys:resume(Observer)
        end,
        {error, #{code := stale_pane, cleanup := complete}} =
            tmux_pane_text:await(Wait, 900),
        ok = tmux_pane_text:release(Wait)
    end).

notices_visible_text(Config) ->
    with_pane(Config, fun(Server, Pane) ->
        {ok, #{owner := Endpoint}} = tmux_server:status(Server),
        Text = <<"ready-for-input">>,
        Options = #{deadline_ms => 900, max_bytes => 4096},
        {ok, Wait} = tmux_pane_text:start(Pane, Text, Options),
        {error, #{code := await_timeout}} = tmux_pane_text:await(Wait, 0),
        {ok, _} = tmux_pane:send_text(Pane, Text),
        {ok, #{screen := Screen}} = tmux_pane_text:await(Wait, 900),
        {_, _} = binary:match(Screen, Text),
        ok = tmux_pane_text:release(Wait),
        {error, #{code := pane_wait_expired}} = tmux_pane_text:await(Wait, 900),
        #{closing_watchers := Watchers} = sys:get_state(Endpoint),
        0 = map_size(Watchers),
        {ok, #{screen := Screen}} = tmux_pane:wait_for_text(Pane, Text, Options)
    end).

cancel_and_deadline(Config) ->
    with_pane(Config, fun(Server, Pane) ->
        {ok, Probe} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"#{pid}">>]),
        Expired = erlang:monotonic_time(millisecond) - 1,
        {error, #{code := deadline, submitted := false, cleanup := complete}} =
            tmux_operation:start_before(Server, Probe, #{}, Expired),
        Missing = <<"absent">>,
        {ok, Wait} = tmux_pane_text:start(Pane, Missing, #{deadline_ms => 900}),
        {error, #{code := pane_wait_active}} = tmux_pane_text:release(Wait),
        {ok, cancel_requested} = tmux_pane_text:cancel(Wait),
        {error, #{code := cancelled, cleanup := complete}} = tmux_pane_text:await(Wait, 900),
        {error, #{code := deadline, cleanup := complete}} =
            tmux_pane:wait_for_text(Pane, Missing, #{deadline_ms => 100}),
        {error, #{code := output_limit, cleanup := complete}} =
            tmux_pane_text:start(Pane, <<"x">>, #{deadline_ms => 900, max_bytes => 1})
    end).

refuses_respawn(Config) ->
    with_pane(Config, fun(_, Pane) ->
        {ok, Wait} = tmux_pane_text:start(Pane, <<"replacement">>, #{deadline_ms => 900}),
        {ok, _} = tmux_pane:respawn(Pane,
            #{force => true, launch => #{argv => [<<"/bin/cat">>]}}),
        {error, #{code := stale_pane, cleanup := complete}} = tmux_pane_text:await(Wait, 900)
    end).

retires_admitted_capture(Config) ->
    with_pane(Config, fun(Server, Pane) ->
        Needle = <<"absent">>,
        Options = #{deadline_ms => 900},
        {ok, Wait} = tmux_pane_text:start(Pane, Needle, Options),
        Capture = park_capture(Server, Wait),
        {ok, cancel_requested} = tmux_pane_text:cancel(Wait),
        {error, #{code := cancelled, cleanup := complete}} = tmux_pane_text:await(Wait, 900),
        {ok, #{phase := retired, cleanup := complete}} = tmux_operation:status(Capture),
        Caller = self(),
        {Owner, OwnerMonitor} = spawn_monitor(fun() ->
            Caller ! {self(), tmux_pane_text:start(Pane, Needle, Options)},
            receive finish -> ok end
        end),
        try
            OwnedWait = receive
                {Owner, {ok, Value}} -> Value;
                {'DOWN', OwnerMonitor, process, Owner, Reason} -> ct:fail({owner_stopped, Reason})
            after 900 -> ct:fail(missing_wait)
            end,
            Observer = element(2, OwnedWait),
            Monitor = monitor(process, Observer),
            OwnedCapture = park_capture(Server, OwnedWait),
            Owner ! finish,
            receive {'DOWN', Monitor, process, Observer, normal} -> ok
            after 900 -> ct:fail(observer_alive)
            end,
            {ok, #{phase := retired, cleanup := complete}} = tmux_operation:status(OwnedCapture)
        after Owner ! finish
        end
    end).

park_capture(Server, {pane_text, Observer, _}) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Ready = <<"pane-text-admitted-", Suffix/binary>>,
    Blocked = <<"pane-text-park-", Suffix/binary>>,
    {ok, Listen} = tmux_command:wait_for(Ready, wait),
    {ok, ReadyWait} = tmux_operation:start(Server, Listen, #{deadline_ms => 900}),
    {ok, Signal} = tmux_command:wait_for(Ready, signal),
    {ok, Park} = tmux_command:wait_for(Blocked, wait),
    % Park inside tmux after admission and before invoking the capture.
    _ = sys:replace_state(Observer, fun(#{command := Read} = State) ->
        {ok, Command} = tmux_command:sequence([Signal, Park, Read]),
        State#{command => Command}
    end),
    {ok, _} = tmux_operation:await(ReadyWait, 900),
    #{operation := Capture} = sys:get_state(Observer),
    {ok, #{phase := sent}} = tmux_operation:status(Capture),
    Capture.

endpoint_death_retires_result(Config) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try
        #{socket := Socket, server_pid := Daemon} = tmux_test_fixture:info(Fixture),
        {ok, #{stdout := <<"tmux ", Raw/binary>>}} =
            tmux_transport:run(Executable, [<<"-V">>], #{timeout_ms => 500, max_stdout => 64}),
        Identity = <<(integer_to_binary(Daemon))/binary, $\t, (string:trim(Raw))/binary, $\n>>,
        Native = #{executable => Executable, socket_path => Socket},
        {ok, Server} = tmux_server:open_observed(self(), Native, Identity),
        try
            Pane = start_pane(Server),
            ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane)),
            Text = <<"completed">>,
            {ok, Wait} = tmux_pane_text:start(Pane, Text, #{deadline_ms => 900}),
            {ok, _} = tmux_pane:send_text(Pane, Text),
            {ok, _} = tmux_pane_text:await(Wait, 900),
            {ok, #{owner := Endpoint}} = tmux_server:status(Server),
            Observer = element(2, Wait),
            Monitor = monitor(process, Observer),
            ok = sys:terminate(Endpoint, shutdown),
            receive {'DOWN', Monitor, process, Observer, normal} -> ok
            after 900 -> ct:fail(cached_result_survived_endpoint)
            end,
            {error, #{code := pane_wait_expired}} = tmux_pane_text:await(Wait, 900)
        after _ = tmux_server:close(Server)
        end
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end.

with_pane(Config, Function) ->
    Executable = proplists:get_value(executable, Config),
    {ok, _} = tmux_server:with_owned(#{executable => Executable}, fun(Server) ->
        Function(Server, start_pane(Server))
    end).

start_pane(Server) ->
    {ok, _} = tmux_session:create(Server,
        #{name => <<"pane-observation">>, width => 70, height => 8,
          launch => #{argv => [<<"/bin/cat">>]}}),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    [Pane] = tmux_snapshot:panes(Snapshot),
    Pane.
