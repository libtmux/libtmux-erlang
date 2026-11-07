-module(tmux_query_plan).
-moduledoc false.
-export([compile/1]).

-spec compile(tmux_filter:t()) -> map().
compile(Filter) ->
    {Tree, Exact, Local} = translate(tmux_filter:entity(Filter), tmux_filter:expression(Filter)),
    Format = iolist_to_binary(render(Tree)),
    case byte_size(Format) =< 131072 andalso depth(Tree) =< 80 of
        true -> #{format => Format, exact => Exact, local_only => Local,
                  numeric_range => {0, 9007199254740991}};
        false -> #{format => <<"1">>, exact => false,
                   local_only => [#{reason => format_limit} | Local]}
    end.

translate(Entity, {Kind, Children}) when Kind =:= all; Kind =:= any ->
    Compiled = [translate(Entity, Child) || Child <- Children],
    Operator = case Kind of all -> 'and'; any -> 'or' end,
    {combine(Operator, [T || {T, _, _} <- Compiled]),
     lists:all(fun({_, Exact, _}) -> Exact end, Compiled),
     lists:append([Reasons || {_, _, Reasons} <- Compiled])};
translate(Entity, {negate, Child}) ->
    case translate(Entity, Child) of
        {Tree, true, Local} -> {{'not', Tree}, true, Local};
        {_, false, Local} -> {true, false, [#{reason => inexact_negation} | Local]}
    end;
translate(_, {field, _, in, []}) -> {false, true, []};
translate(_, {field, _, not_in, []}) -> {true, true, []};
translate(Entity, {field, Stable, Op, Value}) ->
    [Meta] = [M || M = #{stable := S} <- maps:values(tmux_schema_data:fields(Entity)), S =:= Stable],
    case Meta of
        #{format := Format, nullable := false, type := Type}
          when Type =:= boolean; Type =:= uint;
               Type =:= pane_id; Type =:= window_id; Type =:= session_id ->
            {scalar(Type, Format, Op, Value), true, []};
        _ -> {true, false, [#{field => Stable, operator => Op,
                              reason => unqualified_scalar_codec}]}
    end;
translate(_, {relation, Stable, _, _}) ->
    {true, false, [#{relation => Stable, reason => complete_relationship_required}]};
translate(_, {count, Stable, _}) ->
    {true, false, [#{relation => Stable, reason => complete_relationship_required}]}.

scalar(Type, Format, in, Values) ->
    combine('or', [scalar(Type, Format, equals, V) || V <- Values]);
scalar(Type, Format, not_in, Values) -> {'not', scalar(Type, Format, in, Values)};
scalar(uint, Format, Op, Value) ->
    {numeric, Format, operator(Op), integer_to_binary(Value)};
scalar(boolean, Format, Op, Value) ->
    {compare, Format, operator(Op), case Value of true -> <<"1">>; false -> <<"0">> end};
scalar(_, Format, Op, Value) -> {compare, Format, operator(Op), Value}.

operator(equals) -> <<"==">>;
operator('not') -> <<"!=">>;
operator(lt) -> <<"<">>;
operator(lte) -> <<"<=">>;
operator(gt) -> <<">">>;
operator(gte) -> <<">=">>.

combine('and', Children) ->
    case lists:member(false, Children) of
        true -> false;
        false -> compact('and', [C || C <- Children, C =/= true], true)
    end;
combine('or', Children) ->
    case lists:member(true, Children) of
        true -> true;
        false -> compact('or', [C || C <- Children, C =/= false], false)
    end.
compact(_, [], Identity) -> Identity;
compact(_, [Child], _) -> Child;
compact(Operator, Children, _) -> balanced(Operator, Children).

%% A linear membership fold can exceed tmux's format recursion limit.
balanced(_, [Child]) -> Child;
balanced(Operator, Children) ->
    {Left, Right} = lists:split(length(Children) div 2, Children),
    {Operator, balanced(Operator, Left), balanced(Operator, Right)}.

render(true) -> <<"1">>;
render(false) -> <<"0">>;
render({'not', Child}) -> [<<"#{==:">>, render(Child), <<",0}">>];
render({Operator, Left, Right}) when Operator =:= 'and'; Operator =:= 'or' ->
    Name = case Operator of 'and' -> <<"&&">>; 'or' -> <<"||">> end,
    [<<"#{">>, Name, $:, render(Left), $,, render(Right), $}];
render({compare, Format, Op, Value}) -> [<<"#{">>, Op, <<":#{">>, Format, <<"},">>, Value, $}];
render({numeric, Format, Op, Value}) -> [<<"#{e|">>, Op, <<"|:#{">>, Format, <<"},">>, Value, $}].

depth({'not', Child}) -> 1 + depth(Child);
depth({Op, Left, Right}) when Op =:= 'and'; Op =:= 'or' -> 1 + max(depth(Left), depth(Right));
depth({compare, _, _, _}) -> 2;
depth({numeric, _, _, _}) -> 2;
depth(_) -> 0.
