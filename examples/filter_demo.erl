-module(filter_demo).
-moduledoc "Validate portable JSON and filter captured rows without tmux I/O.".
-export([run/0]).

-spec run() -> map().
run() ->
    {ok, Editor} = tmux_model:pane(#{id => <<"%1">>, active => true,
        width => 120, current_command => <<"nvim">>}),
    {ok, Shell} = tmux_model:pane(#{id => <<"%2">>, active => false,
        width => 80, current_command => <<"bash">>}),
    Panes = tmux_select:from_list(pane, [Editor, Shell]),
    Criteria = #{active => true, 'or' => [
        #{current_command => #{in => [<<"nvim">>, <<"vim">>]}},
        #{width => #{gte => 160}}
    ]},
    {ok, Filter} = tmux_filter:new(pane, Criteria),
    Encoded = iolist_to_binary(json:encode(tmux_filter:to_wire(Filter))),
    {ok, Document} = tmux_filter:decode_json(Encoded),
    {ok, RoundTrip} = tmux_filter:from_wire(pane, Document),
    {ok, Editor} = tmux_select:one(RoundTrip, Panes),
    [Editor] = tmux_select:to_list(tmux_select:where(Filter, Panes)),
    {error, #{code := duplicate_key}} = tmux_filter:decode_json(
        <<"{\"version\":1,\"version\":2}">>),
    #{matched_ids => [tmux_model:get(id, Editor)],
      wire_round_trip => true, duplicate_keys_rejected => true}.
