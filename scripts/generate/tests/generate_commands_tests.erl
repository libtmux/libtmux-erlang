-module(generate_commands_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

-define(PINS, [{<<"3.3">>, <<"c33">>}, {<<"3.3a">>, <<"c33a">>}, {<<"3.4">>, <<"c34">>}]).

%% Fixtures: a command is {Symbol, Name, AliasField, ArgumentSpec, Low, High}.

command(Name, Alias, Spec, Low, High) ->
    Symbol = "cmd_" ++ string:replace(binary_to_list(Name), "-", "_", all) ++ "_entry",
    {lists:flatten(Symbol), Name, Alias, Spec, Low, High}.

commands(#{list_keys := ListKeys, send_keys := SendKeys}) ->
    [command(<<"attach-session">>, ".alias = \"attach\",\n", "c:", 0, 0),
     command(<<"list-sessions">>, "", "f:F:", 0, 0),
     command(<<"list-windows">>, ".alias = NULL,\n", "f:F:", 0, 0),
     command(<<"list-panes">>, "", "f:F:", 0, 0),
     command(<<"send-keys">>, ".alias = \"send\",\n", SendKeys, 0, -1),
     command(<<"list-keys">>, "", ListKeys, 0, 1),
     command(<<"select-layout">>, "", "", 0, 1)].

tree(Commands, Layout) ->
    Table = ["const struct cmd_entry *cmd_table[] = {\n",
             [["&", Symbol, ",\n"] || {Symbol, _, _, _, _, _} <- Commands], "NULL\n};\n"],
    Entries = [["const struct cmd_entry ", Symbol, " = {\n.name = \"", Name, "\",\n", Alias,
                ".args = { \"", Spec, "\", ", integer_to_list(Low), ", ", integer_to_list(High),
                ", NULL },\n};\n"] || {Symbol, Name, Alias, Spec, Low, High} <- Commands],
    #{<<"cmd.c">> => iolist_to_binary(Table),
      <<"cmd-fixture.c">> => iolist_to_binary(Entries),
      <<"layout-custom.c">> => case Layout of
                                   true -> <<"layout_parse_json(cell);\n">>;
                                   false -> <<"layout_parse(cell);\n">>
                               end}.

standard(Layout, ListKeys, SendKeys) ->
    tree(commands(#{list_keys => ListKeys, send_keys => SendKeys}), Layout).

%% 3.3 and 3.3a are identical; 3.4 adds list-keys -F and layout JSON.
trees() ->
    #{<<"c33">> => standard(false, "T:", "Kc:"),
      <<"c33a">> => standard(false, "T:", "Kc:"),
      <<"c34">> => standard(true, "F:T:", "Kc:")}.

source(Trees) ->
    #{read => fun(Commit, Path) -> maps:get(Path, maps:get(Commit, Trees)) end,
      list => fun(Commit) -> maps:keys(maps:get(Commit, Trees)) end}.

refresh(Trees) -> generate_commands:refresh(source(Trees), ?PINS).

replace(Commit, File, From, To, Trees) ->
    Tree = maps:get(Commit, Trees),
    Text = maps:get(File, Tree),
    ?assertNotEqual(nomatch, binary:match(Text, From)),
    Trees#{Commit := Tree#{File := binary:replace(Text, From, To)}}.

field(Key, Object) -> generate_catalogue:field(Key, Object).

%% Refresh

refresh_collects_variants_features_and_digests_test() ->
    Data = refresh(trees()),
    ?assertEqual([<<"3.3">>, <<"3.3a">>, <<"3.4">>], field(<<"versions">>, Data)),
    Commands = field(<<"commands">>, Data),
    ?assertEqual([<<"attach-session">>, <<"list-keys">>, <<"list-panes">>, <<"list-sessions">>,
                  <<"list-windows">>, <<"select-layout">>, <<"send-keys">>],
                 [Name || {Name, _} <- Commands]),
    [First, Second] = field(<<"list-keys">>, Commands),
    ?assertEqual([<<"3.3">>, <<"3.3a">>], field(<<"versions">>, First)),
    ?assertEqual([<<"3.4">>], field(<<"versions">>, Second)),
    ?assertEqual([{<<"alias">>, null}, {<<"argument_spec">>, <<"F:T:">>}, {<<"min_args">>, 0},
                  {<<"max_args">>, 1}, {<<"file">>, <<"cmd-fixture.c">>}],
                 field(<<"metadata">>, Second)),
    [Attach] = field(<<"attach-session">>, Commands),
    ?assertEqual(<<"attach">>, field(<<"alias">>, field(<<"metadata">>, Attach))),
    [Send] = field(<<"send-keys">>, Commands),
    ?assertEqual(null, field(<<"max_args">>, field(<<"metadata">>, Send))),
    Features = field(<<"features">>, Data),
    ?assertEqual([3, 3], field(<<"minimum">>, field(<<"native_list_filter">>, Features))),
    ?assertEqual([3, 3], field(<<"minimum">>, field(<<"send_client_keys">>, Features))),
    ?assertEqual([3, 4], field(<<"minimum">>, field(<<"key_list_format">>, Features))),
    ?assertEqual([<<"3.4">>], field(<<"versions">>, field(<<"layout_json">>, Features))),
    Source = field(<<"3.4">>, field(<<"sources">>, Data)),
    ?assertEqual(<<"c34">>, field(<<"commit">>, Source)),
    ?assertEqual([<<"cmd-fixture.c">>, <<"cmd.c">>, <<"layout-custom.c">>],
                 [Path || {Path, _} <- generate_catalogue:members(field(<<"files">>, Source))]),
    ?assertEqual(script_util:sha256_hex(<<"layout_parse_json(cell);\n">>),
                 field(<<"layout-custom.c">>, field(<<"files">>, Source))).

refresh_refuses_test_() ->
    Trees = trees(),
    Refused = fun(Reason, Changed) ->
                  ?assertError({value_error, Reason}, refresh(Changed))
              end,
    [{"explicit alias spelled as two literals",
      fun() -> Refused(<<"unrecognized explicit command alias: cmd_attach_session_entry">>,
                       replace(<<"c34">>, <<"cmd-fixture.c">>, <<".alias = \"attach\",">>,
                               <<".alias = \"att\" \"ach\",">>, Trees))
      end},
     {"explicit alias with a comment",
      fun() -> Refused(<<"unrecognized explicit command alias: cmd_attach_session_entry">>,
                       replace(<<"c34">>, <<"cmd-fixture.c">>, <<".alias = \"attach\",">>,
                               <<".alias /* field comment */ = \"attach\",">>, Trees))
      end},
     {"conditional initializer",
      fun() -> Refused(<<"conditional command initializer: cmd_send_keys_entry">>,
                       replace(<<"c33">>, <<"cmd-fixture.c">>, <<".name = \"send-keys\",">>,
                               <<"#ifdef X\n.name = \"send-keys\",\n#endif">>, Trees))
      end},
     {"duplicate canonical command",
      fun() -> Refused(<<"duplicate canonical command: list-keys">>,
                       replace(<<"c33a">>, <<"cmd-fixture.c">>, <<".name = \"list-panes\",">>,
                               <<".name = \"list-keys\",">>, Trees))
      end},
     {"minimum above maximum",
      fun() -> Refused(<<"invalid argument bounds: list-keys">>,
                       replace(<<"c34">>, <<"cmd-fixture.c">>, <<"\"F:T:\", 0, 1,">>,
                               <<"\"F:T:\", 2, 1,">>, Trees))
      end},
     {"maximum below unbounded",
      fun() -> Refused(<<"invalid argument bounds: list-keys">>,
                       replace(<<"c34">>, <<"cmd-fixture.c">>, <<"\"F:T:\", 0, 1,">>,
                               <<"\"F:T:\", 0, -2,">>, Trees))
      end},
     {"invalid canonical name",
      fun() -> Refused(<<"invalid canonical command: Select">>,
                       replace(<<"c33">>, <<"cmd-fixture.c">>, <<".name = \"select-layout\",">>,
                               <<".name = \"Select\",">>, Trees))
      end},
     {"unparsed initializer",
      fun() -> Refused(<<"unrecognized command initializer: cmd_list_keys_entry">>,
                       replace(<<"c33">>, <<"cmd-fixture.c">>, <<".args = { \"T:\"">>,
                               <<".args = { T_SPEC">>, Trees))
      end},
     {"unparsed command table",
      fun() -> Refused(<<"unrecognized command table: 3.4">>,
                       replace(<<"c34">>, <<"cmd.c">>, <<"NULL">>, <<"&cmd_x, NULL">>, Trees))
      end},
     {"capability without a monotonic policy",
      fun() -> Refused(<<"capability needs a non-monotonic policy: send_client_keys">>,
                       replace(<<"c33a">>, <<"cmd-fixture.c">>, <<"\"Kc:\"">>, <<"\"c:\"">>,
                               Trees))
      end}].

%% Validation

valid() ->
    Data = refresh(trees()),
    ok = generate_commands:validate(Data, ?PINS),
    Data.

put([], Value, _) -> Value;
put([Index | Rest], Value, List) when is_integer(Index) ->
    {Before, [Item | After]} = lists:split(Index - 1, List),
    Before ++ [put(Rest, Value, Item) | After];
put([Key | Rest], Value, Object) ->
    lists:keyreplace(Key, 1, Object, {Key, put(Rest, Value, field(Key, Object))}).

validate_refuses_test_() ->
    Refused = fun(Reason, Data, Pins) ->
                  ?assertError({value_error, Reason}, generate_commands:validate(Data, Pins))
              end,
    Pin = fun(Version, Commit) -> lists:keyreplace(Version, 1, ?PINS, {Version, Commit}) end,
    [{"pinned commit changed",
      fun() -> Refused(<<"command catalogue source commits differ from schema/tmux-sources.json">>,
                       valid(), Pin(<<"3.4">>, <<"other">>))
      end},
     {"pinned version added",
      fun() -> Refused(<<"command catalogue profiles differ from schema/tmux-sources.json">>,
                       valid(), ?PINS ++ [{<<"3.5">>, <<"c35">>}])
      end},
     {"digest malformed",
      fun() -> Refused(<<"invalid command source digest: attach-session">>,
                       put([<<"sources">>, <<"3.3">>, <<"files">>, <<"cmd-fixture.c">>],
                           <<"ABC">>, valid()), ?PINS)
      end},
     {"digest missing for the declaring file",
      fun() -> Refused(<<"invalid command source digest: attach-session">>,
                       put([<<"commands">>, <<"attach-session">>, 1, <<"metadata">>, <<"file">>],
                           <<"cmd-missing.c">>, valid()), ?PINS)
      end},
     {"profile claimed twice",
      fun() -> Refused(<<"invalid command profiles: list-keys">>,
                       put([<<"commands">>, <<"list-keys">>, 2, <<"versions">>],
                           [<<"3.3a">>, <<"3.4">>], valid()), ?PINS)
      end},
     {"profile not pinned",
      fun() -> Refused(<<"invalid command profiles: select-layout">>,
                       put([<<"commands">>, <<"select-layout">>, 1, <<"versions">>],
                           [<<"9.9">>], valid()), ?PINS)
      end},
     {"capability minimum disagrees with its profiles",
      fun() -> Refused(<<"invalid capability minimum/profile policy: layout_json">>,
                       put([<<"features">>, <<"layout_json">>, <<"minimum">>], [3, 3], valid()),
                       ?PINS)
      end},
     {"capability missing",
      fun() -> Refused(<<"unknown or missing capability policy">>,
                       put([<<"features">>],
                           lists:keydelete(<<"layout_json">>, 1, field(<<"features">>, valid())),
                           valid()), ?PINS)
      end}].

%% Generation

generate_names_the_script_and_keeps_the_schema_order_test() ->
    [{Module, Data}, {Reference, Markdown}] = generate_commands:generate(valid()),
    ?assertEqual("apps/libtmux_erlang/src/tmux_capability_data.erl", Module),
    ?assertEqual("docs/commands-reference.md", Reference),
    ?assertMatch(<<"%% Generated by scripts/generate/generate_commands.erl; do not edit.\n"
                   "-module(tmux_capability_data).\n", _/binary>>, Data),
    ?assertMatch({_, _}, binary:match(Data, <<"#{version => 1,\nversions => [<<\"3.3\">>, ">>)),
    ?assertMatch({_, _}, binary:match(Data, <<"alias => none,\nargument_spec => <<\"F:T:\">>,">>)),
    ?assertMatch({_, _}, binary:match(
        Markdown, <<"| `list-keys` | \xe2\x80\x94 | 3.3, 3.3a | `T:` | 0..1 | "
                    "[Declaration](https://github.com/tmux/tmux/blob/c33a/cmd-fixture.c) |\n">>)),
    ?assertMatch({_, _}, binary:match(Markdown, <<"| `key_list_format` | 3.4 | ">>)).
