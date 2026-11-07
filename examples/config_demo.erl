-module(config_demo).
-moduledoc "Apply session configuration and wait for its explicit signal.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    try
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"configured-job">>,
              launch => #{argv => [<<"/bin/cat">>]}}),
        try
            Id = tmux_model:get(id, Session),
            Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
            Channel = <<"configured-", Suffix/binary>>,
            {ok, Wait} = tmux_command:wait_for(Channel, wait),
            {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
            {ok, Source} = tmux_command:source_file(stdin, #{}),
            Scope = [<<"-t">>, Id, <<"@state">>],
            {ok, Settings} = tmux_command:raw(<<"set-option">>,
                Scope ++ [<<"configured">>]),
            {ok, Signal} = tmux_command:wait_for(Channel, signal),
            {ok, SetText} = tmux_command:to_config(Settings),
            {ok, SignalText} = tmux_command:to_config(Signal),
            Text = <<SetText/binary, "\n", SignalText/binary, "\n">>,
            {ok, _} = tmux_server:command(Server, Source, #{stdin => Text}),
            {ok, #{cleanup := complete}} =
                tmux_operation:await(Operation, 900),
            State = <<"@state">>,
            {ok, <<"configured">>} = tmux_option:get(Session, State, #{}),
            ParseOptions = #{parse_only => true},
            {ok, Parse} = tmux_command:source_file(stdin, ParseOptions),
            {ok, NewValue} = tmux_command:raw(<<"set-option">>,
                Scope ++ [<<"changed">>]),
            {ok, Change} = tmux_command:to_config(NewValue),
            {ok, _} = tmux_server:command(Server, Parse, #{stdin => Change}),
            {ok, <<"configured">>} = tmux_option:get(Session, State, #{}),
            #{configuration_applied => true, event_received => true,
              parse_only_kept_value => true}
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
