-module(tmux_diagnostics_SUITE).
-compile(nowarn_missing_spec).
-behaviour(logger_handler).
-export([all/0, init_per_suite/1, end_per_suite/1, bounded_reports/1, log/2]).

%% Outer: real helper/tmux boundaries and a synchronous, owned Logger handler.
all() -> [bounded_reports].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    [{executable, list_to_binary(Executable)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

bounded_reports(Config) ->
    Level = logger:get_module_level(tmux_log),
    Tag = make_ref(),
    Caller = self(),
    Filter = fun
        (#{meta := #{domain := [libtmux | _]}} = Event, _) -> Event;
        (#{meta := #{pid := Pid}} = Event, _) when Pid =:= Caller -> Event;
        (_, _) -> stop
    end,
    ok = logger:add_handler(tmux_diagnostics_test, ?MODULE,
        #{level => all, filter_default => stop,
          filters => [{owned_domain, {Filter, none}}],
          config => #{recipient => self(), tag => Tag}}),
    try
        ok = logger:set_module_level(tmux_log, debug),
        transport_reports(Tag),
        channel_credit(Tag),
        owned_cleanup(Tag, proplists:get_value(executable, Config)),
        tmux_test_fixture:with_server(proplists:get_value(executable, Config),
            fun(Server, Fixture) -> capture_and_operation(Tag, Server, Fixture) end),
        ok = logger:set_module_level(tmux_log, none),
        flush(Tag),
        {ok, #{cleanup := complete}} = tmux_transport:run(<<"/bin/true">>, [], #{}),
        receive {Tag, _} -> ct:fail(disabled_logger_emitted) after 0 -> ok end
    after
        ok = logger:remove_handler(tmux_diagnostics_test),
        case Level of
            [] -> ok = logger:unset_module_level(tmux_log);
            [{tmux_log, Previous}] -> ok = logger:set_module_level(tmux_log, Previous)
        end,
        flush(Tag)
    end.

log(Event, #{config := #{recipient := Pid, tag := Tag}}) ->
    Pid ! {Tag, Event},
    ok.

transport_reports(Tag) ->
    Secret = <<"not-a-log-field\n", 0, 255>>,
    {ok, Handle = {transport, _, Token}} = tmux_transport:start(<<"/bin/cat">>, [],
        #{stdin => Secret, env => #{<<"PRIVATE_VALUE">> => <<"not-a-log-field">>}}),
    try
        {ok, #{stdout := Secret, cleanup := complete}} = tmux_transport:await(Handle, 900),
        #{event := transport_result, transport := Token, result := ok,
          stdout_bytes := 18, stderr_bytes := 0, stdin_delivered := 18,
          cleanup := complete, duration_us := Duration} =
            report(Tag, transport_result, transport, Token),
        true = is_integer(Duration) andalso Duration >= 0
    after ok = tmux_transport:close(Handle)
    end,
    {ok, Missing = {transport, _, MissingToken}} =
        tmux_transport:start(<<"/no-such-not-a-log-field">>, [], #{}),
    try
        {error, #{code := exec_failed, cleanup := complete}} =
            tmux_transport:await(Missing, 900),
        #{code := exec_failed, result := error, outcome := not_started} =
            report(Tag, transport_result, transport, MissingToken)
    after ok = tmux_transport:close(Missing)
    end,
    {ok, Limited = {transport, _, LimitToken}} = tmux_transport:start(
        <<"/usr/bin/printf">>, [<<"12345">>], #{max_stdout => 4}),
    try
        {error, #{code := output_limit, cleanup := complete}} =
            tmux_transport:await(Limited, 900),
        #{code := output_limit, stdout_bytes := 4} =
            report(Tag, transport_result, transport, LimitToken)
    after ok = tmux_transport:close(Limited)
    end.

channel_credit(Tag) ->
    {ok, Channel = {transport, _, Token, _}} =
        tmux_transport:start_channel(<<"/bin/cat">>, [], #{}),
    try
        {ok, _} = tmux_transport:await_started(Channel, 900),
        {ok, Write} = tmux_transport:write(Channel, <<"data">>),
        receive {tmux_transport, Channel, {write_ack, Write, 4}} -> ok
        after 900 -> ct:fail(channel_write_timeout)
        end,
        receive {tmux_transport, Channel, {data, stdout, Sequence, <<"data">>}} ->
            #{stream := stdout, sequence := Sequence, held_bytes := 4} =
                report(Tag, transport_credit_held, transport, Token),
            ok = tmux_transport:ack(Channel, stdout, Sequence)
        after 900 -> ct:fail(channel_read_timeout)
        end,
        {ok, _} = tmux_transport:cancel(Channel),
        {error, #{cleanup := complete}} = tmux_transport:await(Channel, 900)
    after ok = tmux_transport:close(Channel)
    end.

capture_and_operation(Tag, Server, Fixture) ->
    {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"new-session">>, <<"-d">>, <<"-s">>, <<"not-a-log-field">>, <<"/bin/cat">>]),
    {ok, Command} = tmux_command:raw(<<"display-message">>,
        [<<"-p">>, <<"not-a-log-field">>]),
    {ok, Operation = {operation, _, Generation, Id}} =
        tmux_operation:start(Server, Command, #{}),
    {ok, #{outcome := success, cleanup := complete}} = tmux_operation:await(Operation, 900),
    #{generation := Generation, outcome := success, cleanup := complete,
      phase := retired, result := ok} = report(Tag, operation_result, operation, Id),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    #{id := Capture} = tmux_snapshot:metadata(Snapshot),
    #{generation := Generation, result := ok, source_calls := Calls} =
        report(Tag, capture_result, capture, Capture),
    true = Calls > 6,
    flush(Tag),
    {error, #{code := capture_limit}} = tmux_server:snapshot(Server, #{max_rows => 1}),
    receive
        {Tag, #{msg := {report, #{event := capture_result, result := error,
                                 code := capture_limit} = Failure}}} -> safe(Failure)
    after 0 -> ct:fail(missing_capture_rejection_report)
    end.

owned_cleanup(Tag, Executable) ->
    {ok, Server, Ownership = {owned_server, Owner, Token}} =
        tmux_server:start_owned(#{executable => Executable}),
    {ok, #{endpoint := #{socket_path := Socket}}} =
        tmux_server:observation_context(Server),
    Marker = filename:join(filename:dirname(Socket), <<"not-a-log-field">>),
    try
        ok = file:write_file(Marker, <<"retained">>),
        {error, #{code := cleanup_incomplete, process_cleanup := complete}} =
            tmux_server:stop_owned(Ownership),
        #{code := cleanup_incomplete} =
            report(Tag, owned_server_cleanup_incomplete, ownership, Token),
        {error, #{code := cleanup_incomplete}} = tmux_server:stop_owned(Ownership),
        receive
            {Tag, #{msg := {report, #{event := owned_server_cleanup_incomplete,
                                     ownership := Token}}}} -> ct:fail(duplicate_warning)
        after 0 -> ok
        end,
        AppState = make_ref(),
        AppState = libtmux_erlang_app:prep_stop(AppState),
        #{failed_owners := 1, code := owned_cleanup_incomplete} =
            report(Tag, owned_server_shutdown_incomplete, scope, application),
        ok = logger:set_module_level(tmux_log, none),
        flush(Tag),
        AppState = libtmux_erlang_app:prep_stop(AppState),
        receive {Tag, _} -> ct:fail(disabled_shutdown_logger_emitted) after 0 -> ok end
    after
        ok = logger:set_module_level(tmux_log, debug),
        #{recovery_report := Recovery} = sys:get_state(Owner),
        _ = file:delete(Marker),
        ok = tmux_server:stop_owned(Ownership),
        case Recovery of
            {ok, File} -> ok = file:delete(File), ok = file:del_dir(filename:dirname(File));
            _ -> ok
        end
    end.

report(Tag, Event, Key, Identity) ->
    receive
        {Tag, #{meta := #{domain := [libtmux, _]},
                msg := {report, #{event := Event, Key := Identity} = Report}}} ->
            safe(Report),
            Report
    after 0 -> ct:fail({missing_report, Event})
    end.

safe(Report) ->
    Encoded = term_to_binary(Report),
    true = byte_size(Encoded) < 1536,
    nomatch = binary:match(Encoded, <<"not-a-log-field">>),
    true = lists:all(fun(Value) ->
        is_atom(Value) orelse is_reference(Value) orelse is_integer(Value)
    end, maps:values(Report)),
    ok.

flush(Tag) -> receive {Tag, _} -> flush(Tag) after 0 -> ok end.
