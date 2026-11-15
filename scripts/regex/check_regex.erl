%% Compare the portable regex fixture against PCRE2, JavaScript and Rust.
%% Usage: escript scripts/regex/check_regex.erl
%% Needs the compiled library, node, and the Rust reference binary built by
%% tools/regex-conformance/README.md; writes _build/checks/regex.json.
-module(check_regex).
-mode(compile).
-export([main/1, payload/2, differences/2, crate_version/1]).

-define(RECEIPT, "_build/checks/regex.json").
-define(RUST, "_build/regex-conformance/debug/libtmux-regex-conformance").

-spec main([string()]) -> no_return().
main([]) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    Started = erlang:monotonic_time(millisecond),
    Native = json:decode(script_util:run_ok("escript", ["tools/regex_fixture.escript"],
        #{timeout_ms => 20000})),
    Patterns = maps:get(<<"patterns">>, Native),
    Expected = expected(Patterns),
    Engines = [{javascript, "node", ["tools/regex-conformance/javascript.mjs"]},
               {rust, filename:absname(?RUST), []}],
    Results = [engine(Name, Program, Arguments, Patterns, Expected)
               || {Name, Program, Arguments} <- Engines],
    Fixture = "test/fixtures/regex-v1.json",
    Receipt = #{result => <<"PASS">>, patterns => length(Patterns),
        cases_per_engine => length(Expected),
        engines => maps:from_list(Results),
        pcre2 => <<"PASS: all expected fixture results">>,
        native_versions => maps:with([<<"otp">>, <<"erts">>, <<"pcre2">>], Native),
        node => trim(script_util:run_ok("node", ["--version"], #{})),
        rustc => trim(script_util:run_ok("rustc", ["--version"], #{})),
        regex_crate => crate_version(read("tools/regex-conformance/Cargo.lock")),
        fixture_sha256 => script_util:sha256_hex({file, Fixture}),
        seconds => (erlang:monotonic_time(millisecond) - Started) / 1000,
        scope => <<"Shared grammar renderers and backend matching; not other ports' public filter APIs">>},
    ok = filelib:ensure_path("_build/checks"),
    Document = json:format(Receipt),
    ok = file:write_file(?RECEIPT, [Document, $\n]),
    io:format("~s~n", [Document]),
    halt(0);
main(_) ->
    io:format(standard_error, "usage: check_regex.erl~n", []),
    halt(2).

engine(Name, Program, Arguments, Patterns, Expected) ->
    Result = script_util:run(Program, Arguments,
        #{stdin => payload(atom_to_binary(Name), Patterns), timeout_ms => 20000}),
    case Result of
        #{status := 0, stdout := Out} ->
            Actual = binary:split(Out, <<"\n">>, [global, trim]),
            case differences(Actual, Expected) of
                [] -> {Name, #{result => <<"PASS">>, cases => length(Actual)}};
                Diff -> error({regex_engine_mismatch, Name, length(Actual),
                               length(Expected), lists:sublist(Diff, 10)})
            end;
        Other -> error({regex_engine_failed, Name, Other})
    end.

%% One line per case: the engine's rendering of the pattern, a tab and the
%% subject as hex.
-spec payload(binary(), [map()]) -> binary().
payload(Engine, Patterns) ->
    iolist_to_binary([[maps:get(Engine, P), $\t, binary:encode_hex(subject(C), lowercase), $\n]
                      || P <- Patterns, C <- maps:get(<<"cases">>, P)]).

subject(Case) -> maps:get(<<"subject">>, Case).

expected(Patterns) ->
    [case maps:get(<<"expected">>, C) of
         true -> <<"true">>;
         false -> <<"false">>;
         Reason -> Reason
     end || P <- Patterns, C <- maps:get(<<"cases">>, P)].

-spec differences([binary()], [binary()]) ->
    [{non_neg_integer() | length, binary(), binary()}].
differences(Actual, Expected) when length(Actual) =/= length(Expected) ->
    [{length, integer_to_binary(length(Actual)), integer_to_binary(length(Expected))}];
differences(Actual, Expected) ->
    [{N, A, E} || {N, {A, E}} <- lists:enumerate(0, lists:zip(Actual, Expected)), A =/= E].

-spec crate_version(binary()) -> binary().
crate_version(Lock) ->
    case re:run(Lock, "name = \"regex\"\\nversion = \"([^\"]+)\"", [{capture, [1], binary}]) of
        {match, [Version]} -> Version;
        nomatch -> error(regex_crate_missing)
    end.

read(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Bytes.

trim(Text) -> string:trim(Text).
