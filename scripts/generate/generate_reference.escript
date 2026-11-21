#!/usr/bin/env escript
-mode(compile).

main(Arguments) ->
    true = lists:all(fun(A) -> A =:= "--check" orelse A =:= "--test" end, Arguments),
    Profile = case lists:member("--test", Arguments) of true -> "test"; false -> "default" end,
    true = code:add_patha("_build/" ++ Profile ++ "/lib/libtmux_erlang/ebin"),
    Raw = iolist_to_binary([
        "# Fields and relationships\n\n",
        "Generated from the compiled schema and operator validator. Do not edit\n",
        "the tables by hand. Field names on the left are Erlang atoms; wire names\n",
        "are JSON strings. IDs are strings, never numbers.\n\n",
        "Text is case-sensitive UTF-8. Bytes use a single-key base64 object on the\n",
        "wire. Nullable values use `none` locally and `null` on the wire.\n",
        "`not_loaded` and `unavailable` are coverage states, not null values.\n\n",
        [entity(E) || E <- tmux_schema_data:entities()]
    ]),
    Content = <<(string:trim(Raw, trailing, "\n"))/binary, "\n">>,
    Path = "docs/fields.md",
    case lists:member("--check", Arguments) of
        false -> ok = filelib:ensure_dir(Path), ok = file:write_file(Path, Content);
        true ->
            case file:read_file(Path) of
                {ok, Content} -> ok;
                _ -> io:format(standard_error, "Field reference drift: ~s~n", [Path]), halt(1)
            end
    end,
    io:format("PASS: generated field/operator reference~n").

entity(Entity) ->
    Fields = tmux_schema_data:fields(Entity),
    Ordered = lists:sort(fun({A, M}, {B, N}) ->
        {not maps:get(required,M),A} =< {not maps:get(required,N),B}
    end, maps:to_list(Fields)),
    ["## ", atom_to_binary(Entity), "\n\n",
     "| Field | Wire name | Type | Nullable | Operators |\n",
     "| --- | --- | --- | --- | --- |\n",
     [["| `", atom_to_binary(Name), "` | `", maps:get(wire,M), "` | `",
       atom_to_binary(maps:get(type,M)), "` | ", atom_to_binary(maps:get(nullable,M)),
       " | ", lists:join(", ", [io_lib:format("`~p`",[Op]) || Op <- tmux_schema:operators(M)]), " |\n"]
      || {Name,M} <- Ordered], "\n",
     "| Relationship | Wire name | Target | Cardinality |\n",
     "| --- | --- | --- | --- |\n",
     [["| `",atom_to_binary(Name),"` | `",maps:get(wire,M),"` | `",
       atom_to_binary(maps:get(target,M)),"` | ",atom_to_binary(maps:get(kind,M))," |\n"]
      || {Name,M} <- lists:sort(maps:to_list(tmux_schema_data:relations(Entity)))], "\n"].
