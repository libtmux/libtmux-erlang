-module(tmux_registry_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

registered_owner_lifetime_test() ->
    {ok, Registry} = tmux_registry:start_link(),
    Parent = self(),
    {Owner, Monitor} = spawn_monitor(fun() ->
        Generation = make_ref(),
        Admission = tmux_admission:new(Generation),
        {ok, Origin, Registry} = tmux_registry:register(Generation, Admission),
        Parent ! {registered, self(), Origin, Generation},
        receive finish -> ok end
    end),
    try
        {Origin, Generation} = receive
            {registered, Owner, Ref, Gen} -> {Ref, Gen}
        after 900 -> error(registration_timeout)
        end,
        ?assertMatch({ok, {Owner, Generation, _}}, tmux_registry:lookup(Origin)),
        ?assertMatch({error, #{code := wrong_owner}}, tmux_registry:revoke(Origin)),
        Owner ! finish,
        receive {'DOWN', Monitor, process, Owner, normal} -> ok
        after 900 -> error(owner_still_alive)
        end,
        ?assertMatch({error, #{code := stale_reference}}, tmux_registry:lookup(Origin)),
        ?assertMatch({error, #{code := stale_reference}}, tmux_registry:lookup(make_ref()))
    after
        exit(Owner, kill),
        ok = gen_server:stop(Registry)
    end.
