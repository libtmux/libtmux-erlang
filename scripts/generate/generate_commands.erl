%% Generate native command metadata and capability floors from pinned tmux sources.
%% usage: escript scripts/generate/generate_commands.erl [--check | --refresh-from TREE]
-module(generate_commands).
-mode(compile).
-moduledoc """
Regenerate `tmux_capability_data` and `docs/commands-reference.md` from
`schema/commands.json`.

`--check` fails when a generated file differs from the schema. `--refresh-from`
rebuilds the schema from the pinned commits in a local tmux clone first.
""".
-export([main/1, refresh/2, validate/2, generate/1]).

-define(STRING, "\"(?:[^\"\\\\]|\\\\.)*\"").
-define(DATA_PATH, "apps/libtmux_erlang/src/tmux_capability_data.erl").
-define(REFERENCE_PATH, "docs/commands-reference.md").
-define(FIELDS, [<<"version">>, <<"sources">>, <<"commands">>, <<"features">>,
                 <<"commit">>, <<"files">>, <<"sha256">>, <<"alias">>,
                 <<"argument_spec">>, <<"min_args">>, <<"max_args">>, <<"file">>,
                 <<"metadata">>, <<"versions">>, <<"minimum">>, <<"description">>]).
-define(DIFFERS, "differ from schema/tmux-sources.json").

-spec main([string()]) -> ok.
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    generate_catalogue:main(#{name => "generate_commands",
                              schema => "schema/commands.json",
                              refresh => fun refresh/2,
                              validate => fun validate/2,
                              generate => fun generate/1,
                              drift => "generated file drift"}, Root, Arguments).

features() ->
    [{<<"native_list_filter">>,
      <<"Native -f filters on session, window and pane list commands.">>,
      [<<"list-sessions">>, <<"list-windows">>, <<"list-panes">>]},
     {<<"send_client_keys">>,
      <<"Native send-keys -K and -c for client-directed key input.">>,
      [<<"send-keys">>]},
     {<<"key_list_format">>,
      <<"Native list-keys -F custom formatting.">>,
      [<<"list-keys">>]},
     {<<"layout_json">>,
      <<"Native JSON layout parsing, including the v2 layout representation.">>,
      [<<"select-layout">>]}].

number(Version) ->
    case generate_catalogue:search(Version, "^(\\d+)\\.(\\d+)[a-z]?\\z") of
        [Major, Minor] -> {binary_to_integer(Major), binary_to_integer(Minor)};
        nomatch -> generate_catalogue:value_error("unsupported release spelling: ~ts",
                                                  [Version])
    end.

%% Refresh

-doc """
Build the schema from `Source`, which lists the root of each pinned commit and
reads `cmd.c`, `layout-custom.c` and every `cmd-*.c` file from it.
""".
-spec refresh(generate_catalogue:source(), generate_catalogue:pins()) ->
    generate_json:json().
refresh(Source, Pins) ->
    Profiles = [{Version, Commit, profile(Source, Version, Commit)}
                || {Version, Commit} <- Pins],
    Sources = [{Version, [{<<"commit">>, Commit},
                          {<<"files">>, [{Path, script_util:sha256_hex(Bytes)}
                                         || {Path, Bytes} <- Files]}]}
               || {Version, Commit, {Files, _}} <- Profiles],
    Commands = lists:foldl(
        fun({Version, _, {_, Current}}, Acc) ->
            lists:foldl(fun({Name, Metadata}, Inner) ->
                            add_variant(Name, Metadata, Version, Inner)
                        end, Acc, Current)
        end, #{}, Profiles),
    Features = [feature(Name, Description, Commands0,
                        [Version || {Version, _, {Files, Current}} <- Profiles,
                                    supports(Name, Current, Files)], Pins)
                || {Name, Description, Commands0} <- features()],
    [{<<"version">>, 1},
     {<<"versions">>, [Version || {Version, _} <- Pins]},
     {<<"sources">>, Sources},
     {<<"features">>, Features},
     {<<"commands">>, [{Name, [[{<<"versions">>, Versions}, {<<"metadata">>, Metadata}]
                               || {Versions, Metadata} <- Variants]}
                       || {Name, Variants} <- lists:sort(maps:to_list(Commands))]}].

add_variant(Name, Metadata, Version, Commands) ->
    Variants = maps:get(Name, Commands, []),
    case lists:keyfind(Metadata, 2, Variants) of
        {Versions, Metadata} ->
            Commands#{Name => lists:keyreplace(Metadata, 2, Variants,
                                               {Versions ++ [Version], Metadata})};
        false ->
            Commands#{Name => Variants ++ [{[Version], Metadata}]}
    end.

%% The sorted source files of one commit and its command table, in table order.
profile(Source, Version, Commit) ->
    Read = maps:get(read, Source),
    TableSource = Read(Commit, <<"cmd.c">>),
    Symbols = table_symbols(Version, TableSource),
    Files = lists:keysort(1, [{Path, Read(Commit, Path)}
                              || Path <- (maps:get(list, Source))(Commit),
                                 generate_catalogue:matches(Path, "^cmd-[a-z-]+\\.c\\z")]
                          ++ [{<<"cmd.c">>, TableSource},
                              {<<"layout-custom.c">>, Read(Commit, <<"layout-custom.c">>)}]),
    Entries = lists:foldl(fun({Path, Bytes}, Acc) -> entries(Path, Bytes, Acc) end,
                          #{}, Files),
    Current = lists:foldl(
        fun(Symbol, Acc) ->
            {Name, Metadata} = maps:get(Symbol, Entries),
            ok = generate_catalogue:ensure(not lists:keymember(Name, 1, Acc),
                                           "duplicate canonical command: ~ts", [Name]),
            Acc ++ [{Name, Metadata}]
        end, [], Symbols),
    {Files, Current}.

table_symbols(Version, TableSource) ->
    Found = generate_catalogue:search(
        TableSource, {"cmd_table\\[\\]\\s*=\\s*\\{(.*?)\\n\\};", [dotall]}),
    Table = case Found of
        [Body] -> Body;
        nomatch -> <<"?">>
    end,
    Symbols = [Symbol || [Symbol] <- generate_catalogue:find(Table, "&(cmd_\\w+_entry)")],
    Remainder = re:replace(Table, "&(cmd_\\w+_entry)|NULL|[\\s,]", "",
                           [global, {return, binary}]),
    ok = generate_catalogue:ensure(
        Remainder =:= <<>> andalso Symbols =/= []
            andalso length(Symbols) =:= length(lists:usort(Symbols)),
        "unrecognized command table: ~ts", [Version]),
    Symbols.

entries(Path, Bytes, Entries) ->
    Matches = generate_catalogue:find(
        Bytes, {"const struct cmd_entry (cmd_\\w+_entry)\\s*=\\s*\\{(.*?)\\n\\};", [dotall]}),
    lists:foldl(fun([Symbol, Body], Acc) -> entry(Path, Symbol, Body, Acc) end,
                Entries, Matches).

entry(Path, Symbol, Body, Entries) ->
    ok = generate_catalogue:ensure(
        not generate_catalogue:matches(Body, {"^\\s*#", [multiline]}),
        "conditional command initializer: ~ts", [Symbol]),
    Name = generate_catalogue:search(Body, ["\\.name\\s*=\\s*(", ?STRING, ")\\s*,"]),
    Alias = generate_catalogue:search(Body, ["\\.alias\\s*=\\s*(", ?STRING, "|NULL)\\s*,"]),
    ok = generate_catalogue:ensure(
        Alias =/= nomatch orelse not generate_catalogue:matches(Body, "\\.alias\\b"),
        "unrecognized explicit command alias: ~ts", [Symbol]),
    Arguments = generate_catalogue:search(
        Body, ["\\.args\\s*=\\s*\\{\\s*(", ?STRING, ")\\s*,\\s*(\\d+)\\s*,"
               "\\s*(-?\\d+)\\s*,\\s*(?:NULL|[a-z_]+)\\s*\\}"]),
    ok = generate_catalogue:ensure(
        Name =/= nomatch andalso Arguments =/= nomatch
            andalso not maps:is_key(Symbol, Entries),
        "unrecognized command initializer: ~ts", [Symbol]),
    [NameLiteral] = Name,
    [Spec, Minimum, Maximum] = Arguments,
    Canonical = generate_catalogue:literal(NameLiteral),
    ok = generate_catalogue:ensure(
        generate_catalogue:matches(Canonical, "^[a-z]+(?:-[a-z]+)+\\z"),
        "invalid canonical command: ~ts", [Canonical]),
    Low = binary_to_integer(Minimum),
    High = binary_to_integer(Maximum),
    ok = generate_catalogue:ensure(
        High >= -1 andalso (High < 0 orelse Low =< High),
        "invalid argument bounds: ~ts", [Canonical]),
    Metadata = [{<<"alias">>, case Alias of
                                  nomatch -> null;
                                  [<<"NULL">>] -> null;
                                  [Literal] -> generate_catalogue:literal(Literal)
                              end},
                {<<"argument_spec">>, generate_catalogue:literal(Spec)},
                {<<"min_args">>, Low},
                {<<"max_args">>, case High of -1 -> null; _ -> High end},
                {<<"file">>, Path}],
    Entries#{Symbol => {Canonical, Metadata}}.

supports(<<"native_list_filter">>, Current, _) ->
    lists:all(fun(Command) -> has_flag(<<"f:">>, spec(Command, Current)) end,
              [<<"list-sessions">>, <<"list-windows">>, <<"list-panes">>]);
supports(<<"send_client_keys">>, Current, _) ->
    Spec = spec(<<"send-keys">>, Current),
    has_flag(<<"K">>, Spec) andalso has_flag(<<"c:">>, Spec);
supports(<<"key_list_format">>, Current, _) ->
    has_flag(<<"F:">>, spec(<<"list-keys">>, Current));
supports(<<"layout_json">>, _, Files) ->
    {_, Layout} = lists:keyfind(<<"layout-custom.c">>, 1, Files),
    binary:match(Layout, <<"layout_parse_json(">>) =/= nomatch.

spec(Command, Current) ->
    case lists:keyfind(Command, 1, Current) of
        {_, Metadata} -> generate_catalogue:field(<<"argument_spec">>, Metadata);
        false -> generate_catalogue:value_error("command missing from a profile: ~ts",
                                                [Command])
    end.

has_flag(Flag, Spec) -> binary:match(Spec, Flag) =/= nomatch.

feature(Name, Description, Commands, Versions, Pins) ->
    ok = generate_catalogue:ensure(Versions =/= [], "capability has no source profile: ~ts",
                                   [Name]),
    {Major, Minor} = Minimum = lists:min([number(Version) || Version <- Versions]),
    ok = generate_catalogue:ensure(
        Versions =:= [Version || {Version, _} <- Pins, number(Version) >= Minimum],
        "capability needs a non-monotonic policy: ~ts", [Name]),
    {Name, [{<<"description">>, Description}, {<<"commands">>, Commands},
            {<<"minimum">>, [Major, Minor]}, {<<"versions">>, Versions}]}.

%% Validation

-doc "Check that the schema matches the pinned sources and its own invariants.".
-spec validate(generate_json:json(), generate_catalogue:pins()) -> ok.
validate(Data, Pins) ->
    Versions = [Version || {Version, _} <- Pins],
    ok = generate_catalogue:ensure(
        generate_catalogue:field(<<"version">>, Data) =:= 1
            andalso generate_catalogue:field(<<"versions">>, Data) =:= Versions,
        "command catalogue profiles " ?DIFFERS, []),
    Sources = generate_catalogue:members(generate_catalogue:field(<<"sources">>, Data)),
    ok = generate_catalogue:ensure(
        maps:from_list([{Version, generate_catalogue:field(<<"commit">>, Source)}
                        || {Version, Source} <- Sources]) =:= maps:from_list(Pins),
        "command catalogue source commits " ?DIFFERS, []),
    Features = generate_catalogue:members(generate_catalogue:field(<<"features">>, Data)),
    ok = generate_catalogue:ensure(
        lists:sort([Name || {Name, _} <- Features])
            =:= lists:sort([Name || {Name, _, _} <- features()]),
        "unknown or missing capability policy", []),
    lists:foreach(fun({Name, Feature}) -> validate_feature(Name, Feature, Versions) end,
                  Features),
    Digests = maps:from_list(
        [{Version, maps:from_list(generate_catalogue:members(
                                      generate_catalogue:field(<<"files">>, Source)))}
         || {Version, Source} <- Sources]),
    lists:foreach(
        fun({Name, Variants}) -> validate_variants(Name, Variants, Versions, Digests) end,
        generate_catalogue:members(generate_catalogue:field(<<"commands">>, Data))).

validate_feature(Name, Feature, Versions) ->
    Valid = case generate_catalogue:field(<<"minimum">>, Feature) of
        [Major, Minor] when is_integer(Major), Major >= 0, is_integer(Minor), Minor >= 0 ->
            generate_catalogue:field(<<"versions">>, Feature)
                =:= [Version || Version <- Versions, number(Version) >= {Major, Minor}];
        _ -> false
    end,
    ok = generate_catalogue:ensure(Valid, "invalid capability minimum/profile policy: ~ts",
                                   [Name]).

validate_variants(Name, Variants, Versions, Digests) ->
    _ = lists:foldl(
        fun(Variant, Seen) ->
            Profiles = generate_catalogue:field(<<"versions">>, Variant),
            ok = generate_catalogue:ensure(
                Profiles =/= [] andalso Profiles -- Versions =:= []
                    andalso not lists:any(fun(Profile) -> lists:member(Profile, Seen) end,
                                          Profiles),
                "invalid command profiles: ~ts", [Name]),
            File = generate_catalogue:field(
                <<"file">>, generate_catalogue:field(<<"metadata">>, Variant)),
            lists:foreach(
                fun(Profile) ->
                    Digest = maps:get(File, maps:get(Profile, Digests), undefined),
                    ok = generate_catalogue:ensure(generate_catalogue:is_hex(Digest, 64),
                                                   "invalid command source digest: ~ts", [Name])
                end, Profiles),
            Seen ++ Profiles
        end, [], Variants),
    ok.

%% Generation

-doc "The Erlang data module and the Markdown reference for `Data`, by repository path.".
-spec generate(generate_json:json()) -> [{string(), binary()}].
generate(Data) ->
    [{?DATA_PATH, unicode:characters_to_binary(data_module(Data))},
     {?REFERENCE_PATH, unicode:characters_to_binary(reference(Data))}].

data_module(Data) ->
    ["%% Generated by scripts/generate/generate_commands.erl; do not edit.\n"
     "-module(tmux_capability_data).\n-moduledoc false.\n"
     "-export([all/0]).\n-spec all() -> map().\nall() ->\n",
     erlang(Data), ".\n"].

erlang(null) -> "none";
erlang(Text) when is_binary(Text) -> ["<<", generate_json:encode_string(Text), ">>"];
erlang(Number) when is_integer(Number) -> integer_to_list(Number);
erlang([]) -> "[]";
erlang(Empty) when is_map(Empty), map_size(Empty) =:= 0 -> "#{}";
erlang([{_, _} | _] = Members) ->
    ["#{", lists:join(",\n", [[key(Key), " => ", erlang(Value)] || {Key, Value} <- Members]),
     "}"];
erlang(Elements) when is_list(Elements) ->
    ["[", lists:join(", ", [erlang(Element) || Element <- Elements]), "]"].

key(Key) ->
    case lists:member(Key, ?FIELDS) of
        true -> Key;
        false -> erlang(Key)
    end.


reference(Data) ->
    Features = generate_catalogue:members(field(<<"features">>, Data)),
    Sources = generate_catalogue:members(field(<<"sources">>, Data)),
    Commands = generate_catalogue:members(field(<<"commands">>, Data)),
    ["# Native commands and capability floors\n\n"
     "Generated from pinned tmux source profiles. These are native\n"
     "parser declarations, not an inventory of implemented Erlang facades,\n"
     "complete argument validation or runtime qualification. Canonical names\n"
     "are lookup keys; aliases are reported as metadata. The\n"
     "`m:tmux_capability` performs pure lookups. Trusted raw commands remain\n"
     "available through `tmux_command:raw/2`.\n\n"
     "## Capability minimums\n\n"
     "Capability minimums name the earliest catalogued source profile for\n"
     "each feature. Runtime support covers tmux 3.3a\x{2013}3.8, including\n"
     "intermediate releases. Routine CI samples only 3.3a and 3.8 on both\n"
     "supported architectures. See\n"
     "[compatibility](compatibility.md) for platform and API qualification.\n\n"
     "| Capability | Minimum tmux | Native behavior |\n"
     "| --- | --- | --- |\n",
     [capability_row(Name, Feature) || {Name, Feature} <- lists:keysort(1, Features)],
     "\n## Source profiles\n\n"
     "Exact parser discovery uses the profiles below. The 3.3 profile is\n"
     "retained as upstream history; the library's runtime floor is 3.3a.\n\n"
     "| Profile | Pinned command table | Commands |\n| --- | --- | --- |\n",
     [profile_row(Version, Source, Commands) || {Version, Source} <- Sources],
     "\n## Parser declarations\n\n"
     "The argument spec is tmux's native flag declaration. Positional bounds\n"
     "exclude flags; an unlimited upper bound is shown as unbounded. Callbacks\n"
     "and command bodies can impose additional constraints. This catalogue\n"
     "does not interpret formats, shell commands or stored command syntax.\n\n"
     "| Command | Alias | Profiles | Argument spec | Positionals | Source |\n"
     "| --- | --- | --- | --- | --- | --- |\n",
     [declaration_row(Name, Variant, Sources) || {Name, Variants} <- Commands,
                                                 Variant <- Variants]].

field(Key, Object) -> generate_catalogue:field(Key, Object).

capability_row(Name, Feature) ->
    Minimum = lists:join(".", [integer_to_binary(N) || N <- field(<<"minimum">>, Feature)]),
    ["| `", Name, "` | ", Minimum, " | ", field(<<"description">>, Feature), " |\n"].

profile_row(Version, Source, Commands) ->
    Count = length([Name || {Name, Variants} <- Commands,
                            lists:any(fun(Variant) ->
                                          lists:member(Version, field(<<"versions">>, Variant))
                                      end, Variants)]),
    ["| ", Version, " | [Source](", blob(Source, <<"cmd.c">>), ") | ",
     integer_to_binary(Count), " |\n"].

declaration_row(Name, Variant, Sources) ->
    Metadata = field(<<"metadata">>, Variant),
    Profiles = field(<<"versions">>, Variant),
    {_, Source} = lists:keyfind(lists:last(Profiles), 1, Sources),
    Alias = case field(<<"alias">>, Metadata) of
        Missing when Missing =:= null; Missing =:= <<>> -> "\x{2014}";
        Text -> Text
    end,
    High = case field(<<"max_args">>, Metadata) of
        null -> "unbounded";
        Limit -> integer_to_binary(Limit)
    end,
    ["| `", Name, "` | ", Alias, " | ", lists:join(", ", Profiles), " | `",
     field(<<"argument_spec">>, Metadata), "` | ",
     integer_to_binary(field(<<"min_args">>, Metadata)), "..", High, " | [Declaration](",
     blob(Source, field(<<"file">>, Metadata)), ") |\n"].

blob(Source, File) ->
    ["https://github.com/tmux/tmux/blob/", field(<<"commit">>, Source), "/", File].
