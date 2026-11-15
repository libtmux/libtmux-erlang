-module(generate_catalogue_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

-define(COMMIT, "0123456789abcdef0123456789abcdef01234567").

manifest(Pin) ->
    iolist_to_binary(["{\"version\": 1, \"versions\": {\"3.3\": ", Pin, "}}"]).

parse_pins_reads_versions_in_order_test() ->
    Text = <<"{\"version\": 1, \"versions\": {\"3.8\": {\"commit\": \"", ?COMMIT,
             "\"}, \"3.3\": {\"commit\": \"", ?COMMIT, "\"}}}">>,
    ?assertEqual([{<<"3.8">>, <<?COMMIT>>}, {<<"3.3">>, <<?COMMIT>>}],
                 generate_catalogue:parse_pins(Text)).

parse_pins_refuses_a_loose_manifest_test_() ->
    Refused = fun(Text) ->
                  ?assertError({value_error, _}, generate_catalogue:parse_pins(Text))
              end,
    [fun() -> Refused(manifest(<<"{\"commit\": \"", ?COMMIT, "\", \"url\": \"x\"}">>)) end,
     fun() -> Refused(manifest(<<"{\"commit\": \"main\"}">>)) end,
     fun() -> Upper = list_to_binary(string:uppercase(?COMMIT)),
              Refused(manifest(<<"{\"commit\": \"", Upper/binary, "\"}">>)) end,
     fun() -> Refused(manifest(<<"{}">>)) end,
     fun() -> Refused(<<"{\"version\": 2, \"versions\": {}}">>) end,
     fun() -> Refused(<<"{\"version\": 1, \"versions\": {\"3.3\": {\"commit\": \"", ?COMMIT,
                        "\"}, \"3.3\": {\"commit\": \"", ?COMMIT, "\"}}}">>) end].

literal_decodes_simple_escapes_test() ->
    ?assertEqual(<<"a\"b\\c\n">>, generate_catalogue:literal(<<"\"a\\\"b\\\\c\\n\"">>)),
    ?assertError({value_error, _}, generate_catalogue:literal(<<"\"a\\x41\"">>)),
    ?assertError({value_error, _}, generate_catalogue:literal(<<"NULL">>)).

with_root(Fun) ->
    script_util:with_tmp_dir("generate-catalogue", fun(Root) ->
        ok = filelib:ensure_path(filename:join(Root, "schema")),
        ok = filelib:ensure_path(filename:join(Root, "out")),
        ok = file:write_file(filename:join(Root, "schema/tmux-sources.json"),
                             manifest([<<"{\"commit\": \"">>, ?COMMIT, <<"\"}">>])),
        Schema = filename:join(Root, "schema/fake.json"),
        ok = file:write_file(Schema, <<"{\"value\": \"one\"}\n">>),
        Fun(Root)
    end).

spec() ->
    #{name => "fake",
      schema => "schema/fake.json",
      refresh => fun(_, _) -> [] end,
      validate => fun(Data, _) ->
                      generate_catalogue:ensure(
                          generate_catalogue:field(<<"value">>, Data) =/= <<"bad">>,
                          "refused value", [])
                  end,
      generate => fun(Data) -> [{"out/a.txt", generate_catalogue:field(<<"value">>, Data)}] end,
      drift => "drift"}.

options() -> #{check => false}.

writes_the_generated_files_test() ->
    with_root(fun(Root) ->
        ?assertEqual(ok, generate_catalogue:run(spec(), Root, options())),
        ?assertEqual({ok, <<"one">>}, file:read_file(filename:join(Root, "out/a.txt")))
    end).

check_passes_on_current_files_test() ->
    with_root(fun(Root) ->
        ok = generate_catalogue:run(spec(), Root, options()),
        ?assertEqual(ok, generate_catalogue:run(spec(), Root, #{check => true}))
    end).

check_names_a_changed_file_and_leaves_it_test() ->
    with_root(fun(Root) ->
        ok = generate_catalogue:run(spec(), Root, options()),
        ok = file:write_file(filename:join(Root, "out/a.txt"), <<"changed">>),
        ?assertEqual({drift, "out/a.txt"}, generate_catalogue:run(spec(), Root, #{check => true})),
        ?assertEqual({ok, <<"changed">>}, file:read_file(filename:join(Root, "out/a.txt")))
    end).

check_names_a_missing_file_test() ->
    with_root(fun(Root) ->
        ?assertEqual({drift, "out/a.txt"}, generate_catalogue:run(spec(), Root, #{check => true}))
    end).

a_refused_schema_writes_nothing_test() ->
    with_root(fun(Root) ->
        Schema = filename:join(Root, "schema/fake.json"),
        ok = file:write_file(Schema, <<"{\"value\": \"bad\"}\n">>),
        ?assertError({value_error, <<"refused value">>},
                     generate_catalogue:run(spec(), Root, options())),
        ?assertEqual({error, enoent}, file:read_file_info(filename:join(Root, "out/a.txt")))
    end).

git_source_test_() ->
    {setup,
     fun() -> {ok, _} = application:ensure_all_started(libtmux_erlang) end,
     fun(_) -> ok = application:stop(libtmux_erlang) end,
     fun() ->
         script_util:with_tmp_dir("generate-source", fun(Repository) ->
             Git = fun(Arguments) ->
                       script_util:run_ok("git", ["-C", Repository, "-c", "commit.gpgsign=false",
                                                  "-c", "user.name=test",
                                                  "-c", "user.email=test@example.invalid"
                                                  | Arguments], #{})
                   end,
             _ = Git(["init", "-q"]),
             ok = file:write_file(filename:join(Repository, "cmd-a.c"), <<"first\n">>),
             ok = file:write_file(filename:join(Repository, "b c.c"), <<"second\n">>),
             _ = Git(["add", "."]),
             _ = Git(["commit", "-q", "-m", "one"]),
             Commit = string:trim(Git(["rev-parse", "HEAD"])),
             Source = generate_catalogue:git_source(Repository),
             ?assertEqual(<<"first\n">>, (maps:get(read, Source))(Commit, <<"cmd-a.c">>)),
             ?assertEqual([<<"b c.c">>, <<"cmd-a.c">>], (maps:get(list, Source))(Commit)),
             ?assertEqual(<<"1 + 2\n">>,
                          (maps:get(preprocess, Source))(<<"#define ONE 1\nONE + 2\n">>))
         end)
     end}.
