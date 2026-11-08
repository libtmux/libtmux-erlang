-module(key_demo).
-moduledoc "Install and remove an application-owned key table.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    try
        Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
        Table = <<"workspace-", Suffix/binary>>,
        {ok, Zoom} = tmux_command:raw(<<"resize-pane">>, [<<"-Z">>]),
        {ok, Status} = tmux_command:raw(<<"display-message">>,
            [<<"Workspace: #{session_name}">>]),
        {ok, _} = tmux_key:bind(Server, <<"z">>, [Zoom, Status],
            #{table => Table, note => <<"Zoom the current workspace pane">>}),
        try
            {ok, _} = tmux_key:bind(Server, <<"s">>, Status,
                #{table => Table, note => <<"Show the workspace name">>}),
            {ok, Listing} = tmux_key:listing(Server, #{table => Table}),
            true = binary:match(Listing, <<"resize-pane">>) =/= nomatch,
            true = binary:match(Listing, <<"display-message">>) =/= nomatch,
            #{bindings => 2, native_listing => true,
              execution => <<"requires a client key press">>}
        after
            {ok, _} = tmux_key:clear_table(Server, Table)
        end
    after
        ok = tmux_server:close(Server)
    end.
