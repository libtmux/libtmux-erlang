-module(generate_options_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

-define(PINS, [{<<"3.3">>, <<"c33">>}, {<<"3.4">>, <<"c34">>}]).

table(Rows) ->
    iolist_to_binary(["#include \"tmux.h\"\n#define HOOK(n) \"after-\" n\n"
                      "const struct options_table_entry options_table[] = {\n",
                      Rows, "{ .name = NULL }\n};\n"]).

row(Name, Scope, Type, Flags) ->
    ["{ .name = ", Name, ",\n  .type = OPTIONS_TABLE_", Type, ",\n  .scope = ", Scope, ",\n",
     Flags, "  .text = \"a { brace\"\n},\n"].

%% Test stand-in for cc -E -P: expand the one macro the fixture defines.
expand(Text) ->
    binary:replace(Text, <<"HOOK(\"bind-key\")">>, <<"\"after-\" \"bind-key\"">>).

source(Tables) ->
    #{read => fun(Commit, <<"options-table.c">>) -> maps:get(Commit, Tables) end,
      preprocess => fun expand/1}.

tables() ->
    Common = [row("\"status\"", "OPTIONS_TABLE_SESSION", "FLAG", ""),
              row("\"after-bind-key\"", "OPTIONS_TABLE_SESSION|OPTIONS_TABLE_WINDOW", "COMMAND",
                  "  .flags = OPTIONS_TABLE_IS_ARRAY|OPTIONS_TABLE_IS_HOOK,\n")],
    #{<<"c33">> => table(Common),
      <<"c34">> => table(Common ++ [row("\"copy-mode-position-format\"",
                                        "OPTIONS_TABLE_PANE", "STRING", "")])}.

refresh(Tables) -> generate_options:refresh(source(Tables), ?PINS).

field(Key, Object) -> generate_catalogue:field(Key, Object).

with_row(Row) ->
    Tables = tables(),
    Tables#{<<"c34">> := table([Row, row("\"status\"", "OPTIONS_TABLE_SESSION", "FLAG", "")])}.

%% Initializers

initializers_ignore_braces_in_literals_test() ->
    Text = <<"x options_table[] = {\n{ .a = \"}{\\\"}\", .b = '{' },\n{ .c = { 1 } }\n};\nafter">>,
    ?assertEqual([<<"{ .a = \"}{\\\"}\", .b = '{' }">>, <<"{ .c = { 1 } }">>],
                 generate_options:initializers(Text)).

initializers_refuse_an_unterminated_table_test() ->
    ?assertError({value_error, <<"unterminated options_table">>},
                 generate_options:initializers(<<"options_table[] = {\n{ .a = 1 },\n">>)),
    ?assertError({value_error, <<"unterminated options_table">>},
                 generate_options:initializers(<<"{ .a = 1 }">>)).

%% Refresh

refresh_collects_options_and_versions_test() ->
    Data = refresh(tables()),
    Entries = field(<<"entries">>, Data),
    ?assertEqual([<<"after-bind-key">>, <<"copy-mode-position-format">>, <<"status">>],
                 [Name || {Name, _} <- Entries]),
    [Hook] = field(<<"after-bind-key">>, Entries),
    ?assertEqual([<<"3.3">>, <<"3.4">>], field(<<"versions">>, Hook)),
    ?assertEqual([{<<"scopes">>, [<<"session">>, <<"window">>]}, {<<"type">>, <<"command">>},
                  {<<"array">>, true}, {<<"hook">>, true}], field(<<"metadata">>, Hook)),
    [Pane] = field(<<"copy-mode-position-format">>, Entries),
    ?assertEqual([<<"3.4">>], field(<<"versions">>, Pane)),
    Sources = field(<<"sources">>, Data),
    ?assertEqual([{<<"commit">>, <<"c33">>}, {<<"file">>, <<"options-table.c">>},
                  {<<"sha256">>, script_util:sha256_hex(maps:get(<<"c33">>, tables()))},
                  {<<"entries">>, 2}], field(<<"3.3">>, Sources)),
    ?assertEqual(3, field(<<"entries">>, field(<<"3.4">>, Sources))).

refresh_expands_concatenated_names_test() ->
    Hook = row("HOOK(\"bind-key\")", "OPTIONS_TABLE_SESSION|OPTIONS_TABLE_WINDOW", "COMMAND",
               "  .flags = OPTIONS_TABLE_IS_ARRAY|OPTIONS_TABLE_IS_HOOK,\n"),
    Tables = with_row(Hook),
    Entries = field(<<"entries">>, refresh(Tables)),
    ?assertMatch([_], field(<<"after-bind-key">>, Entries)),
    ?assertEqual([<<"3.3">>, <<"3.4">>],
                 field(<<"versions">>, hd(field(<<"after-bind-key">>, Entries)))).

refresh_splits_a_changed_option_into_variants_test() ->
    Changed = binary:replace(maps:get(<<"c34">>, tables()),
                             <<"OPTIONS_TABLE_FLAG">>, <<"OPTIONS_TABLE_NUMBER">>),
    Entries = field(<<"entries">>, refresh(#{<<"c33">> => maps:get(<<"c33">>, tables()),
                                             <<"c34">> => Changed})),
    ?assertEqual([[<<"3.3">>], [<<"3.4">>]],
                 [field(<<"versions">>, Variant) || Variant <- field(<<"status">>, Entries)]).

refresh_refuses_test_() ->
    Refused = fun(Reason, Row) ->
                  ?assertError({value_error, Reason}, refresh(with_row(Row)))
              end,
    [{"duplicate option",
      fun() -> ?assertError({value_error, <<"invalid or duplicate option: status">>},
                            refresh(with_row(row("\"status\"", "OPTIONS_TABLE_SESSION",
                                                 "FLAG", ""))))
      end},
     {"invalid name",
      fun() -> Refused(<<"invalid or duplicate option: Status">>,
                       row("\"Status\"", "OPTIONS_TABLE_SESSION", "FLAG", ""))
      end},
     {"unparsed name",
      fun() -> ?assertError({value_error, <<"unrecognized option name: ", _/binary>>},
                            refresh(with_row(row("name_macro", "OPTIONS_TABLE_SESSION",
                                                 "FLAG", ""))))
      end},
     {"unknown scope",
      fun() -> Refused(<<"unrecognized scope: OPTIONS_TABLE_SESSION|BOGUS">>,
                       row("\"x\"", "OPTIONS_TABLE_SESSION|BOGUS", "FLAG", ""))
      end},
     {"unknown type",
      fun() -> Refused(<<"unrecognized option type: bogus">>,
                       row("\"x\"", "OPTIONS_TABLE_SESSION", "BOGUS", ""))
      end},
     {"conditional table",
      fun() -> Conditional = <<"#if X\n", (maps:get(<<"c33">>, tables()))/binary>>,
               ?assertError({value_error, <<"conditional table requires", _/binary>>},
                            refresh((tables())#{<<"c33">> := Conditional}))
      end}].

%% Validation and generation

validate_refuses_changed_pins_test() ->
    Data = refresh(tables()),
    ?assertEqual(ok, generate_options:validate(Data, ?PINS)),
    Differs = <<"option catalogue source pins differ from schema/tmux-sources.json">>,
    Moved = [{<<"3.3">>, <<"c33">>}, {<<"3.4">>, <<"other">>}],
    ?assertError({value_error, Differs}, generate_options:validate(Data, Moved)),
    ?assertError({value_error, Differs},
                 generate_options:validate(Data, [{<<"3.3">>, <<"c33">>}])).

generate_writes_the_documented_format_test() ->
    [{Module, Data}, {Reference, Markdown}] = generate_options:generate(refresh(tables())),
    ?assertEqual("apps/libtmux_erlang/src/tmux_option_data.erl", Module),
    ?assertEqual("docs/options-reference.md", Reference),
    ?assertMatch(<<"%% Generated by scripts/generate/generate_options.erl; do not edit.\n"
                   "-module(tmux_option_data).\n", _/binary>>, Data),
    ?assertMatch({_, _}, binary:match(Data, <<"versions() -> [<<\"3.3\">>, <<\"3.4\">>].\n">>)),
    ?assertMatch({_, _}, binary:match(
        Data, <<"variants(<<\"after-bind-key\">>) -> [\n    {[<<\"3.3\">>, <<\"3.4\">>], "
                "#{scopes => [session, window], type => command, array => true, "
                "hook => true}}];\n">>)),
    ?assertMatch({_, _}, binary:match(Data, <<"variants(_) -> [].\n">>)),
    ?assertMatch({_, _}, binary:match(
        Markdown, <<"| `status` | 3.3, 3.4 | session | flag | false | false |\n">>)).
