-module(prop_tmux_filter).
-compile(nowarn_missing_spec).
-include_lib("proper/include/proper.hrl").
-export([prop_wire_round_trip/0, prop_filter_composition/0, prop_json_bytes/0]).

prop_wire_round_trip() ->
    ?FORALL(Criteria, criteria(),
        begin
            {ok, Filter} = tmux_filter:new(pane, Criteria),
            {ok, Document} = tmux_json:decode(iolist_to_binary(json:encode(tmux_filter:to_wire(Filter)))),
            {ok, Filter} =:= tmux_filter:from_wire(pane, Document) andalso
                {ok, Filter} =:= tmux_filter:new(pane, Filter)
        end).

prop_filter_composition() ->
    ?FORALL({Rows, A, B}, {rows(), criteria(), criteria()},
        begin
            Selection = tmux_select:from_list(pane, Rows),
            Left = tmux_select:where(#{'and' => [A, B]}, Selection),
            Right = tmux_select:where(B, tmux_select:where(A, Selection)),
            Complement = tmux_select:where(#{'not' => A}, Selection),
            Chosen = tmux_select:where(A, Selection),
            tmux_select:to_list(Left) =:= tmux_select:to_list(Right) andalso
                tmux_select:size(Chosen) + tmux_select:size(Complement) =:= length(Rows)
        end).

prop_json_bytes() ->
    ?FORALL(Bytes, binary(),
        begin
            {ok, Filter} = tmux_filter:new(pane, #{current_path => Bytes}),
            {ok, Document} = tmux_json:decode(iolist_to_binary(json:encode(tmux_filter:to_wire(Filter)))),
            {ok, Filter} =:= tmux_filter:from_wire(pane, Document)
        end).

criteria() ->
    ?LET({Width, Active, Commands, Pattern, Negate},
        {choose(0, 10000), boolean(), list(elements([<<"vim">>, <<"cat">>, <<"nvim">>])),
         elements([<<"^(vim|nvim)$">>, <<"^cat$">>, <<"c.t">>, <<"^.{0,8}$">>]), boolean()},
        begin
            Base = #{width => #{gte => Width}, active => Active,
                     current_command => #{in => Commands,
                         regex => #{pattern => Pattern, dialect => portable_v1}}},
            case Negate of true -> #{'not' => Base}; false -> Base end
        end).

rows() ->
    %% At least one row establishes field coverage for this property. The
    %% independent empty-selection tests verify the stricter unloaded contract.
    ?LET(Values, non_empty(list({choose(0, 10000), boolean(), elements([<<"vim">>, <<"cat">>])})),
        [pane(N, Value) || {N, Value} <- lists:enumerate(Values)]).

pane(N, {Width, Active, Command}) ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%", (integer_to_binary(N))/binary>>,
        width => Width, active => Active, current_command => Command}),
    Pane.
