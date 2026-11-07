-module(hook_demo).
-moduledoc "Acknowledge a registered split hook before reading its effect.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    try
        Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
        {ok, Session} = tmux_session:create(Server,
            Launch#{name => <<"hooks">>}),
        try
            {ok, Snapshot} = tmux_server:snapshot(Server),
            [Pane] = tmux_snapshot:panes(Snapshot),
            Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
            Channel = <<"hook-", Suffix/binary>>,
            {ok, Mark} = tmux_command:raw(<<"set-option">>,
                [<<"-t">>, tmux_model:get(id, Session),
                 <<"@last-event">>, <<"split complete">>]),
            {ok, Signal} = tmux_command:wait_for(Channel, signal),
            {ok, Wait} = tmux_command:wait_for(Channel, wait),
            {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
            try
                Name = <<"after-split-window">>,
                {ok, _} = tmux_hook:set(Session, {Name, 4}, [Mark, Signal]),
                {ok, _} = tmux_pane:split(Pane, Launch),
                {ok, #{cleanup := complete}} =
                    tmux_operation:await(Operation, 900),
                {ok, <<"split complete">>} =
                    tmux_option:get(Session, <<"@last-event">>, #{}),
                {ok, #{4 := _}} = tmux_hook:get(Session, Name, #{}),
                {ok, _} = tmux_hook:unset(Session, Name),
                none = tmux_hook:get(Session, Name, #{}),
                #{event => <<"split complete">>, hook_acknowledged => true,
                  local_hook_removed => true}
            after
                {ok, _} = tmux_operation:cancel(Operation),
                case tmux_operation:await(Operation, 900) of
                    {ok, #{cleanup := complete}} -> ok;
                    {error, #{cleanup := complete}} -> ok
                end
            end
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
