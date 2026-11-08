-module(model_types_ok).
-export([run/0, build_pane/1]).

-spec run() -> ok.
run() ->
    {ok, Session} = tmux_model:session(#{id => <<"$1">>, attached_count => 1}),
    {ok, Window} = tmux_model:window(#{id => <<"@1">>, width => 120.0}),
    {ok, Link} = tmux_model:window_link(#{session_id => <<"$1">>,
        window_id => <<"@1">>, index => 0, active => true}),
    {ok, Pane} = build_pane(#{id => <<"%1">>, pid => none,
        title => unavailable, current_command => not_loaded}),
    true = tmux_model:get(attached, Session),
    120 = tmux_model:get(width, Window),
    window_link = tmux_model:entity(Link),
    none = tmux_model:get(pid, Pane),
    {error, #{code := invalid_value}} =
        tmux_model:new(pane, #{id => <<"%1">>, active => <<"true">>}),
    ok.

-spec build_pane(tmux_model:pane_input()) ->
    {ok, tmux_model:pane()} | {error, tmux_schema:error_detail()}.
build_pane(Fields) -> tmux_model:pane(Fields).
