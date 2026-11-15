%% Generate option metadata and its reference from pinned tmux source tables.
%% usage: escript scripts/generate/generate_options.erl [--check | --refresh-from TREE]
-module(generate_options).
-mode(compile).
-moduledoc """
Regenerate `tmux_option_data` and `docs/options-reference.md` from
`schema/options.json`.

`--check` fails when a generated file differs from the schema. `--refresh-from`
rebuilds the schema from the pinned commits in a local tmux clone first; it
needs a C preprocessor to expand the hook macros.
""".
-export([main/1, refresh/2, validate/2, generate/1, initializers/1]).

-define(STRING, "\"(?:[^\"\\\\]|\\\\.)*\"").
-define(DATA_PATH, "apps/libtmux_erlang/src/tmux_option_data.erl").
-define(REFERENCE_PATH, "docs/options-reference.md").
-define(TABLE, <<"options-table.c">>).
-define(KINDS, [<<"choice">>, <<"colour">>, <<"command">>, <<"flag">>, <<"key">>,
                <<"number">>, <<"string">>]).

-spec main([string()]) -> ok.
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    generate_catalogue:main(#{name => "generate_options",
                              schema => "schema/options.json",
                              refresh => fun refresh/2,
                              validate => fun validate/2,
                              generate => fun generate/1,
                              drift => "Generated option catalogue drift",
                              done => "PASS: generated option catalogue and source reference"},
                            Root, Arguments).

%% Refresh

-doc """
Build the schema from `Source`, which reads `options-table.c` at each pinned
commit and expands its macros.
""".
-spec refresh(generate_catalogue:source(), generate_catalogue:pins()) ->
    generate_json:json().
refresh(Source, Pins) ->
    {Sources, Entries} = lists:foldl(
        fun({Version, Commit}, {SourcesAcc, EntriesAcc}) ->
            Bytes = (maps:get(read, Source))(Commit, ?TABLE),
            Text = re:replace(Bytes, "^\\s*#include[^\\n]*", "",
                              [global, multiline, {return, binary}]),
            ok = generate_catalogue:ensure(
                not generate_catalogue:matches(
                    Text, {"^\\s*#\\s*(?:if|elif|else|endif)\\b", [multiline]}),
                "conditional table requires an explicit extraction policy", []),
            Rows = initializers((maps:get(preprocess, Source))(Text)),
            Named = lists:foldl(fun(Row, Acc) -> row(Row, Acc) end, [], Rows),
            Entry = [{<<"commit">>, Commit}, {<<"file">>, ?TABLE},
                     {<<"sha256">>, script_util:sha256_hex(Bytes)},
                     {<<"entries">>, length(Named)}],
            Add = fun({Name, Metadata}, Acc) -> add_variant(Name, Metadata, Version, Acc) end,
            {[{Version, Entry} | SourcesAcc], lists:foldl(Add, EntriesAcc, Named)}
        end, {[], #{}}, Pins),
    [{<<"version">>, 1},
     {<<"sources">>, lists:reverse(Sources)},
     {<<"entries">>, [{Name, [[{<<"versions">>, Versions}, {<<"metadata">>, Metadata}]
                              || {Versions, Metadata} <- Variants]}
                      || {Name, Variants} <- lists:sort(maps:to_list(Entries))]}].

add_variant(Name, Metadata, Version, Entries) ->
    Variants = maps:get(Name, Entries, []),
    case lists:keyfind(Metadata, 2, Variants) of
        {Versions, Metadata} ->
            Entries#{Name => lists:keyreplace(Metadata, 2, Variants,
                                              {Versions ++ [Version], Metadata})};
        false ->
            Entries#{Name => Variants ++ [{[Version], Metadata}]}
    end.

-doc """
The `{...}` initializers of `options_table[]` in preprocessed C, ignoring braces
inside string and character literals.
""".
-spec initializers(binary()) -> [binary()].
initializers(Text) ->
    case binary:split(Text, <<"options_table[] = {">>) of
        [_, Table] -> scan(Table, 0, 0, none, false, 0, []);
        _ -> generate_catalogue:value_error("unterminated options_table", [])
    end.

scan(Text, Position, _, _, _, _, _) when Position >= byte_size(Text) ->
    generate_catalogue:value_error("unterminated options_table", []);
scan(Text, Position, Depth, Quote, Escaped, Start, Rows) ->
    Char = binary:at(Text, Position),
    Next = Position + 1,
    case Quote of
        none when Char =:= $"; Char =:= $' ->
            scan(Text, Next, Depth, Char, false, Start, Rows);
        none when Char =:= ${ ->
            scan(Text, Next, Depth + 1, none, false, case Depth of 0 -> Position; _ -> Start end,
                 Rows);
        none when Char =:= $}, Depth =:= 0 ->
            lists:reverse(Rows);
        none when Char =:= $}, Depth =:= 1 ->
            scan(Text, Next, 0, none, false, Start,
                 [binary:part(Text, Start, Next - Start) | Rows]);
        none when Char =:= $} ->
            scan(Text, Next, Depth - 1, none, false, Start, Rows);
        none ->
            scan(Text, Next, Depth, none, false, Start, Rows);
        _ when Escaped ->
            scan(Text, Next, Depth, Quote, false, Start, Rows);
        _ when Char =:= $\\ ->
            scan(Text, Next, Depth, Quote, true, Start, Rows);
        _ when Char =:= Quote ->
            scan(Text, Next, Depth, none, false, Start, Rows);
        _ ->
            scan(Text, Next, Depth, Quote, false, Start, Rows)
    end.

%% Add the option a table row declares, unless it is the NULL terminator.
row(Row, Named) ->
    case generate_catalogue:matches(Row, "\\.name\\s*=\\s*NULL") of
        true -> Named;
        false -> option(Row, Named)
    end.

option(Row, Named) ->
    Literals = generate_catalogue:search(Row, ["\\.name\\s*=\\s*((?:", ?STRING, "\\s*)+),"]),
    ok = generate_catalogue:ensure(Literals =/= nomatch, "unrecognized option name: ~ts",
                                   [binary:part(Row, 0, min(80, byte_size(Row)))]),
    [Pieces] = Literals,
    Strings = generate_catalogue:find(Pieces, ["(", ?STRING, ")"]),
    Name = iolist_to_binary([generate_catalogue:literal(Piece) || [Piece] <- Strings]),
    ok = generate_catalogue:ensure(
        generate_catalogue:matches(Name, "^[a-z][a-z0-9-]*\\z")
            andalso not lists:keymember(Name, 1, Named),
        "invalid or duplicate option: ~ts", [Name]),
    Scope = case generate_catalogue:search(Row, "\\.scope\\s*=\\s*([^,]+),") of
        [Value] -> Value;
        nomatch -> generate_catalogue:value_error("missing scope: ~ts", [Name])
    end,
    Scopes = [Found || [Found] <- generate_catalogue:find(
                                      Scope, "OPTIONS_TABLE_(SERVER|SESSION|WINDOW|PANE)")],
    Remainder = re:replace(Scope, "OPTIONS_TABLE_(SERVER|SESSION|WINDOW|PANE)|[\\s|]", "",
                           [global, {return, binary}]),
    ok = generate_catalogue:ensure(Scopes =/= [] andalso Remainder =:= <<>>,
                                   "unrecognized scope: ~ts", [Scope]),
    Kind = case generate_catalogue:search(Row, "\\.type\\s*=\\s*OPTIONS_TABLE_(\\w+)") of
        [Type] -> string:lowercase(Type);
        nomatch -> generate_catalogue:value_error("missing type: ~ts", [Name])
    end,
    ok = generate_catalogue:ensure(lists:member(Kind, ?KINDS), "unrecognized option type: ~ts",
                                   [Kind]),
    Metadata = [{<<"scopes">>, [string:lowercase(Found) || Found <- Scopes]},
                {<<"type">>, Kind},
                {<<"array">>, binary:match(Row, <<"OPTIONS_TABLE_IS_ARRAY">>) =/= nomatch},
                {<<"hook">>, binary:match(Row, <<"OPTIONS_TABLE_IS_HOOK">>) =/= nomatch}],
    Named ++ [{Name, Metadata}].

%% Validation

-doc "Check that the schema's sources are the pinned commits.".
-spec validate(generate_json:json(), generate_catalogue:pins()) -> ok.
validate(Data, Pins) ->
    Sources = generate_catalogue:members(generate_catalogue:field(<<"sources">>, Data)),
    generate_catalogue:ensure(
        maps:from_list([{Version, generate_catalogue:field(<<"commit">>, Source)}
                        || {Version, Source} <- Sources]) =:= maps:from_list(Pins),
        "option catalogue source pins differ from schema/tmux-sources.json", []).

%% Generation

-doc "The Erlang data module and the Markdown reference for `Data`, by repository path.".
-spec generate(generate_json:json()) -> [{string(), binary()}].
generate(Data) ->
    Sources = generate_catalogue:members(field(<<"sources">>, Data)),
    Entries = generate_catalogue:members(field(<<"entries">>, Data)),
    [{?DATA_PATH, unicode:characters_to_binary(data_module(Sources, Entries))},
     {?REFERENCE_PATH, unicode:characters_to_binary(reference(Sources, Entries))}].

field(Key, Object) -> generate_catalogue:field(Key, Object).

data_module(Sources, Entries) ->
    ["%% Generated by scripts/generate/generate_options.erl; do not edit.\n"
     "-module(tmux_option_data).\n-moduledoc false.\n"
     "-export([versions/0, names/0, variants/1]).\n\n"
     "-spec versions() -> [binary()].\nversions() -> [",
     lists:join(", ", [binary(Version) || {Version, _} <- Sources]),
     "].\n\n"
     "-spec names() -> [binary()].\nnames() -> [\n    ",
     lists:join(",\n    ", [binary(Name) || {Name, _} <- Entries]),
     "].\n\n"
     "-spec variants(binary()) -> [{[binary()], map()}].\n",
     [["variants(", binary(Name), ") -> [\n",
       lists:join(",\n", [variant(Variant) || Variant <- Variants]), "];\n"]
      || {Name, Variants} <- Entries],
     "variants(_) -> [].\n"].

variant(Variant) ->
    Versions = [binary(Version) || Version <- field(<<"versions">>, Variant)],
    ["    {[", lists:join(", ", Versions), "], ", metadata(field(<<"metadata">>, Variant)), "}"].

binary(Value) -> ["<<\"", Value, "\">>"].

metadata(Value) ->
    ["#{scopes => [", lists:join(", ", field(<<"scopes">>, Value)), "], type => ",
     field(<<"type">>, Value), ", array => ", atom_to_binary(field(<<"array">>, Value)),
     ", hook => ", atom_to_binary(field(<<"hook">>, Value)), "}"].

reference(Sources, Entries) ->
    ["# Option catalogue\n\n"
     "Generated from pinned tmux `options-table.c` files by\n"
     "`scripts/generate/generate_options.erl`. [Scoped options](options.md)\n"
     "defines the public API. Types describe tmux's parser; values use binary\n"
     "text. Hooks appear for discovery and are rejected by the option API.\n\n"
     "## Sources\n\n| Version | Source | SHA-256 | Entries |\n"
     "| --- | --- | --- | --- |\n",
     [["| ", Version, " | [Table](https://github.com/tmux/tmux/blob/",
       field(<<"commit">>, Source), "/options-table.c) | `", field(<<"sha256">>, Source),
       "` | ", integer_to_binary(field(<<"entries">>, Source)), " |\n"]
      || {Version, Source} <- Sources],
     "\n## Options and hooks\n\n"
     "| Name | Versions | Scopes | Type | Array | Hook |\n"
     "| --- | --- | --- | --- | --- | --- |\n",
     [option_row(Name, Variant) || {Name, Variants} <- Entries, Variant <- Variants]].

option_row(Name, Variant) ->
    Metadata = field(<<"metadata">>, Variant),
    ["| `", Name, "` | ", lists:join(", ", field(<<"versions">>, Variant)), " | ",
     lists:join(", ", field(<<"scopes">>, Metadata)), " | ", field(<<"type">>, Metadata),
     " | ", atom_to_binary(field(<<"array">>, Metadata)), " | ",
     atom_to_binary(field(<<"hook">>, Metadata)), " |\n"].
