-module(control_read_demo).
-moduledoc "Read IDs and run mutations on a private control attachment.".
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
    tmux_scope:run_or_error(fun() ->
        Counts = submit(Control, SessionId),
        Counts#{window_width => mutate(Server, Control, Session)}
    end, fun() -> tmux_control:close(Control) end).

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

mutate(Server, Control, Session) ->
    {ok, Snapshot} = tmux_server:snapshot(Server),
    [Window] = tmux_snapshot:windows(Snapshot),
    % docs:begin mutate
    {ok, Rename} = tmux_session:rename_command(Session, <<"resized">>),
    {ok, Resize} = tmux_window:resize_command(Window, #{width => 110}),
    {ok, Work} = tmux_control:submit(Control, [Rename, Resize], #{}),
    {ok, #{replies := [<<>>, <<>>]}} = tmux_control:await(Work, 900),
    % docs:end mutate
    {ok, Renamed} = tmux_session:get(Server, tmux_model:get(id, Session)),
    <<"resized">> = tmux_model:get(name, Renamed),
    {ok, Resized} = tmux_window:get(Server, tmux_model:get(id, Window)),
    110 = tmux_model:get(width, Resized).

count_ids(Bytes) -> length(binary:split(Bytes, <<10>>, [global, trim_all])).
