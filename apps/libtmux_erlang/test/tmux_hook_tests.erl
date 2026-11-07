-module(tmux_hook_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

validation_before_dispatch_test() ->
    {ok, Command} = tmux_command:raw(<<"display-message">>, [<<"literal">>]),
    ?assertMatch({error, #{code := not_a_hook}},
        tmux_hook:set({session_defaults, invalid}, {<<"mouse">>, 0}, Command)),
    ?assertMatch({error, #{code := wrong_option_scope}},
        tmux_hook:set({window_defaults, invalid},
            {<<"after-split-window">>, 0}, Command)),
    ?assertMatch({error, #{code := array_index_required}},
        tmux_hook:set({session_defaults, invalid}, <<"after-split-window">>, Command)),
    ?assertMatch({error, #{code := invalid_hook_name}},
        tmux_hook:append({session_defaults, invalid}, {<<"pane-died">>, 0}, Command)),
    ?assertMatch({error, #{code := invalid_option_key}},
        tmux_hook:set({window_defaults, invalid},
            {{<<"pane-died">>, 1}, 2}, Command)),
    {ok, Detached} = tmux_model:session(#{id => <<"$0">>}),
    ?assertMatch({error, #{code := detached_reference}},
        tmux_hook:set(Detached, {<<"after-split-window">>, 0}, Command)),
    ?assertMatch({error, #{code := invalid_hook_commands}},
        tmux_hook:set(Detached, {<<"after-split-window">>, 0}, [])),
    ?assertMatch({error, #{code := invalid_hook_commands}},
        tmux_hook:set(Detached, {<<"after-split-window">>, 0},
            [Command | invalid])),
    ?assertMatch({error, #{code := unknown_option}},
        tmux_hook:get(Detached, <<"after-split-window">>, #{quiet => true})),
    ?assertMatch({error, #{code := invalid_hook_context}},
        tmux_hook:run({session_defaults, invalid}, <<"after-split-window">>)).
