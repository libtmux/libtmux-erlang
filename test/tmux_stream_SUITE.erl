-module(tmux_stream_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, delivers_and_accounts/1,
         bounded_subscribers/1, abandoned_join/1, delayed_activation/1,
         retired_before_activation/1, fragmented_output/1, owner_death/1,
         session_retirement/1, borrowed_refusal/1]).

%% Outer: a real control attachment delivers pane bytes and notifications.
all() -> [delivers_and_accounts, bounded_subscribers, abandoned_join, delayed_activation,
          retired_before_activation, fragmented_output, owner_death, session_retirement,
          borrowed_refusal].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    [{executable, list_to_binary(Executable)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

delivers_and_accounts(Config) ->
    with_session(Config, fun(Server, Session, Pane, Window) ->
        {ok, Sub = {tmux_stream, Control, _}} = tmux_stream:subscribe(Server, Session, #{}),
        {ok, #{child_pid := Client, helper_pid := Helper, identity := same_connection}} =
            tmux_control:status(Control),
        Processes = [{Pid, observed(Pid)} || Pid <- [Client, Helper]],
        try
            {ok, Slow} = tmux_stream:join(Sub, #{credit => #{bytes => 1, messages => 8}}),
            {ok, _} = tmux_window:rename(Window, <<"first">>),
            {Generation, First, FirstSize} = rename_event(Sub, <<"first">>),
            receive
                {tmux_stream, Slow, {gap, Generation, #{after_sequence := 0, extent := unknown,
                                                        reason := credit_exhausted}}} -> ok
            after 900 -> ct:fail(missing_credit_gap)
            end,
            {error, #{code := subscription_closed}} =
                tmux_stream:demand(Slow, #{bytes => 1, messages => 1}),
            {ok, _} = tmux_window:rename(Window, <<"second">>),
            {Generation, Second, SecondSize} = rename_event(Sub, <<"second">>),
            true = Second > First,
            check_ack(Sub, Generation, {First, FirstSize}, {Second, SecondSize}),
            Expected = <<"bytes", 0, 9, 92, 195, 169, 13, 10>>,
            {ok, _} = tmux_pane:send_text(Pane, <<"go\n">>),
            Expected = pane_output(Sub, tmux_model:get(id, Pane), Generation, byte_size(Expected))
        after ok = tmux_stream:close(Sub)
        end,
        ok = tmux_stream:close(Sub),
        {ok, #{phase := closed, cleanup := complete}} = tmux_control:status(Control),
        detached(Session, Server),
        lists:foreach(fun({Pid, Identity}) ->
            {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid)
        end, Processes)
    end).

check_ack(Sub, Generation, {First, FirstSize}, {Second, SecondSize}) ->
    {error, #{code := credit_limit}} = tmux_stream:demand(Sub, #{bytes => 0, messages => 1}),
    {error, #{code := credit_limit}} = tmux_stream:demand(Sub, #{bytes => 1, messages => 0}),
    {error, #{code := invalid_ack}} = tmux_stream:ack(Sub, make_ref(), First),
    {error, #{code := invalid_ack}} = tmux_stream:ack(Sub, Generation, Second + 100),
    ok = tmux_stream:ack(Sub, Generation, Second),
    ok = tmux_stream:ack(Sub, Generation, Second),
    ok = tmux_stream:demand(Sub, #{bytes => SecondSize, messages => 1}),
    {error, #{code := credit_limit}} = tmux_stream:demand(Sub, #{bytes => 0, messages => 1}),
    {error, #{code := credit_limit}} = tmux_stream:demand(Sub, #{bytes => 1, messages => 0}),
    ok = tmux_stream:ack(Sub, Generation, First),
    ok = tmux_stream:demand(Sub, #{bytes => FirstSize, messages => 1}).

rename_event(Sub, Name) ->
    Size = byte_size(Name),
    {Generation, Sequence, Window} = take_event(Sub, fun
        ({event, Gen, Seq, {notification, <<"window-renamed">>, Fields}}) ->
            case binary:split(Fields, <<" ">>) of
                [Id, Name] -> {match, {Gen, Seq, Id}};
                _ -> skip
            end;
        (_) -> skip
    end, deadline()),
    {Generation, Sequence, byte_size(<<"window-renamed ">>) + byte_size(Window) + Size}.

pane_output(Sub, Pane, Generation, Count) ->
    pane_output(Sub, Pane, Generation, Count, [], deadline()).

pane_output(_, _, _, 0, Parts, _) -> iolist_to_binary(lists:reverse(Parts));
pane_output(Sub, Pane, Generation, Remaining, Parts, Deadline) ->
    Bytes = take_event(Sub, fun
        ({event, Gen, _, {pane_output, Id, Data}}) when Id =:= Pane, Gen =:= Generation -> {match, Data};
        (_) -> skip
    end, Deadline),
    true = byte_size(Bytes) =< Remaining,
    pane_output(Sub, Pane, Generation, Remaining - byte_size(Bytes), [Bytes | Parts], Deadline).

take_event(Sub, Match, Deadline) ->
    receive
        {tmux_stream, Sub, {gap, _, Cause}} -> ct:fail({unexpected_gap, Cause});
        {tmux_stream, Sub, Message} ->
            case Match(Message) of
                {match, Value} -> Value;
                skip -> take_event(Sub, Match, Deadline)
            end
    after max(0, Deadline - erlang:monotonic_time(millisecond)) -> ct:fail(missing_stream_event)
    end.

bounded_subscribers(Config) ->
    with_session(Config, fun(Server, Session, _, _) ->
        {ok, Sub} = tmux_stream:subscribe(Server, Session, #{}),
        try
            Joined = [begin {ok, Item} = tmux_stream:join(Sub, #{}), Item end || _ <- lists:seq(1, 15)],
            {error, #{code := subscriber_limit}} = tmux_stream:join(Sub, #{}),
            [First | Rest] = Joined,
            ok = tmux_stream:close(First),
            {ok, Again} = tmux_stream:join(Sub, #{}),
            lists:foreach(fun(Item) -> ok = tmux_stream:close(Item) end, [Again | Rest]),
            {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
            1 = tmux_model:get(attached_count, Current)
        after ok = tmux_stream:close(Sub)
        end,
        detached(Session, Server)
    end).

abandoned_join(Config) ->
    with_session(Config, fun(Server, Session, _, _) ->
        {ok, Sub = {tmux_stream, {control, Controller, _} = Control, _}} =
            tmux_stream:subscribe(Server, Session, #{}),
        Parent = self(),
        try
            ok = sys:suspend(Controller),
            Caller = spawn(fun() ->
                Parent ! {joined, self(), tmux_stream:join(Sub, #{})},
                receive finish -> ok end
            end),
            try
                try
                    receive
                        {joined, Caller, {error, #{code := await_timeout}}} -> ok
                    after 990 -> ct:fail(join_did_not_timeout)
                    end
                after ok = sys:resume(Controller)
                end,
                {ok, _} = tmux_control:status(Control),
                #{stream := #{subscribers := Subscribers}} = sys:get_state(Controller),
                1 = map_size(Subscribers),
                {messages, []} = process_info(Caller, messages)
            after Caller ! finish
            end
        after ok = tmux_stream:close(Sub)
        end
    end).

delayed_activation(Config) ->
    with_session(Config, fun(Server, Session, _, Window) ->
        {ok, Sub} = tmux_stream:subscribe(Server, Session, #{}),
        try
            Deadline = erlang:monotonic_time(millisecond) + 200,
            Joined = reserve_join(Sub, Deadline),
            Timer = erlang:start_timer(Deadline, self(), activate, [{abs, true}]),
            receive {timeout, Timer, activate} -> ok
            after 750 -> ct:fail(activation_timer_missing)
            end,
            ok = activate(Joined),
            ok = tmux_stream:demand(Joined, #{bytes => 0, messages => 0}),
            {ok, _} = tmux_window:rename(Window, <<"joined">>),
            {_, _, _} = rename_event(Joined, <<"joined">>),
            ok = tmux_stream:close(Joined)
        after ok = tmux_stream:close(Sub)
        end
    end).

retired_before_activation(Config) ->
    with_session(Config, fun(Server, Session, _, _) ->
        {ok, Sub} = tmux_stream:subscribe(Server, Session, #{}),
        try
            Joined = reserve_join(Sub, deadline()),
            {ok, _} = tmux_session:kill(Session),
            Allowed = [control_eof, control_exit],
            Id = tmux_model:get(id, Session),
            ok = await_session_end(Sub, Id, Allowed, deadline()),
            ok = activate(Joined),
            ok = await_session_end(Joined, Id, Allowed, deadline())
        after ok = tmux_stream:close(Sub)
        end
    end).

reserve_join({tmux_stream, Control, Anchor}, Deadline) ->
    Id = make_ref(),
    Credit = #{bytes => 65536, messages => 8},
    ok = tmux_control:request(Control, {stream, Anchor, {join, Id, Credit, Deadline}}, 900),
    {tmux_stream, Control, Id}.

activate({tmux_stream, Control, Id}) -> tmux_control:resolve_stream(Control, Id, activate).

fragmented_output(_) ->
    Generation = make_ref(),
    Control = {control, self(), Generation},
    Id = make_ref(),
    Sub = {tmux_stream, Control, Id},
    Pending = tmux_stream:new(self(), Control, Generation, {Id, #{bytes => 64, messages => 1}}),
    Active = tmux_stream:resolve(Id, self(), activate, Pending),
    {ok, [], Part} = tmux_control_codec:feed(tmux_control_codec:new(Generation), <<"%output %7 \\0">>),
    {ok, [], Partial} = tmux_control_codec:feed(Part, <<"00\\134", 195>>),
    {ok, [{notification, Generation, Line}], Complete} =
        tmux_control_codec:feed(Partial, <<169, "\\015\\012\n">>),
    ok = tmux_control_codec:finish(Complete),
    {ok, Delivered} = tmux_stream:event(Line, Active),
    receive
        {tmux_stream, Sub, {event, Generation, 1, {pane_output, <<"%7">>, <<0, 92, 195, 169, 13, 10>>}}} ->
            ok
    after 0 -> ct:fail(misdecoded_output)
    end,
    Retired = tmux_stream:finish(closed, Delivered),
    true = tmux_stream:empty(Retired).

owner_death(Config) ->
    with_session(Config, fun(Server, Session, _, _) ->
        Parent = self(),
        {Owner, Monitor} = spawn_monitor(fun() ->
            {ok, Sub} = tmux_stream:subscribe(Server, Session, #{}),
            Parent ! {subscribed, self(), Sub},
            receive finish -> ok end
        end),
        try
            Sub = receive {subscribed, Owner, Value} -> Value
                  after 900 -> ct:fail(owner_not_subscribed)
                  end,
            {tmux_stream, Control, _} = Sub,
            {ok, #{generation := Generation, child_pid := Client, helper_pid := Helper}} =
                tmux_control:status(Control),
            Processes = [{Pid, observed(Pid)} || Pid <- [Client, Helper]],
            {ok, Joined} = tmux_stream:join(Sub, #{}),
            exit(Owner, kill),
            receive {'DOWN', Monitor, process, Owner, killed} -> ok
            after 900 -> ct:fail(owner_still_alive)
            end,
            receive {tmux_stream, Joined, {closed, Generation, owner_down}} -> ok
            after 900 -> ct:fail(subscriber_not_closed)
            end,
            ok = tmux_stream:close(Joined),
            detached(Session, Server),
            lists:foreach(fun({Pid, Identity}) ->
                {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid)
            end, Processes),
            {ok, Next = {tmux_stream, Replacement, _}} = tmux_stream:subscribe(Server, Session, #{}),
            try
                {ok, #{generation := Other}} = tmux_control:status(Replacement),
                true = Other =/= Generation
            after ok = tmux_stream:close(Next)
            end
        after exit(Owner, kill)
        end
    end).

session_retirement(Config) ->
    retire_session(Config, <<"on">>, [control_exit, control_eof]),
    retire_session(Config, <<"off">>, [stream_session_changed]).

retire_session(Config, DetachOnDestroy, Reasons) ->
    with_session(Config, fun(Server, Session, _, _) ->
        {ok, Other} = tmux_session:create(Server, #{name => <<"remaining">>,
            launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, _} = tmux_option:set(Session, <<"detach-on-destroy">>, DetachOnDestroy),
        {ok, Sub = {tmux_stream, Control, _}} = tmux_stream:subscribe(Server, Session, #{}),
        {ok, #{child_pid := Client, helper_pid := Helper}} = tmux_control:status(Control),
        Processes = [{Pid, observed(Pid)} || Pid <- [Client, Helper]],
        try
            {ok, _} = tmux_session:kill(Session),
            ok = await_session_end(Sub, tmux_model:get(id, Session), Reasons, deadline())
        after ok = tmux_stream:close(Sub)
        end,
        {ok, #{phase := closed, cleanup := complete}} = tmux_control:status(Control),
        detached(Other, Server),
        lists:foreach(fun({Pid, Identity}) ->
            {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid)
        end, Processes)
    end).

await_session_end(Sub, Session, Reasons, Deadline) ->
    receive
        {tmux_stream, Sub, {gap, _, #{reason := Reason}}} ->
            case lists:member(Reason, Reasons) of
                true -> ok;
                false -> ct:fail({unexpected_retirement, Reason})
            end;
        {tmux_stream, Sub, {event, _, _, {notification, <<"session-changed">>, Target}}} ->
            case binary:split(Target, <<" ">>) of
                [Session, _] -> await_session_end(Sub, Session, Reasons, Deadline);
                _ -> ct:fail({stream_changed_session, Target})
            end;
        {tmux_stream, Sub, _} -> await_session_end(Sub, Session, Reasons, Deadline)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) -> ct:fail(stream_survived_session)
    end.

borrowed_refusal(Config) ->
    Executable = proplists:get_value(executable, Config),
    with_session(Config, fun(Server, Session, _, _) ->
        {ok, #{endpoint := #{socket_path := Socket}}} = tmux_server:observation_context(Server),
        {ok, Borrowed} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try
            {ok, Current} = tmux_session:get(Borrowed, tmux_model:get(id, Session)),
            {error, #{code := stream_requires_owned_server, cleanup := complete}} =
                tmux_stream:subscribe(Borrowed, Current, #{}),
            detached(Session, Borrowed)
        after ok = tmux_server:close(Borrowed)
        end
    end).

detached(Session, Server) ->
    {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
    0 = tmux_model:get(attached_count, Current),
    ok.

with_session(Config, Check) ->
    Executable = proplists:get_value(executable, Config),
    Code = <<"stty -echo; printf 'ready\\n'; IFS= read -r line; "
             "printf 'bytes\\000\\011\\134\\303\\251\\n'; IFS= read -r line">>,
    {ok, Server, Ownership} = tmux_server:start_owned(#{executable => Executable}),
    try
        {ok, Session} = tmux_session:create(Server, #{name => <<"streams">>,
            window_name => <<"initial">>, launch => #{argv => [<<"/bin/sh">>, <<"-c">>, Code]}}),
        {ok, Graph} = tmux_server:snapshot(Server),
        [Pane] = tmux_snapshot:panes(Graph),
        [Window] = tmux_snapshot:windows(Graph),
        {ok, _} = tmux_pane:wait_for_text(Pane, <<"ready">>, #{deadline_ms => 750}),
        Check(Server, Session, Pane, Window)
    after ok = tmux_server:stop_owned(Ownership)
    end.

observed(Pid) ->
    {ok, Identity} = tmux_identity:observe(Pid),
    Identity.

deadline() -> erlang:monotonic_time(millisecond) + 900.
