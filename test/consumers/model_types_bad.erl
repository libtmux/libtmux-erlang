-module(model_types_bad).
-compile(nowarn_missing_spec).
-export([pane_boolean/0, window_number/0, session_identity/0, link_index/0]).

pane_boolean() ->
    tmux_model:pane(#{id => <<"%1">>, active => <<"true">>}).

window_number() ->
    tmux_model:window(#{id => <<"@1">>, width => <<"120">>}).

session_identity() ->
    tmux_model:session(#{name => <<"missing-id">>}).

link_index() ->
    tmux_model:window_link(#{session_id => <<"$1">>, window_id => <<"@1">>}).
