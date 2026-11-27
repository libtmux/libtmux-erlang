-module(preview_cleanup_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

with_settings(Fun) ->
    script_util:with_tmp_dir("preview-cleanup-test", fun(Directory) ->
        Settings = #{pr => "42", repository => "libtmux/libtmux-erlang",
                     bucket => "docs-test", output => filename:join(Directory, "output")},
        put(commands, []),
        try Fun(Settings)
        after erase(commands)
        end
    end).

runner(Status, Response) ->
    fun(Executable, Arguments, _) ->
        put(commands, get(commands) ++ [{Executable, Arguments}]),
        #{status => Status, stdout => iolist_to_binary(Response)}
    end.

query() -> {"gh", ["api", "--method", "GET", "repos/libtmux/libtmux-erlang/pulls/42"]}.

current_state_controls_eligibility_test() ->
    lists:foreach(fun({State, Expected}) ->
        with_settings(fun(#{output := Output} = Settings) ->
            Response = json:encode(#{number => 42, state => State}),
            ok = preview_cleanup:run("eligibility", Settings, runner(0, Response)),
            ?assertEqual({ok, <<"should_cleanup=false\nshould_cleanup=", Expected/binary, "\n">>},
                         file:read_file(Output)),
            ?assertEqual([query()], get(commands))
        end)
    end, [{<<"closed">>, <<"true">>}, {<<"open">>, <<"false">>}]).

invalid_responses_cannot_authorize_cleanup_test() ->
    lists:foreach(fun(Response) ->
        with_settings(fun(#{output := Output} = Settings) ->
            ?assertError({preview_cleanup, invalid_pull_request_response},
                preview_cleanup:run("eligibility", Settings, runner(0, Response))),
            ?assertEqual({ok, <<"should_cleanup=false\n">>}, file:read_file(Output))
        end)
    end, [<<"{\"number\":43,\"state\":\"closed\"}">>,
          <<"{\"number\":42,\"state\":\"unknown\"}">>,
          <<"{\"number\":\"42\",\"state\":\"closed\"}">>,
          <<"{\"number\":42}">>, <<"[]">>, <<"not json">>,
          <<"{\"number\":42,\"state\":\"closed\"}\n{}">>]).

query_failure_leaves_cleanup_disabled_test() ->
    with_settings(fun(#{output := Output} = Settings) ->
        ?assertError({preview_cleanup, pull_request_query_failed},
            preview_cleanup:run("eligibility", Settings, runner(1, <<>>))),
        ?assertEqual({ok, <<"should_cleanup=false\n">>}, file:read_file(Output)),
        ?assertEqual([query()], get(commands))
    end).

deletion_rechecks_current_state_and_scopes_the_prefix_test() ->
    lists:foreach(fun(State) ->
        with_settings(fun(Settings) ->
            Response = json:encode(#{number => 42, state => State}),
            ok = preview_cleanup:run("delete", Settings, runner(0, Response)),
            Expected = case State of
                <<"open">> -> [query()];
                <<"closed">> -> [query(), {"aws", ["s3", "rm",
                    "s3://docs-test/en/erlang/pr-42/", "--recursive"]}]
            end,
            ?assertEqual(Expected, get(commands))
        end)
    end, [<<"open">>, <<"closed">>]).

invalid_pr_numbers_never_reach_a_command_test() ->
    lists:foreach(fun(Pr) ->
        with_settings(fun(#{output := Output} = Settings) ->
            ?assertError({preview_cleanup, invalid_pr_number},
                preview_cleanup:run("eligibility", Settings#{pr := Pr}, runner(0, <<>>))),
            ?assertEqual({ok, <<"should_cleanup=false\n">>}, file:read_file(Output)),
            ?assertEqual([], get(commands))
        end)
    end, [false, "", "0", "-1", "42\n", "42/../../latest", "42;exit 0"]).

foreign_repository_never_reaches_a_command_test() ->
    with_settings(fun(Settings) ->
        ?assertError({preview_cleanup, invalid_repository},
            preview_cleanup:run("delete", Settings#{repository := "libtmux/libtmux-lua"},
                                runner(0, <<>>))),
        ?assertEqual([], get(commands))
    end).

invalid_bucket_cannot_change_the_prefix_test() ->
    lists:foreach(fun(Bucket) ->
        with_settings(fun(Settings) ->
            Response = <<"{\"number\":42,\"state\":\"closed\"}">>,
            ?assertError({preview_cleanup, invalid_bucket},
                preview_cleanup:run("delete", Settings#{bucket := Bucket}, runner(0, Response))),
            ?assertEqual([query()], get(commands))
        end)
    end, [false, "", "docs-test/en/python", "docs-test/../latest", "docs-test\n"]).

failed_delete_is_reported_test() ->
    with_settings(fun(Settings) ->
        Runner = fun("gh", Arguments, Options) ->
                     (runner(0, <<"{\"number\":42,\"state\":\"closed\"}">>))(
                         "gh", Arguments, Options);
                    ("aws", Arguments, Options) ->
                     (runner(1, <<>>))("aws", Arguments, Options)
                 end,
        ?assertError({preview_cleanup, preview_delete_failed},
            preview_cleanup:run("delete", Settings, Runner))
    end).
