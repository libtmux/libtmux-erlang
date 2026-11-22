% Retire one closed pull request's Erlang documentation preview.
-module(preview_cleanup).
-moduledoc """
Check current pull request state before deleting its Erlang preview.

The default-branch cleanup workflow runs `eligibility` before assuming its
cleanup role, then `delete` rechecks that the pull request is still closed.
Both stages require `PR`, `REPOSITORY` and the workflow's `GH_TOKEN`.
`eligibility` appends to `GITHUB_OUTPUT`; `delete` also requires `BUCKET`.
Commands use the compiled library helper, so run `rebar3 compile` first.
""".
-mode(compile).
-export([main/1, run/3]).

-spec main([string()]) -> no_return().
main([Stage]) when Stage =:= "eligibility"; Stage =:= "delete" ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    Settings = #{pr => os:getenv("PR"), repository => os:getenv("REPOSITORY"),
                 output => os:getenv("GITHUB_OUTPUT"), bucket => os:getenv("BUCKET")},
    try run(Stage, Settings, fun script_util:run/3) of
        ok -> halt(0)
    catch error:{preview_cleanup, Reason} ->
        io:format(standard_error, "preview cleanup failed: ~p~n", [Reason]),
        halt(1)
    end;
main(_) ->
    io:format(standard_error, "usage: preview_cleanup.erl eligibility|delete~n", []),
    halt(2).

-doc """
Run one cleanup stage using the supplied command runner. Performs I/O.
Invalid input, malformed current state and failed commands raise
`{preview_cleanup, Reason}`. An open pull request is a successful no-op.
""".
-spec run(string(), map(), fun((string(), [string()], map()) -> map())) -> ok.
run("eligibility", #{output := Output} = Settings, Runner) ->
    ok = file:write_file(Output, <<"should_cleanup=false\n">>, [append]),
    Closed = current_closed(Settings, Runner),
    file:write_file(Output, ["should_cleanup=", atom_to_list(Closed), "\n"], [append]);
run("delete", #{pr := Pr, bucket := Bucket} = Settings, Runner) ->
    case current_closed(Settings, Runner) of
        false -> ok;
        true ->
            valid_bucket(Bucket) orelse fail(invalid_bucket),
            Prefix = "s3://" ++ Bucket ++ "/en/erlang/pr-" ++ Pr ++ "/",
            case Runner("aws", ["s3", "rm", Prefix, "--recursive"], #{}) of
                #{status := 0} -> ok;
                _ -> fail(preview_delete_failed)
            end
    end.

current_closed(#{pr := Pr, repository := Repository}, Runner) ->
    valid_number(Pr) orelse fail(invalid_pr_number),
    Repository =:= "libtmux/libtmux-erlang" orelse fail(invalid_repository),
    Command = ["api", "--method", "GET", "repos/" ++ Repository ++ "/pulls/" ++ Pr],
    case Runner("gh", Command, #{}) of
        #{status := 0, stdout := Response} -> closed(Response, list_to_integer(Pr));
        _ -> fail(pull_request_query_failed)
    end.

valid_number(Pr) when is_list(Pr) ->
    re:run(Pr, "^[1-9][0-9]*\\z", [{capture, none}]) =:= match;
valid_number(_) -> false.

valid_bucket(Bucket) when is_list(Bucket) ->
    re:run(Bucket, "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\\z", [{capture, none}]) =:= match;
valid_bucket(_) -> false.

closed(Response, Pr) ->
    Decoded = try json:decode(Response)
              catch error:_ -> fail(invalid_pull_request_response)
              end,
    case Decoded of
        #{<<"number">> := Pr, <<"state">> := <<"closed">>} -> true;
        #{<<"number">> := Pr, <<"state">> := <<"open">>} -> false;
        _ -> fail(invalid_pull_request_response)
    end.

-spec fail(atom()) -> no_return().
fail(Reason) -> error({preview_cleanup, Reason}).
