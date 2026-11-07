-module(tmux_admission_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

capacity_and_claim_test() ->
    Admission = tmux_admission:new(make_ref()),
    Deadline = now_ms() + 900,
    Leases = [begin
        {ok, Lease} = tmux_admission:reserve(Admission, self(), 1, Deadline), Lease
    end || _ <- lists:seq(1, 64)],
    ?assertMatch({error, #{code := busy}}, tmux_admission:reserve(Admission, self(), 1, Deadline)),
    [First | _] = Leases,
    ok = tmux_admission:deliver(Admission, First, 1, <<1>>),
    receive {tmux_admission, _, First, _, <<1>>} -> ok after 900 -> error(delivery) end,
    ?assertEqual(ok, tmux_admission:claim(Admission, First, self(), 1)),
    ?assertMatch({error, #{code := invalid_lease}}, tmux_admission:claim(Admission, First, self(), 1)),
    lists:foreach(fun(Lease) -> ok = tmux_admission:release(Admission, Lease) end, Leases),
    ?assertEqual(ok, tmux_admission:release(Admission, First)),
    ?assertMatch({ok, #{operations := 0, bytes := 0}}, tmux_admission:stats(Admission)),
    {ok, Large} = tmux_admission:reserve(Admission, self(), 262144, Deadline),
    ?assertMatch({error, #{code := busy}}, tmux_admission:reserve(Admission, self(), 1, Deadline)),
    ok = tmux_admission:release(Admission, Large),
    ok = tmux_admission:close(Admission),
    ?assertMatch({error, #{code := server_closed}}, tmux_admission:reserve(Admission, self(), 1, Deadline)).

owner_death_and_expiry_test() ->
    Admission = tmux_admission:new(make_ref()),
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        {ok, Lease} = tmux_admission:reserve(Admission, self(), 100, now_ms() + 900),
        Parent ! {lease, self(), Lease}
    end),
    Lease = receive {lease, Pid, Ref} -> Ref after 900 -> error(missing_lease) end,
    receive {'DOWN', Monitor, process, Pid, normal} -> ok after 900 -> error(owner_alive) end,
    [_] = tmux_admission:expire(Admission),
    ?assertMatch({ok, #{operations := 0, bytes := 0}}, tmux_admission:stats(Admission)),
    ?assertMatch({error, #{code := invalid_lease}}, tmux_admission:claim(Admission, Lease, Pid, 100)),
    Expires = now_ms() + 5,
    {ok, Expiring} = tmux_admission:reserve(Admission, self(), 100, Expires),
    Timer = erlang:start_timer(Expires, self(), expired, [{abs, true}]),
    receive {timeout, Timer, expired} -> ok after 900 -> error(expiry_timer) end,
    [_] = tmux_admission:expire(Admission),
    ?assertMatch({error, #{code := invalid_lease}}, tmux_admission:claim(Admission, Expiring, self(), 100)),
    ?assertMatch({ok, #{operations := 0, bytes := 0}}, tmux_admission:stats(Admission)).

now_ms() -> erlang:monotonic_time(millisecond).

revoke_before_capacity_release_test() ->
    Generation = make_ref(),
    Admission = tmux_admission:new(Generation),
    {ok, Lease} = tmux_admission:reserve(Admission, self(), 262144, now_ms() + 900),
    {ok, #{alias := Alias}} = tmux_admission:lookup(Admission, Lease),
    ok = tmux_admission:deliver(Admission, Lease, 262144, queued),
    ok = tmux_admission:release(Admission, Lease),
    Alias ! {tmux_admission, Generation, Lease, self(), late},
    {ok, Replacement} = tmux_admission:reserve(Admission, self(), 262144, now_ms() + 900),
    receive {tmux_admission, Generation, Lease, _, _} -> error(released_payload)
    after 0 -> ok
    end,
    ?assertMatch({ok, #{operations := 1, bytes := 262144}}, tmux_admission:stats(Admission)),
    ok = tmux_admission:release(Admission, Replacement).
