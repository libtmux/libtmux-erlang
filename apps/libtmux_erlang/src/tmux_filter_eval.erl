-module(tmux_filter_eval).
-moduledoc false.
-export([prepare/3, matches/2]).
-export_type([t/0]).
-type context() :: {snapshot, tmux_snapshot:t()} | {rows, map()}.
-opaque t() :: {prepared_filter, tmux_schema:entity(), 1, context(), fun((tmux_model:row()) -> boolean())}.

-spec prepare(tmux_schema:entity(), tmux_filter:expr(), context()) -> {ok, t()} | {error, map()}.
prepare(Entity, Tree, Context) ->
    try {ok, {prepared_filter, Entity, 1, Context, compile(Entity, Tree, Context)}}
    catch throw:{filter_preparation_failed, Detail} -> {error, Detail}
    end.

-spec matches(t(), tmux_model:row()) -> {ok, boolean()} | {error, map()}.
matches({prepared_filter, Entity, 1, Context, Predicate}, Row) ->
    case belongs(Entity, Row, Context) of
        true ->
            try {ok, Predicate(Row)}
            catch throw:{filter_evaluation_failed, Detail} -> {error, Detail}
            end;
        false -> {error, #{code => prepared_context_mismatch}}
    end.

belongs(Entity, Row, Context) ->
    case tmux_model:validate(Row) of
        {ok, Row} -> tmux_model:entity(Row) =:= Entity andalso captured(Entity, Row, Context);
        {error, _} -> false
    end.

captured(_, Row, {rows, Set}) -> maps:is_key(Row, Set);
captured(Entity, Row, {snapshot, Snapshot}) ->
    Key = case Entity of
        window_link -> {tmux_model:get(session_id, Row), tmux_model:get(index, Row),
                        tmux_model:get(window_id, Row)};
        _ -> tmux_model:get(id, Row)
    end,
    tmux_snapshot:get(Entity, Key, Snapshot) =:= {ok, Row}.

compile(Entity, {all, Children}, Context) ->
    Predicates = [compile(Entity, Child, Context) || Child <- Children],
    fun(Row) -> lists:all(fun(P) -> P(Row) end, Predicates) end;
compile(Entity, {any, Children}, Context) ->
    Predicates = [compile(Entity, Child, Context) || Child <- Children],
    fun(Row) -> lists:any(fun(P) -> P(Row) end, Predicates) end;
compile(Entity, {negate, Child}, Context) ->
    Predicate = compile(Entity, Child, Context),
    fun(Row) -> not Predicate(Row) end;
compile(Entity, {field, Stable, regex, #{pattern := Pattern}}, _) ->
    {Name, _} = metadata(Stable, tmux_schema_data:fields(Entity)),
    case tmux_regex:compile(Pattern) of
        {ok, Compiled} ->
            fun(Row) ->
                case tmux_model:get(Name, Row) of
                    none -> false;
                    Actual ->
                        case tmux_regex:run(Compiled, Actual) of
                            {ok, Boolean} -> Boolean;
                            {error, Detail} ->
                                throw({filter_evaluation_failed, Detail#{field => Stable}})
                        end
                end
            end;
        {error, Detail} -> throw({filter_preparation_failed, Detail#{field => Stable}})
    end;
compile(Entity, {field, Stable, Op, Value}, _) ->
    {Name, _} = metadata(Stable, tmux_schema_data:fields(Entity)),
    Predicate = scalar(Op, Value),
    fun(Row) -> Predicate(tmux_model:get(Name, Row)) end;
compile(Entity, {relation, Stable, Op, Child}, {snapshot, Snapshot} = Context) ->
    {Name, #{target := Target}} = metadata(Stable, tmux_schema_data:relations(Entity)),
    Predicate = compile(Target, Child, Context),
    fun(Row) ->
        {ok, Related} = tmux_snapshot:related(Name, Row, Snapshot),
        quantify(Op, Predicate, Related)
    end;
compile(Entity, {count, Stable, Ops}, {snapshot, Snapshot}) ->
    {Name, _} = metadata(Stable, tmux_schema_data:relations(Entity)),
    Predicates = [scalar(Op, Value) || {Op, Value} <- Ops],
    fun(Row) ->
        {ok, Related} = tmux_snapshot:related(Name, Row, Snapshot),
        Count = length(Related),
        lists:all(fun(P) -> P(Count) end, Predicates)
    end.

metadata(Stable, Items) ->
    [{Name, Meta}] = [{N, M} || {N, M = #{stable := S}} <- maps:to_list(Items), S =:= Stable],
    {Name, Meta}.

quantify(some, Predicate, Rows) -> lists:any(Predicate, Rows);
quantify(every, Predicate, Rows) -> lists:all(Predicate, Rows);
quantify(none, Predicate, Rows) -> not lists:any(Predicate, Rows);
quantify(is, _, none) -> false;
quantify(is, Predicate, Row) -> Predicate(Row);
quantify(is_not, Predicate, Row) -> not quantify(is, Predicate, Row).

scalar(equals, Value) -> fun(Actual) -> Actual =:= Value end;
scalar('not', Value) -> fun(Actual) -> Actual =/= Value end;
scalar(in, Values) ->
    Set = maps:from_keys(Values, true),
    fun(Actual) -> maps:is_key(Actual, Set) end;
scalar(not_in, Values) ->
    Predicate = scalar(in, Values),
    fun(Actual) -> not Predicate(Actual) end;
scalar(present, Present) -> fun(Actual) -> (Actual =/= none) =:= Present end;
scalar(Op, Value) ->
    fun(none) -> false; (Actual) -> compare(Op, Actual, Value) end.

compare(lt, Actual, Value) -> Actual < Value;
compare(lte, Actual, Value) -> Actual =< Value;
compare(gt, Actual, Value) -> Actual > Value;
compare(gte, Actual, Value) -> Actual >= Value;
compare(contains, _, <<>>) -> true;
compare(contains, Actual, Value) -> binary:match(Actual, Value) =/= nomatch;
compare(starts_with, Actual, Value) ->
    Size = byte_size(Value),
    byte_size(Actual) >= Size andalso binary:part(Actual, 0, Size) =:= Value;
compare(ends_with, Actual, Value) ->
    Size = byte_size(Value),
    byte_size(Actual) >= Size andalso
        binary:part(Actual, byte_size(Actual) - Size, Size) =:= Value.
