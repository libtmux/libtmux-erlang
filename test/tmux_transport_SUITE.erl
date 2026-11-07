-module(tmux_transport_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         separate_output/1, input_and_arguments/1, output_limit/1,
         deadline/1, waiter_timeout/1, owner_death/1, exec_failure/1,
         incomplete_input/1, environment_and_cwd/1, asynchronous_requests/1]).

%% Outer: real subprocess ownership and bounded I/O through the packaged helper.
all() -> [separate_output, input_and_arguments, output_limit, deadline,
          waiter_timeout, owner_death, exec_failure, incomplete_input, environment_and_cwd,
          asynchronous_requests].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(libtmux_erlang).

separate_output(_Config) ->
    {ok, #{stdout := <<"%begin\nraw">>, stderr := <<"warning">>,
           exit_status := 7, cleanup := complete}} = tmux_transport:run(
        <<"/bin/sh">>, [<<"-c">>, <<"printf '%s' '%begin
raw'; printf warning >&2; exit 7">>], #{}).

input_and_arguments(_Config) ->
    Bytes = binary:copy(<<0, 255, 10, 65>>, 2300),
    {ok, #{stdout := Bytes, stderr := <<>>, exit_status := 0,
           stdin_delivered := 9200, cleanup := complete}} =
        tmux_transport:run(<<"/bin/cat">>, [], #{stdin => Bytes}),
    Literal = <<"$(false); ' ", 255>>,
    {ok, #{stdout := Literal, exit_status := 0}} = tmux_transport:run(
        <<"/usr/bin/printf">>, [<<"%s">>, Literal], #{}).

output_limit(_Config) ->
    {error, #{code := output_limit, stream := stdout, stdout := <<"1234">>,
              cleanup := complete, outcome := unknown}} = tmux_transport:run(
        <<"/usr/bin/printf">>, [<<"12345">>], #{max_stdout => 4}),
    {ok, #{stdout := <<"1234">>}} = tmux_transport:run(
        <<"/usr/bin/printf">>, [<<"1234">>], #{max_stdout => 4}).

deadline(_Config) ->
    {error, #{code := timeout, outcome := unknown, cleanup := complete}} =
        tmux_transport:run(<<"/usr/bin/python3">>,
            [<<"-c">>, <<"import signal; signal.pause()">>], #{timeout_ms => 40}).

waiter_timeout(_Config) ->
    {ok, Handle} = blocking_child(),
    try
        {ok, _} = tmux_transport:await_started(Handle, 900),
        {error, #{code := await_timeout}} = tmux_transport:await(Handle, 0),
        {ok, #{phase := running, cause := none, waiters := 0}} =
            tmux_transport:status(Handle),
        {ok, cancel_requested} = tmux_transport:cancel(Handle),
        {error, #{code := cancelled, outcome := unknown, cleanup := complete}} =
            tmux_transport:await(Handle, 900),
        receive Message -> ct:fail({stray_response, Message}) after 0 -> ok end
    after
        ok = tmux_transport:close(Handle)
    end.

owner_death(_Config) ->
    Parent = self(),
    Initiator = spawn(fun() ->
        {ok, Handle} = blocking_child(),
        {ok, Status} = tmux_transport:await_started(Handle, 900),
        Parent ! {ready, self(), Status},
        receive finish -> ok end
    end),
    receive
        {ready, Initiator, #{worker := Worker, helper_pid := Helper,
                             child_pid := Child}} ->
            HelperIdentity = process_identity(Helper),
            ChildIdentity = process_identity(Child),
            Monitor = monitor(process, Worker),
            exit(Initiator, kill),
            receive {'DOWN', Monitor, process, Worker, normal} -> ok
            after 900 -> ct:fail(owner_cleanup_timeout)
            end,
            false = same_process(Helper, HelperIdentity),
            false = same_process(Child, ChildIdentity)
    after 900 ->
        exit(Initiator, kill),
        ct:fail(start_timeout)
    end.

exec_failure(_Config) ->
    {error, #{code := exec_failed, outcome := not_started, cleanup := complete}} =
        tmux_transport:run(<<"/no-such-libtmux-executable">>, [], #{}).

incomplete_input(_Config) ->
    {error, #{code := stdin_write_failed, outcome := unknown, cleanup := complete,
              stdin_delivered := Delivered}} = tmux_transport:run(
        <<"/bin/true">>, [], #{stdin => binary:copy(<<65>>, 1048576)}),
    true = Delivered < 1048576.

environment_and_cwd(_Config) ->
    {ok, #{stdout := <<"/tmp\nvalue\nmissing\nmissing\n">>, exit_status := 0}} =
        tmux_transport:run(<<"/usr/bin/python3">>, [<<"-c">>,
            <<"import os; print(os.getcwd()); print(os.getenv('ONLY')); ",
              "print(os.getenv('TMUX','missing')); print(os.getenv('TMUX_PANE','missing'))">>],
            #{cwd => <<"/tmp">>, inherit_env => false,
              env => #{<<"ONLY">> => <<"value">>, <<"TMUX">> => <<"borrowed">>,
                       <<"TMUX_PANE">> => <<"%1">>}}).

blocking_child() ->
    tmux_transport:start(<<"/usr/bin/python3">>,
        [<<"-c">>, <<"import signal; signal.pause()">>], #{timeout_ms => 5000}).

asynchronous_requests(_Config) ->
    {ok, Handle} = blocking_child(),
    try
        {ok, #{worker := Worker}} = tmux_transport:await_started(Handle, 900),
        Requests0 = gen_server:reqids_new(),
        Requests1 = gen_server:reqids_add(tmux_transport:send_request(Handle, await),
                                          result, Requests0),
        Requests2 = gen_server:reqids_add(tmux_transport:send_request(Handle, retired),
                                          retirement, Requests1),
        ok = tmux_transport:cancel_async(Handle),
        Replies = async_replies(Requests2, #{}),
        #{result := {error, #{code := cancelled, cleanup := complete}},
          retirement := {error, #{code := cancelled, cleanup := complete}}} = Replies,
        Monitor = monitor(process, Worker),
        ok = tmux_transport:close_async(Handle),
        receive {'DOWN', Monitor, process, Worker, normal} -> ok
        after 900 -> ct:fail(async_close_timeout)
        end
    after
        _ = tmux_transport:close(Handle)
    end.

async_replies(Requests, Replies) ->
    case gen_server:reqids_size(Requests) of
        0 -> Replies;
        _ ->
            receive Message ->
                case gen_server:check_response(Message, Requests, true) of
                    {{reply, Reply}, Label, Remaining} ->
                        async_replies(Remaining, Replies#{Label => Reply});
                    Other -> ct:fail({unexpected_async_response, Other})
                end
            after 900 -> ct:fail(async_reply_timeout)
            end
    end.

process_identity(Pid) ->
    {ok, Stat} = file:read_file("/proc/" ++ integer_to_list(Pid) ++ "/stat"),
    %% comm may contain spaces and ')'; the final closing parenthesis ends it.
    {Position, 2} = lists:last(binary:matches(Stat, <<") ">>)),
    Tail = binary:part(Stat, Position + 2, byte_size(Stat) - Position - 2),
    lists:nth(20, binary:split(Tail, <<" ">>, [global])).

same_process(Pid, Identity) ->
    try process_identity(Pid) =:= Identity
    catch error:{badmatch, {error, enoent}} -> false
    end.
