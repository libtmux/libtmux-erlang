%% Validate a clean release checkout and the exact public Hex source artifact.
%% Usage: escript scripts/release/check_release.erl [--tag vVERSION | --from-actions]
%%        [--artifact TARBALL [--qualified-receipt RECEIPT]] [--require-published]
-module(check_release).
-mode(compile).
-export([main/1, validate_version/2, validate_checkout/2, published_artifact/3,
         validate_qualification/3, application_version/1, actions_tag/2]).
-export_type([fetch/0]).

-define(APP, "libtmux_erlang").
-define(LIMIT, 16777216).
-define(SEMVER, "\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)"
                "(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?\\z").

-doc "Fetch a URL: the HTTP status and body, or the transport error.".
-type fetch() :: fun((string()) -> {ok, non_neg_integer(), binary()} | {error, term()}).

-spec main([string()]) -> no_return().
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    case run(Root, parse(Arguments, #{})) of
        {ok, Result} ->
            io:format("~s~n", [json:format(Result)]),
            output(Result),
            halt(0);
        {error, Message} ->
            io:format(standard_error, "~s~n", [Message]),
            halt(1)
    end.

parse([], Options) -> Options;
parse(["--tag", Tag | Rest], Options) -> parse(Rest, Options#{tag => Tag});
parse(["--from-actions" | Rest], Options) ->
    case actions_tag(os:getenv("GITHUB_EVENT_NAME"), os:getenv("GITHUB_REF_NAME")) of
        none -> parse(Rest, Options);
        Tag -> parse(Rest, Options#{tag => Tag})
    end;
parse(["--artifact", Path | Rest], Options) -> parse(Rest, Options#{artifact => Path});
parse(["--qualified-receipt", Path | Rest], Options) ->
    parse(Rest, Options#{receipt => Path});
parse(["--require-published" | Rest], Options) ->
    parse(Rest, Options#{require_published => true});
parse(Other, _) ->
    io:format(standard_error, "unrecognized arguments: ~p~n", [Other]),
    halt(2).

-doc """
The tag a GitHub Actions run releases: the ref name on a push event, `none` on
any other event.
""".
-spec actions_tag(string() | false, string() | false) -> string() | none.
actions_tag("push", Ref) when is_list(Ref), Ref =/= "" -> Ref;
actions_tag("push", _) -> error(missing_ref_name);
actions_tag(_, _) -> none.

run(Root, Options) ->
    case usage(Options) of
        {error, Message} ->
            io:format(standard_error, "~s~n", [Message]),
            halt(2);
        ok -> release(Root, Options)
    end.

usage(#{receipt := _} = Options) when not is_map_key(artifact, Options) ->
    {error, "--qualified-receipt requires --artifact"};
usage(#{require_published := _} = Options) when not is_map_key(artifact, Options) ->
    {error, "--require-published requires --artifact"};
usage(_) -> ok.

release(Root, Options) ->
    try
        Tag = maps:get(tag, Options, none),
        Version = validate_version(application_version(Root), Tag),
        Head = validate_checkout(Root, Tag),
        Base = #{version => list_to_binary(Version), head => list_to_binary(Head)},
        {ok, case maps:find(artifact, Options) of
            error -> Base;
            {ok, Path} -> artifact(Path, Version, Head, Options, Base)
        end}
    catch
        error:{release, Message} -> {error, Message}
    end.

artifact(Path, Version, Head, Options, Base) ->
    {ok, Expected} = file:read_file(Path),
    Digest = script_util:sha256_hex(Expected),
    case maps:find(receipt, Options) of
        {ok, Receipt} ->
            {ok, Text} = file:read_file(Receipt),
            validate_qualification(json:decode(Text), Head, Digest);
        error -> ok
    end,
    Published = published_artifact(Version, Expected, fun fetch/1),
    case {maps:get(require_published, Options, false), Published} of
        {true, false} ->
            fail("release not public on Hex; check staged approval before retrying");
        _ -> ok
    end,
    Base#{sha256 => Digest, published => Published}.

-spec fail(term()) -> no_return().
fail(Message) -> error({release, Message}).

-doc "The literal application version from the app resource template.".
-spec application_version(file:filename_all()) -> string().
application_version(Root) ->
    Path = filename:join([Root, "apps", ?APP, "src", ?APP ++ ".app.src"]),
    {ok, Text} = file:read_file(Path),
    case re:run(Text, "\\{vsn,\\s*\"([^\"\\n]+)\"\\}", [{capture, [1], list}]) of
        {match, [Version]} -> Version;
        nomatch -> fail("missing literal application version")
    end.

-doc """
Accept a SemVer version without build metadata. When `Tag` is not `none` it
must be exactly `v` and the version.
""".
-spec validate_version(string(), string() | none) -> string().
validate_version(Version, Tag) ->
    Valid = case re:run(Version, ?SEMVER, [{capture, all, list}]) of
        {match, [_, _, _, _]} -> true;
        {match, [_, _, _, _, Prerelease]} -> not leading_zero(Prerelease);
        nomatch -> false
    end,
    Valid orelse fail("release version must be SemVer without build metadata"),
    (Tag =:= none orelse Tag =:= "v" ++ Version) orelse
        fail("tag must exactly match v" ++ Version),
    Version.

leading_zero(Prerelease) ->
    lists:any(fun([$0, _ | _] = Part) -> lists:all(fun is_digit/1, Part);
                 (_) -> false
              end, string:split(Prerelease, ".", all)).

is_digit(Char) -> Char >= $0 andalso Char =< $9.

-doc """
Require a clean tree, and with a tag that the tag points at HEAD. Returns
HEAD's commit ID.
""".
-spec validate_checkout(file:filename_all(), string() | none) -> string().
validate_checkout(Root, Tag) ->
    Status = script_util:git(["status", "--porcelain", "--untracked-files=all"], Root),
    Status =:= <<>> orelse fail("release requires a clean checkout"),
    Head = binary_to_list(script_util:git(["rev-parse", "HEAD"], Root)),
    case Tag of
        none -> ok;
        _ ->
            Tagged = script_util:run("git", ["rev-parse", "refs/tags/" ++ Tag ++ "^{commit}"],
                #{cwd => unicode:characters_to_binary(Root)}),
            case Tagged of
                #{status := 0, stdout := Out} ->
                    string:trim(binary_to_list(Out)) =:= Head orelse
                        fail("release tag must point to HEAD");
                _ -> fail("release tag must point to HEAD")
            end
    end,
    Head.

-doc """
Whether the public Hex tarball for `Version` exists. Only HTTP 404 means
absent; a different existing payload or any other failure raises.
""".
-spec published_artifact(string(), binary(), fetch()) -> boolean().
published_artifact(Version, Expected, Fetch) ->
    Url = "https://repo.hex.pm/tarballs/" ++ ?APP ++ "-" ++ Version ++ ".tar",
    case Fetch(Url) of
        {ok, 404, _} -> false;
        {ok, 200, Expected} -> true;
        {ok, 200, _} -> fail("public Hex artifact differs from the qualified source package");
        {ok, Status, _} -> fail(io_lib:format("registry answered HTTP ~B", [Status]));
        {error, Reason} -> fail(io_lib:format("registry request failed: ~p", [Reason]))
    end.

-doc "Bind a tarball to a passing receipt for the same clean commit and bytes.".
-spec validate_qualification(map(), string(), binary()) -> ok.
validate_qualification(Proof, Head, Sha256) ->
    Source = maps:get(<<"source">>, Proof, #{}),
    Packages = maps:get(<<"packages">>, Proof, #{}),
    Package = maps:get(unicode:characters_to_binary(?APP), Packages, #{}),
    Head1 = unicode:characters_to_binary(Head),
    case {maps:get(<<"result">>, Proof, none), maps:get(<<"head">>, Source, none),
          maps:get(<<"status">>, Source, none), maps:get(<<"sha256">>, Package, none)} of
        {<<"PASS">>, Head1, Empty, Sha256} when Empty =:= <<>>; Empty =:= null -> ok;
        _ -> fail("artifact does not match clean native CI qualification")
    end.

fetch(Url) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),
    Ssl = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
           {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case httpc:request(get, {Url, []}, [{timeout, 30000}, {ssl, Ssl}],
                       [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, Body}} when byte_size(Body) =< ?LIMIT -> {ok, Status, Body};
        {ok, {{_, _, _}, _, _}} -> {error, body_too_large};
        {error, Reason} -> {error, Reason}
    end.

output(Result) ->
    case os:getenv("GITHUB_OUTPUT") of
        false -> ok;
        Path ->
            Lines = [[atom_to_list(Key), $=, text(Value), $\n]
                     || {Key, Value} <- lists:sort(maps:to_list(Result))],
            ok = file:write_file(Path, Lines, [append])
    end.

text(true) -> "true";
text(false) -> "false";
text(Value) -> Value.
