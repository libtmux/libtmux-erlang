-module(stream_demo).
-moduledoc "Read bytes from a pane on a private tmux server.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Bytes} = tmux_server:with_owned(
        #{executable => Executable}, fun read_pane/1),
    #{pane_output => Bytes, cleanup => complete}.

read_pane(Server) ->
    Script = <<"stty -echo; printf 'ready\\n'; IFS= read -r line; "
               "printf 'hello\\n'; IFS= read -r line">>,
    Launch = #{argv => [<<"/bin/sh">>, <<"-c">>, Script]},
    {ok, Session} = tmux_session:create(
        Server, #{name => <<"output">>, launch => Launch}),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    [Pane] = tmux_snapshot:panes(Snapshot),
    {ok, _} = tmux_pane:wait_for_text(Pane, <<"ready">>, #{deadline_ms => 900}),
    PaneId = tmux_model:get(id, Pane),
    Expected = <<"hello\r\n">>,
    % docs:begin subscribe
    {ok, Subscription} = tmux_stream:subscribe(Server, Session, #{}),
    tmux_scope:run_or_error(fun() ->
        {error, #{code := credit_limit}} =
            tmux_stream:demand(Subscription, #{bytes => 1, messages => 1}),
        {ok, _} = tmux_pane:send_text(Pane, <<"go\n">>),
        Deadline = erlang:monotonic_time(millisecond) + 900,
        ok = receive_bytes(Subscription, PaneId, Expected, Deadline),
        Expected
    end, fun() -> tmux_stream:close(Subscription) end).
    % docs:end subscribe

receive_bytes(_, _, <<>>, _) -> ok;
receive_bytes(Sub, Pane, Expected, Deadline) ->
    receive
        {tmux_stream, Sub, {event, Gen, Seq, {pane_output, Pane, Data}}} ->
            ok = tmux_stream:ack(Sub, Gen, Seq),
            Size = byte_size(Data),
            <<Data:Size/binary, Rest/binary>> = Expected,
            receive_bytes(Sub, Pane, Rest, Deadline);
        {tmux_stream, Sub, {event, Gen, Seq, _}} ->
            ok = tmux_stream:ack(Sub, Gen, Seq),
            receive_bytes(Sub, Pane, Expected, Deadline);
        {tmux_stream, Sub, Message} ->
            error({stream_ended, Message})
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error(pane_output_timeout)
    end.
