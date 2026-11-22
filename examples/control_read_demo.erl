-module(control_read_demo).
-moduledoc "Read session and pane IDs on a private control attachment.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Counts} = tmux_server:with_owned(
        #{executable => Executable}, fun read_group/1),
    Counts#{cleanup => complete}.

read_group(Server) ->
    Launch = #{argv => [<<"/bin/cat">>]},
    {ok, Session} = tmux_session:create(
        Server, #{name => <<"reads">>, launch => Launch}),
    SessionId = tmux_model:get(id, Session),
    {ok, Control} = tmux_control:attach(Server, Session, #{}),
    tmux_scope:run_or_error(fun() -> submit(Control, SessionId) end,
                            fun() -> tmux_control:close(Control) end).

submit(Control, SessionId) ->
    % docs:begin submit
    {ok, Sessions} = tmux_command:raw(<<"list-sessions">>,
        [<<"-F">>, <<"#{session_id}">>]),
    {ok, Panes} = tmux_command:raw(<<"list-panes">>,
        [<<"-t">>, SessionId, <<"-F">>, <<"#{pane_id}">>]),
    {ok, Read} = tmux_control:submit(Control, [Sessions, Panes], #{}),
    {ok, #{replies := [SessionIds, PaneIds]}} = tmux_control:await(Read, 900),
    % docs:end submit
    #{sessions => count_ids(SessionIds), panes => count_ids(PaneIds)}.

count_ids(Bytes) -> length(binary:split(Bytes, <<10>>, [global, trim_all])).
