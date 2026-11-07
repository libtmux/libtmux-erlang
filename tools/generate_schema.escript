#!/usr/bin/env escript
%%! -noshell
-mode(compile).

main(Args) when Args =:= []; Args =:= ["--check"] ->
    {ok, Source} = file:read_file("schema/entities.json"),
    #{<<"version">> := 1, <<"entities">> := Entities} = json:decode(Source),
    validate(Entities),
    Outputs = [
        {"apps/libtmux_erlang/src/tmux_schema_data.erl", schema(Entities)},
        {"apps/libtmux_erlang/src/tmux_model.erl", model(Entities)}
    ],
    Results = [output(Path, iolist_to_binary(Data), Args) || {Path, Data} <- Outputs],
    case lists:all(fun(Result) -> Result =:= ok end, Results) of
        true -> ok;
        false -> halt(1)
    end;
main(_) ->
    io:format(standard_error, "Usage: generate_schema.escript [--check]~n", []),
    halt(2).

validate(Entities) ->
    Names = [maps:get(<<"name">>, E) || E <- Entities],
    true = length(Names) =:= length(lists:usort(Names)),
    lists:foreach(fun(E) ->
        _ = atom_source(maps:get(<<"name">>, E)),
        Fields = maps:get(<<"fields">>, E),
        FieldNames = [maps:get(<<"name">>, F) || F <- Fields],
        true = length(FieldNames) =:= length(lists:usort(FieldNames)),
        true = [] =:= [N || N <- FieldNames,
                            lists:member(N, [<<"origin">>, <<"snapshot_id">>,
                                             <<"model_version">>])],
        lists:foreach(fun(F) ->
            _ = atom_source(maps:get(<<"name">>, F)),
            Type = maps:get(<<"type">>, F),
            _ = value_type(Type),
            case maps:find(<<"minimum">>, F) of
                error -> ok;
                {ok, Minimum} ->
                    true = lists:member(Type, [<<"uint">>, <<"integer">>]),
                    Floor = case Type of <<"uint">> -> 0; _ -> -9007199254740991 end,
                    true = is_integer(Minimum, Floor, 9007199254740991)
            end
        end, Fields),
        lists:foreach(fun(R) ->
            true = lists:member(maps:get(<<"target">>, R), Names)
        end, maps:get(<<"relations">>, E))
    end, Entities).

output(Path, Data, []) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, Data);
output(Path, Data, ["--check"]) ->
    case file:read_file(Path) of
        {ok, Data} -> ok;
        _ -> io:format(standard_error, "Generated file differs: ~s~n", [Path]), stale
    end.

header(Module) ->
    ["%% Generated from schema/entities.json by tools/generate_schema.escript.\n",
     "-module(", Module, ").\n"].

schema(Entities) ->
    [header("tmux_schema_data"), "-moduledoc false.\n",
     "-export([entities/0, fields/1, relations/1, wire_entity/1]).\n\n",
     "-spec entities() -> [atom()].\nentities() -> [",
     join([name(E) || E <- Entities], ", "), "].\n\n",
     "-spec fields(atom()) -> #{atom() => map()}.\n",
     join([["fields(", name(E), ") -> #{\n",
            join([field(F, E) || F <- maps:get(<<"fields">>, E)], ",\n"),
            "\n}"] || E <- Entities], ";\n"), ".\n\n",
     "-spec relations(atom()) -> #{atom() => map()}.\n",
     join([["relations(", name(E), ") -> #{",
            join([relation(R, E) || R <- maps:get(<<"relations">>, E)], ", "),
            "}"] || E <- Entities], ";\n"), ".\n\n",
     "-spec wire_entity(atom()) -> binary().\n",
     join([["wire_entity(", name(E), ") -> ", binary_source(maps:get(<<"wire">>, E))]
           || E <- Entities], ";\n"), ".\n"].

field(F, E) ->
    Wire = maps:get(<<"wire">>, F),
    Stable = <<"tmux.", (maps:get(<<"wire">>, E))/binary, ".", Wire/binary>>,
    ["    ", name(F), " => #{type => ", atom_source(maps:get(<<"type">>, F)),
     ", wire => ", binary_source(Wire), ", stable => ", binary_source(Stable),
     ", required => ", bool(maps:get(<<"required">>, F, false)),
     ", nullable => ", bool(maps:get(<<"nullable">>, F, false)),
     case maps:find(<<"minimum">>, F) of
         {ok, Minimum} -> [", minimum => ", integer_to_binary(Minimum)];
         error -> []
     end,
     case maps:find(<<"format">>, F) of
         {ok, Format} -> [", format => ", binary_source(Format)];
         error -> []
     end, "}"].

relation(R, E) ->
    Wire = maps:get(<<"wire">>, R),
    Stable = <<"tmux.", (maps:get(<<"wire">>, E))/binary, ".", Wire/binary>>,
    [name(R), " => #{kind => ", atom_source(maps:get(<<"kind">>, R)),
     ", target => ", atom_source(maps:get(<<"target">>, R)),
     ", wire => ", binary_source(Wire), ", stable => ", binary_source(Stable), "}"].

model(Entities) ->
    Names = [name(E) || E <- Entities],
    [header("tmux_model"),
     "-moduledoc \"\"\"\n",
     "Validated native domain records. Constructors perform no tmux I/O.\n\n",
     "Missing optional observations remain not_loaded; required identity fields\n",
     "must be supplied. Unavailable capabilities remain\n",
     "unavailable. Neither state means an empty relation or known absence.\n",
     "Rows created by `new/2` and the entity constructors are detached.\n",
     "Use `tmux_server:bind/2` to register a fresh observed row for actions;\n",
     "use `m:tmux_snapshot` for captured graph relationships.\n",
     "\"\"\".\n",
     "-export_record([", join(Names, ", "), "]).\n",
     "-export([new/2, validate/1, entity/1, get/2, to_map/1, origin/1,\n",
     "         snapshot_id/1, model_version/1, bind/3]).\n",
     "-export([", join([[N, "/1"] || N <- Names], ", "), "]).\n",
     "-export_type([row/0, pane_id/0, window_id/0, session_id/0,\n",
     "              ", join([[N, "/0"] || N <- Names], ", "), "]).\n\n",
     "-doc \"A canonical pane ID binary in the percent namespace; nominal checking is by Dialyzer.\".\n",
     "-nominal pane_id() :: binary().\n",
     "-doc \"A canonical physical-window ID binary in the at-sign namespace.\".\n",
     "-nominal window_id() :: binary().\n",
     "-doc \"A canonical session ID binary in the dollar namespace.\".\n",
     "-nominal session_id() :: binary().\n\n",
     [record(E) || E <- Entities],
     "-doc \"One schema-defined native domain record, with separate origin and capture metadata.\".\n",
     "-type row() :: ", join([["#", N, "{}"] || N <- Names], " | "), ".\n",
     [["-doc \"A validated ", N, " observation. Native records are experimental in OTP 29.\".\n",
       "-type ", N, "() :: #", N, "{}.\n"] || N <- Names],
     "\n-doc \"\"\"\n",
     "Construct a detached row from validated observations.\n\n",
     "```erlang\n",
     "1> {ok, Pane} = tmux_model:new(pane, #{id => <<\"%1\">>, width => 120}), ok.\n",
     "ok\n",
     "2> tmux_model:get(width, Pane).\n",
     "120\n",
     "```\n",
     "\"\"\".\n",
     "-spec new(atom(), map()) -> {ok, row()} | {error, map()}.\n",
     "new(Entity, Fields) ->\n",
     "    maybe\n",
     "        {ok, Normalized} ?= tmux_schema:normalize(Entity, Fields),\n",
     "        {ok, build(Entity, Normalized)}\n",
     "    end.\n\n",
     [["-doc \"Construct a detached ", N,
       " row, validating required fields and scalar bounds without tmux I/O.\".\n",
       "-spec ", N, "(map()) -> {ok, ", N, "()} | {error, map()}.\n",
       N, "(Fields) -> new(", N, ", Fields).\n\n"] || N <- Names],
     "-doc \"Validate native row shape, model version and normalized observations. Exported records do not enforce these invariants at construction. Performs no I/O.\".\n",
     "-spec validate(term()) -> {ok, row()} | {error, map()}.\n",
     "validate(Row) ->\n",
     "    case row_metadata(Row) of\n",
     "        {Entity, 1, Origin, Snapshot}\n",
     "          when (Origin =:= none orelse is_reference(Origin)),\n",
     "               (Snapshot =:= none orelse is_reference(Snapshot)) ->\n",
     "            Fields = to_map(Row),\n",
     "            case tmux_schema:normalize(Entity, Fields) of\n",
     "                {ok, Fields} -> {ok, Row};\n",
     "                {ok, _} -> {error, #{code => unnormalized_row, path => []}};\n",
     "                {error, _} = Error -> Error\n",
     "            end;\n",
     "        _ -> {error, #{code => invalid_row, path => []}}\n",
     "    end.\n\n",
     "-doc \"Return the built-in entity kind of a native row without I/O.\".\n",
     getter("entity", "atom()", Entities, fun(E) -> name(E) end),
     "-doc \"Read the opaque origin token, or none for a detached row. This does not revalidate endpoint lifetime.\".\n",
     getter("origin", "none | reference()", Entities, fun(_) -> "Value" end, "origin"),
     "-doc \"Read the capture identity, or none when not associated with a snapshot. Performs no I/O.\".\n",
     getter("snapshot_id", "none | reference()", Entities, fun(_) -> "Value" end, "snapshot_id"),
     "-doc \"Read the native model version. Unknown versions fail validation; record internals are not a persistence format.\".\n",
     getter("model_version", "pos_integer()", Entities, fun(_) -> "Value" end, "model_version"),
     "-doc \"Return domain field values without origin or capture metadata. This is not the portable filter wire representation. Performs no I/O.\".\n",
     "-spec to_map(row()) -> map().\n",
     join([["to_map(Row = #", name(E), "{}) -> #{",
            join([[name(F), " => Row#", name(E), ".", name(F)] ||
                    F <- maps:get(<<"fields">>, E)], ", "), "}"]
           || E <- Entities], ";\n"), ".\n\n",
     "-doc \"Read a permitted domain field without I/O. Unknown fields raise unknown_field; unloaded and unavailable values remain distinct.\".\n",
     "-spec get(atom(), row()) -> term().\n",
     join(lists:append([[["get(", name(F), ", #", name(E), "{", name(F),
                          " = Value}) -> Value"]
                        || F <- maps:get(<<"fields">>, E)] || E <- Entities]), ";\n"),
     ";\nget(Field, Row) -> error({unknown_field, entity(Row), Field}).\n\n",
     "-doc false.\n",
     "-spec bind(row(), reference(), reference()) -> row().\n",
     join([["bind(Row = #", N, "{}, Origin, Snapshot)\n",
            "  when is_reference(Origin), is_reference(Snapshot) ->\n",
            "    {ok, Row} = validate(Row),\n",
            "    Row#", N, "{origin = Origin, snapshot_id = Snapshot}"]
           || N <- Names], ";\n"), ".\n\n",
     join([["row_metadata(#", N, "{model_version = V, origin = O, snapshot_id = S}) ->\n",
            "    {", N, ", V, O, S}"] || N <- Names], ";\n"),
     ";\nrow_metadata(_) -> invalid.\n\n",
     join([["build(", name(E), ", Fields) -> #", name(E), "{\n",
            join([["    ", name(F), " = maps:get(", name(F), ", Fields)"]
                  || F <- maps:get(<<"fields">>, E)], ",\n"), "\n}"]
           || E <- Entities], ";\n"), ".\n"].

record(E) ->
    ["-record #", name(E), "{\n",
     join([["    ", name(F),
            case maps:get(<<"required">>, F, false) of
                true -> " :: ";
                false -> " = not_loaded :: "
            end,
            field_type(F),
            case maps:get(<<"nullable">>, F, false) of true -> " | none"; false -> [] end,
            case maps:get(<<"required">>, F, false) of
                true -> [];
                false -> " | not_loaded | unavailable"
            end] || F <- maps:get(<<"fields">>, E)], ",\n"),
     ",\n    origin = none :: none | reference(),\n",
     "    snapshot_id = none :: none | reference(),\n",
     "    model_version = 1 :: pos_integer()\n}.\n\n"].

getter(Function, Type, Entities, Value) ->
    ["-spec ", Function, "(row()) -> ", Type, ".\n",
     join([[Function, "(#", name(E), "{}) -> ", Value(E)] || E <- Entities],
          ";\n"), ".\n\n"].
getter(Function, Type, Entities, Value, Field) ->
    ["-spec ", Function, "(row()) -> ", Type, ".\n",
     join([[Function, "(#", name(E), "{", Field, " = Value}) -> ", Value(E)]
           || E <- Entities], ";\n"), ".\n\n"].

name(Map) -> atom_source(maps:get(<<"name">>, Map)).
atom_source(Name) ->
    match = re:run(Name, <<"^[a-z][a-z0-9_]*$">>, [{capture, none}]),
    Name.
binary_source(Value) -> io_lib:format("~p", [Value]).
bool(true) -> "true";
bool(false) -> "false".
join(Values, Separator) -> lists:join(Separator, Values).
field_type(#{<<"type">> := <<"uint">>, <<"minimum">> := 1}) -> "pos_integer()";
field_type(F) -> value_type(maps:get(<<"type">>, F)).

value_type(<<"pane_id">>) -> "pane_id()";
value_type(<<"window_id">>) -> "window_id()";
value_type(<<"session_id">>) -> "session_id()";
value_type(<<"text">>) -> "binary()";
value_type(<<"bytes">>) -> "binary()";
value_type(<<"boolean">>) -> "boolean()";
value_type(<<"uint">>) -> "non_neg_integer()";
value_type(<<"integer">>) -> "integer()".
