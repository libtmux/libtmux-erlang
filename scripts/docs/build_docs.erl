% Build native EEP-48 API documentation with a pinned ExDoc escript.
-module(build_docs).
-mode(compile).
-moduledoc """
Builds the native API browser into `_build/docs/core` with the ExDoc escript
that `tools/docs-tool.json` pins.

```console
$ escript scripts/docs/build_docs.erl --prepare
```

`--prepare` downloads the pinned ExDoc over HTTPS, checks its SHA-256 digest
and size, and stores it below `_build/tools/ex_doc`. The download is the only
network access. Without arguments the script compiles the library, stages the
guides with their links rewritten to generated source pages, runs ExDoc with
warnings as errors, checks the rendered HTML with `check_docs:check/2` and
writes the receipt `_build/checks/docs.json`.

Run both from the repository root; the build needs `rebar3 compile` first so
that this script's helpers are on the code path.
""".
-export([main/1, prepare/1, build/1, tool_valid/2, verify_download/2, proxy/1, diff_sha256/1]).
-include_lib("kernel/include/file.hrl").

-define(TOOL_LIMIT, 8388608).
-define(DOWNLOAD_TIMEOUT_MS, 120000).
-define(COMPILE_TIMEOUT_MS, 30000).
-define(EXDOC_TIMEOUT_MS, 60000).
-define(SOURCE_PATTERN, "https://source.invalid/%{path}#L%{line}").

-doc "Entry point: `--prepare` downloads the tool, no argument builds.".
-spec main([string()]) -> no_return().
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    try run(Arguments, Root) of
        ok -> halt(0);
        usage ->
            io:format(standard_error, "usage: build_docs.erl [--prepare]~n", []),
            halt(2)
    catch
        error:{build_docs, Message} ->
            io:format(standard_error, "build_docs: ~ts~n", [Message]),
            halt(1);
        error:{docs_check, Where, Reason} ->
            io:format(standard_error, "check_docs: ~ts: ~tw~n", [Where, Reason]),
            halt(1);
        Class:Reason:Stack ->
            io:format(standard_error, "build_docs: ~p:~p~n~p~n", [Class, Reason, Stack]),
            halt(1)
    end.

run(["--prepare"], Root) -> prepare(Root);
run([], Root) ->
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    case [Module || Module <- [docs_util, script_util, check_docs, check_rendered_docs, docs_sources],
                    code:ensure_loaded(Module) =/= {module, Module}] of
        [] -> ok;
        Missing -> fail(iolist_to_binary(io_lib:format(
                       "~p not found; run rebar3 compile first", [Missing])))
    end,
    ok = script_util:boot(Root),
    build(Root);
run(_, _) -> usage.

-spec fail(binary()) -> no_return().
fail(Message) -> error({build_docs, Message}).

% `--prepare` runs before the library compiles, so it uses nothing from the
% scripts' helper modules.
manifest(Root) ->
    {ok, Binary} = file:read_file(filename:join(Root, "tools/docs-tool.json")),
    json:decode(Binary).

field(Name, Manifest) -> maps:get(Name, Manifest).

executable(Root, Manifest) ->
    filename:join([Root, "_build/tools/ex_doc", field(<<"version">>, Manifest), "ex_doc"]).

-doc """
Whether `Executable` is the pinned tool: a regular file (not a symbolic link)
of at most 8 MiB whose SHA-256 digest matches the manifest.
""".
-spec tool_valid(file:filename_all(), map()) -> boolean().
tool_valid(Executable, Manifest) ->
    case file:read_link_info(Executable) of
        {ok, #file_info{type = regular, size = Size}} when Size =< ?TOOL_LIMIT ->
            case file:read_file(Executable) of
                {ok, Bytes} when byte_size(Bytes) =< ?TOOL_LIMIT ->
                    sha256_hex(Bytes) =:= field(<<"sha256">>, Manifest);
                _ -> false
            end;
        _ -> false
    end.

-doc "Download and install the pinned ExDoc unless the installed copy is valid.".
-spec prepare(file:filename_all()) -> ok.
prepare(Root) ->
    Manifest = manifest(Root),
    Executable = executable(Root, Manifest),
    case tool_valid(Executable, Manifest) of
        true -> ok;
        false ->
            Bytes = fetch(field(<<"url">>, Manifest), ?TOOL_LIMIT + 1),
            ok = verify_download(Bytes, Manifest),
            ok = filelib:ensure_dir(Executable),
            Temporary = <<Executable/binary, ".download">>,
            {ok, Device} = file:open(Temporary, [write, binary, exclusive]),
            ok = file:write(Device, Bytes),
            ok = file:close(Device),
            ok = file:rename(Temporary, Executable)
    end,
    io:format("PASS: verified ExDoc ~ts for OTP ~ts~n",
              [field(<<"version">>, Manifest), field(<<"otp">>, Manifest)]).

-doc "Accept a download of at most 8 MiB whose SHA-256 digest matches the manifest.".
-spec verify_download(binary(), map()) -> ok.
verify_download(Bytes, Manifest) ->
    case byte_size(Bytes) =< ?TOOL_LIMIT andalso
             sha256_hex(Bytes) =:= field(<<"sha256">>, Manifest) of
        true -> ok;
        false -> fail(<<"ExDoc download does not match the pinned digest">>)
    end.

sha256_hex(Data) -> binary:encode_hex(crypto:hash(sha256, Data), lowercase).

% The body is read in chunks and abandoned once it passes the limit.
fetch(Url, Limit) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    ok = httpc:set_options(proxy(os:getenv("https_proxy", os:getenv("HTTPS_PROXY", "")))),
    Verify = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
              {customize_hostname_check,
               [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    {ok, Request} = httpc:request(get, {binary_to_list(Url), [{"user-agent", "libtmux-docs"}]},
        [{ssl, Verify}, {connect_timeout, 30000}, {timeout, ?DOWNLOAD_TIMEOUT_MS}],
        [{sync, false}, {stream, self}, {body_format, binary}]),
    collect(Request, <<>>, Limit).

collect(Request, Body, Limit) ->
    receive
        {http, {Request, stream_start, _}} -> collect(Request, Body, Limit);
        {http, {Request, stream, Part}} ->
            Next = <<Body/binary, Part/binary>>,
            case byte_size(Next) >= Limit of
                true ->
                    ok = httpc:cancel_request(Request),
                    fail(<<"ExDoc download exceeds the size limit">>);
                false -> collect(Request, Next, Limit)
            end;
        {http, {Request, stream_end, _}} -> Body;
        {http, {Request, {{_, Status, _}, _, _}}} ->
            fail(iolist_to_binary(io_lib:format("ExDoc download failed with HTTP ~B", [Status])));
        {http, {Request, {error, Reason}}} ->
            fail(iolist_to_binary(io_lib:format("ExDoc download failed: ~p", [Reason])))
    after ?DOWNLOAD_TIMEOUT_MS ->
        ok = httpc:cancel_request(Request),
        fail(<<"ExDoc download timed out">>)
    end.

-doc """
`httpc` options for the proxy named by an `https_proxy` value: none when it is
empty, otherwise the proxy host and port.
""".
-spec proxy(string()) -> [{https_proxy, {{string(), inet:port_number()}, []}}].
proxy("") -> [];
proxy(Value) ->
    Url = case string:find(Value, "://") of
        nomatch -> "http://" ++ Value;
        _ -> Value
    end,
    #{host := Host} = Parsed = uri_string:parse(Url),
    [{https_proxy, {{unicode:characters_to_list(Host), maps:get(port, Parsed, 80)}, []}}].

inputs(Root) ->
    Names = binary:split(script_util:run_ok("git",
        ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], #{cwd => Root}),
        <<0>>, [global]),
    maps:from_list([{Name, docs_util:sha256_file(filename:join(Root, Name))}
                    || Name <- lists:usort(Names), Name =/= <<>>,
                       is_regular_file(filename:join(Root, Name))]).

is_regular_file(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular}} -> true;
        _ -> false
    end.

environment() ->
    case os:getenv("ERL_FLAGS") of
        false -> #{<<"ERL_FLAGS">> => <<"+S 4:4">>};
        _ -> #{}
    end.

run_tool(Root, Executable, Arguments, Environment, Timeout) ->
    case script_util:run(Executable, Arguments,
                         #{cwd => Root, env => Environment, timeout_ms => Timeout}) of
        #{status := 0} -> ok;
        #{stdout := Stdout, stderr := Stderr, status := Status} ->
            io:format(standard_error, "~ts~ts", [Stdout, Stderr]),
            fail(iolist_to_binary(io_lib:format("~ts failed (~p)", [Executable, Status])))
    end.

-doc """
SHA-256 of `git diff --binary HEAD`. Git writes the diff to a file under
`_build` that is hashed in chunks, so the size is not limited by the output
cap of `script_util:run/3` and the digest equals the hash of the diff text.
""".
-spec diff_sha256(file:filename_all()) -> binary().
diff_sha256(Root) ->
    Diff = unicode:characters_to_binary(filename:join(Root, "_build/docs/working-tree.diff")),
    ok = filelib:ensure_dir(Diff),
    try
        _ = script_util:run_ok("git", ["diff", "--binary", "HEAD", <<"--output=", Diff/binary>>],
                               #{cwd => Root}),
        docs_util:sha256_file(Diff)
    after _ = file:delete(Diff)
    end.

sorted_object(Map, Value) ->
    {object, [{Key, Value(Item)} || {Key, Item} <- lists:sort(maps:to_list(Map))]}.

info(Info, _) when map_size(Info) =:= 0 -> {object, []};
info(Info, Keys) -> {object, [{Key, maps:get(Key, Info)} || Key <- Keys]}.

-doc """
Build the browser below `Root` and write `_build/checks/docs.json`. Needs the
library and this script's helpers compiled, the pinned ExDoc prepared and the
Git checkout unchanged while it runs.
""".
-spec build(file:filename_all()) -> ok.
build(Root0) ->
    Root = unicode:characters_to_binary(Root0),
    Manifest = manifest(Root),
    Executable = executable(Root, Manifest),
    tool_valid(Executable, Manifest) orelse fail(
        <<"Prepare documentation tools first: escript scripts/docs/build_docs.erl --prepare">>),
    Started = erlang:monotonic_time(microsecond),
    InputFiles = inputs(Root),
    Environment = environment(),
    ok = run_tool(Root, "rebar3", ["compile"], Environment, ?COMPILE_TIMEOUT_MS),
    Ebin = filename:join(Root, "_build/default/lib/libtmux_erlang/ebin"),
    is_regular_file(filename:join(Ebin, "libtmux_erlang.app"))
        orelse fail(<<"Compile first: rebar3 compile">>),
    Status = script_util:run_ok("git", ["status", "--porcelain", "--untracked-files=all"],
                                #{cwd => Root}),
    Diff = diff_sha256(Root),
    Output = filename:join(Root, "_build/docs/core"),
    ok = clean_directory(Output),
    Groups = guide_groups(Root),
    Extras = lists:append([Pages || {_, Pages} <- Groups]),
    Context = docs_sources:context(Root, Extras),
    #{head := Head} = Context,
    {Staged, Staging} = stage_guides(Context, Extras),
    ok = write_config(Root, Staged, Groups),
    Dirty = Status =/= <<>>,
    ok = run_exdoc(Root, Executable, Environment, Head, Dirty),
    Media = maps:get(media, Staging),
    ok = docs_sources:copy_media(Root, Output, Media),
    Final = docs_sources:rewrite_source_links(Context, Staging),
    _ = check_docs:check(Root, #{html_directory => Output}),
    (inputs(Root) =:= InputFiles andalso script_util:git(["rev-parse", "HEAD"], Root) =:= Head)
        orelse fail(<<"Documentation inputs changed during the build; "
                      "rebuild the stable checkout">>),
    Receipt = [{<<"result">>, <<"PASS">>}, {<<"head">>, Head},
               {<<"ex_doc">>, docs_util:read_ordered_json(
                                  filename:join(Root, "tools/docs-tool.json"))},
               {<<"working_tree">>, case Dirty of
                   true -> <<"dirty preview">>;
                   false -> <<"clean commit">>
               end},
               {<<"status">>, docs_util:splitlines(Status)},
               {<<"diff_sha256">>, Diff},
               {<<"source_files">>, sorted_object(maps:get(sources, Final),
                    fun(Info) -> info(Info, [<<"sha256">>, <<"matches_head">>]) end)},
               {<<"media">>, sorted_object(Media,
                    fun(Info) -> info(Info, [<<"source">>, <<"sha256">>]) end)},
               {<<"input_files">>, sorted_object(InputFiles, fun(Digest) -> Digest end)},
               {<<"beams">>, sorted_object(beam_digests(Ebin), fun(Digest) -> Digest end)},
               {<<"seconds">>, (erlang:monotonic_time(microsecond) - Started) / 1.0e6},
               {<<"output">>, <<"_build/docs/core">>},
               {<<"source">>, <<"compiler EEP-48 chunks; no legacy EDoc source extraction">>}],
    docs_util:write_file(filename:join(Root, "_build/checks/docs.json"),
                         [docs_util:json_text({object, Receipt}), $\n]),
    Keys = [<<"result">>, <<"head">>, <<"working_tree">>, <<"seconds">>, <<"output">>],
    Summary = [lists:keyfind(Key, 1, Receipt) || Key <- Keys],
    io:format("~ts~n", [docs_util:json_text({object, Summary})]).

clean_directory(Directory) ->
    case filelib:is_file(Directory) of
        true -> ok = file:del_dir_r(Directory);
        false -> ok
    end,
    filelib:ensure_path(Directory).

guide_groups(Root) ->
    Start = [<<"README.md">>, <<"docs/first-task.md">>, <<"docs/installation.md">>,
             <<"docs/guides.md">>],
    Reference = [<<"docs/api.md">>, <<"docs/fields.md">>, <<"docs/options-reference.md">>,
                 <<"docs/commands-reference.md">>, <<"docs/compatibility.md">>],
    Project = [<<"docs/project-policy.md">> | docs_util:wildcard(Root, "docs/adr-*.md")]
        ++ [<<"docs/branding.md">>, <<"LICENSE">>],
    Tasks = docs_util:wildcard(Root, "docs/*.md") -- (Start ++ Reference ++ Project),
    [{'Start here', Start}, {'Tasks', Tasks}, {'Reference', Reference}, {'Project', Project}].

stage_guides(#{root := Root} = Context, Extras) ->
    lists:mapfoldl(fun(Page, State) ->
        {Text, Next} = docs_sources:stage_page(Context, Page, State),
        Destination = staged_page(Page),
        docs_util:write_file(filename:join(Root, Destination), Text),
        {Destination, Next}
    end, docs_sources:new_state(), Extras).

staged_page(Page) -> filename:join("_build/docs/pages", Page).

write_config(Root, Staged, Groups) ->
    StagedGroups = [{Group, [staged_page(Page) || Page <- Pages]} || {Group, Pages} <- Groups],
    Config = [{proglang, erlang}, {main, <<"readme">>},
              {source_url_pattern, list_to_binary(?SOURCE_PATTERN)},
              {extras, Staged}, {groups_for_extras, StagedGroups}],
    docs_util:write_file(filename:join(Root, "_build/docs/ex_doc.config"),
                         [io_lib:format("~tp.~n", [Term]) || Term <- Config]).

run_exdoc(Root, Executable, Environment, Head, Dirty) ->
    Source = filename:join(Root, "apps/libtmux_erlang/src/libtmux_erlang.app.src"),
    {ok, Application} = file:read_file(Source),
    {match, [Version]} = re:run(Application, "\\{vsn,\\s*\"([^\"\\n]+)\"\\}",
                                [{capture, [1], binary}]),
    Suffix = case Dirty of
        true -> <<"+working-tree">>;
        false -> <<>>
    end,
    run_tool(Root, "escript",
        [Executable, "libtmux for Erlang", <<Version/binary, Suffix/binary>>,
         "_build/default/lib/libtmux_erlang/ebin", "--config", "_build/docs/ex_doc.config",
         "--formatter", "html", "--output", "_build/docs/core", "--source-ref", Head,
         "--warnings-as-errors"], Environment, ?EXDOC_TIMEOUT_MS).

beam_digests(Ebin) ->
    maps:from_list([{Beam, docs_util:sha256_file(filename:join(Ebin, Beam))}
                    || Beam <- docs_util:wildcard(Ebin, "*.beam")]).
