% Build and consume exact Hex source artifacts through a private local registry.
-module(check_source_package).
-moduledoc """
Build the Hex source artifact for `libtmux_erlang`, serve it from a private signed
registry on a loopback socket and install it into a clean consumer.

```console
$ escript scripts/package/check_source_package.erl --prepare
$ escript scripts/package/check_source_package.erl
```

`--prepare` downloads the pinned `rebar3_hex`, `hex_core` and `verl` archives named in
`tools/package-tool.json`, verifies their digests and compiles `hex_core` under
`_build/source-package-tools`. The run builds the artifact in a staged copy of the
application, installs it from the local registry into a consumer with no checkout,
plugin or cache, proves that a missing C compiler fails before the helper is
installed and runs the installed consumers from `check_package:exercise_consumer/4`.
It writes `_build/source-package-check/receipt.json` and a log for every command,
and exits 0 only when the receipt says `PASS`.
""".
-mode(compile).
-include_lib("kernel/include/file.hrl").
-export([main/1, run/1, prepare/1, ensure_pins/3, unpack_core/2, compile_core/1, runtime/0,
         prepared_manifest/3, verify_prepared/4, check_contents/2, source_identity/1,
         repo_config/2, start_registry/2, registry_url/1, registry_requests/1,
         stop_registry/1, copy_package_source/2]).
-export_type([registry/0]).

-define(APP, "libtmux_erlang").
-define(REQUEST_LIMIT, 256).
-define(DOWNLOAD_LIMIT, 8 * 1024 * 1024).
-define(RECV_TIMEOUT_MS, 10000).
-define(LOG_TAIL, 8000).
-define(PREPARE_COMMAND, "escript scripts/package/check_source_package.erl --prepare").

-doc "A running registry server: its port and the process that owns its state.".
-opaque registry() :: #{port := inet:port_number(), owner := pid()}.

-spec main([string()]) -> no_return().
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    case Arguments of
        ["--prepare"] -> check_package:run_script(fun() -> prepare(Root), 0 end);
        [] -> check_package:run_script(fun() -> run(Root) end);
        [Help] when Help =:= "-h"; Help =:= "--help" ->
            io:format("usage: check_source_package.erl [--prepare]~n"),
            halt(0);
        _ ->
            io:format(standard_error, "usage: check_source_package.erl [--prepare]~n", []),
            halt(2)
    end.

%% Provisioning

-doc """
Provision the test-only Hex tooling, separately from the measured run: download and
verify the pinned archives, unpack and compile `hex_core` and record what was built
in `prepared.json`.
""".
-spec prepare(file:filename()) -> ok.
prepare(Root) ->
    Tools = tools_dir(Root),
    Pins = read_pins(Root),
    ok = filelib:ensure_path(Tools),
    ok = ensure_pins(Tools, Pins, fun fetch/1),
    Core = filename:join(Tools, "hex_core"),
    ok = unpack_core(pinned_tarball(Tools, pin(<<"hex_core">>, Pins)), Core),
    ok = compile_core(Core),
    Manifest = prepared_manifest(Root, Tools, runtime()),
    ok = file:write_file(filename:join(Tools, "prepared.json"),
                         check_package:encode_json(Manifest)),
    io:format("Prepared pinned Hex tooling; no project package was published.~n").

-doc """
Make sure each pinned archive exists in `Tools` with its pinned SHA-256. A missing or
changed archive comes from `Fetch(Url)` and is kept only when its digest matches.
""".
-spec ensure_pins(file:filename(), [map()], fun((string()) -> {ok, binary()} | {error, term()})) ->
    ok.
ensure_pins(Tools, Pins, Fetch) ->
    lists:foreach(fun(Pin) ->
        Path = pinned_tarball(Tools, Pin),
        Name = filename:basename(Path),
        case is_pinned(Path, Pin) of
            true -> ok;
            false ->
                Data = case Fetch("https://repo.hex.pm/tarballs/" ++ Name) of
                    {ok, Body} when byte_size(Body) =< ?DOWNLOAD_LIMIT -> Body;
                    {ok, _} -> check_package:fail("tool archive too large: ~ts", [Name]);
                    {error, Reason} ->
                        check_package:fail("cannot download ~ts: ~p", [Name, Reason])
                end,
                case sha256(Data) =:= maps:get(<<"sha256">>, Pin) of
                    true -> ok = file:write_file(Path, Data);
                    false -> check_package:fail("tool checksum mismatch: ~ts", [Name])
                end
        end
    end, Pins).

fetch(Url) ->
    {ok, _} = application:ensure_all_started([inets, ssl]),
    Ssl = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
           {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case httpc:request(get, {Url, []}, [{timeout, 30000}, {ssl, Ssl}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Status, _}, _, _}} -> {error, {http_status, Status}};
        {error, Reason} -> {error, Reason}
    end.

-doc "Replace `Core` with the contents of a Hex package archive.".
-spec unpack_core(file:filename(), file:filename()) -> ok.
unpack_core(Tarball, Core) ->
    Packed = case erl_tar:extract(Tarball, [memory, {files, ["contents.tar.gz"]}]) of
        {ok, [{_, Data}]} -> Data;
        _ -> check_package:fail("~ts has no contents.tar.gz", [Tarball])
    end,
    ok = remove_tree(Core),
    ok = filelib:ensure_path(Core),
    case erl_tar:extract({binary, Packed}, [compressed, {cwd, Core}]) of
        ok -> ok;
        {error, Reason} -> check_package:fail("cannot unpack ~ts: ~p", [Tarball, Reason])
    end.

-doc """
Generate the `hex_core` scanner and compile every source into `Core/ebin`, treating
warnings as errors.
""".
-spec compile_core(file:filename()) -> ok.
compile_core(Core) ->
    Source = filename:join(Core, "src"),
    Ebin = filename:join(Core, "ebin"),
    ok = filelib:ensure_path(Ebin),
    _ = script_util:run_ok("erlc", ["-o", Source, filename:join(Source, "safe_erl_term.xrl")],
                           #{timeout_ms => 120000}),
    true = code:add_patha(Ebin),
    lists:foreach(fun(File) ->
        Options = [{outdir, Ebin}, {i, Source}, warnings_as_errors, report_errors,
                   report_warnings],
        case compile:file(File, Options) of
            {ok, _} -> ok;
            _ -> check_package:fail("cannot compile ~ts", [File])
        end
    end, lists:sort(filelib:wildcard(filename:join(Source, "*.erl")))).

-doc "The OTP release, ERTS version and architecture of the running VM.".
-spec runtime() -> #{binary() => binary()}.
runtime() ->
    Release = erlang:system_info(otp_release),
    {ok, Version} = file:read_file(
        filename:join([code:root_dir(), "releases", Release, "OTP_VERSION"])),
    #{<<"otp">> => string:trim(Version),
      <<"erts">> => check_package:bin(erlang:system_info(version)),
      <<"architecture">> => check_package:bin(erlang:system_info(system_architecture))}.

-doc """
What `prepared.json` records: the pin file digest, the runtime and the digest of every
file under `hex_core`.
""".
-spec prepared_manifest(file:filename(), file:filename(), map()) -> map().
prepared_manifest(Root, Tools, Runtime) ->
    #{<<"pins_sha256">> => script_util:sha256_hex({file, pins_file(Root)}),
      <<"runtime">> => Runtime,
      <<"files">> => prepared_files(Tools)}.

prepared_files(Tools) ->
    Files = filelib:fold_files(filename:join(Tools, "hex_core"), ".*", true,
                               fun(File, Acc) -> [File | Acc] end, []),
    maps:from_list([{check_package:bin(lists:nthtail(length(Tools) + 1, File)),
                     script_util:sha256_hex({file, File})} || File <- Files]).

-doc """
Fail unless the pinned archives are present and the prepared tools still match the
pins, the runtime and the compiled files recorded by `--prepare`.
""".
-spec verify_prepared(file:filename(), file:filename(), [map()], map()) -> ok.
verify_prepared(Root, Tools, Pins, Runtime) ->
    lists:foreach(fun(Pin) ->
        case is_pinned(pinned_tarball(Tools, Pin), Pin) of
            true -> ok;
            false -> check_package:fail("Run " ?PREPARE_COMMAND " first", [])
        end
    end, Pins),
    Recorded = case file:read_file(filename:join(Tools, "prepared.json")) of
        {ok, Text} ->
            try json:decode(Text)
            catch error:_ -> undefined
            end;
        {error, _} -> undefined
    end,
    Current = Recorded =:= prepared_manifest(Root, Tools, Runtime),
    case Current andalso filelib:is_regular(filename:join([Tools, "hex_core", "ebin",
                                                           "hex_registry.beam"])) of
        true -> ok;
        false ->
            check_package:fail("Prepared tool source/BEAM/runtime mismatch; repeat --prepare", [])
    end.

%% Package contents

-doc """
Check a Hex source artifact: no prebuilt files, every required source file present.
Returns its SHA-256 and file names.
""".
-spec check_contents(file:filename(), string()) -> #{sha256 := binary(), files := [binary()]}.
check_contents(Path, App) ->
    Packed = case erl_tar:extract(Path, [memory, {files, ["contents.tar.gz"]}]) of
        {ok, [{_, Data}]} -> Data;
        _ -> check_package:fail("~ts has no contents.tar.gz", [Path])
    end,
    Names = case erl_tar:table({binary, zlib:gunzip(Packed)}) of
        {ok, Listed} -> [check_package:bin(Name) || Name <- Listed];
        {error, Reason} -> check_package:fail("cannot read ~ts: ~p", [Path, Reason])
    end,
    case [Name || Name <- Names, prebuilt(Name)] of
        [] -> ok;
        Forbidden -> check_package:fail("prebuilt files in ~ts: ~ts",
                                        [App, lists:join(", ", Forbidden)])
    end,
    Required = [<<"LICENSE">>, <<"CHANGELOG.md">>, <<"README.md">>, <<"rebar.config">>, <<"capabilities.json">>,
                <<"assets/logo.svg">>, <<"assets/logo-128.png">>, <<"assets/logo-512.png">>,
                check_package:bin("src/" ++ App ++ ".app.src"), <<"c_src/owned_io.c">>,
                <<"c_src/Makefile">>, <<"c_src/LICENSE">>, <<"c_src/provenance.json">>],
    case [Name || Name <- lists:sort(Required), not lists:member(Name, Names)] of
        [] -> ok;
        Missing -> check_package:fail("missing source-package files in ~ts: ~ts",
                                      [App, lists:join(", ", Missing)])
    end,
    #{sha256 => script_util:sha256_hex({file, Path}), files => Names}.

prebuilt(Name) ->
    lists:any(fun(Prefix) -> string:prefix(Name, Prefix) =/= nomatch end,
              [<<"priv/">>, <<"ebin/">>, <<"_build/">>])
        orelse lists:any(fun(Suffix) -> ends_with(Name, Suffix) end,
                         [<<".beam">>, <<".o">>, <<".so">>]).

ends_with(Name, Suffix) ->
    Skip = byte_size(Name) - byte_size(Suffix),
    Skip >= 0 andalso binary:part(Name, Skip, byte_size(Suffix)) =:= Suffix.

-doc "Copy the application sources the Hex artifact is built from, without build output.".
-spec copy_package_source(file:filename(), file:filename()) -> ok.
copy_package_source(Source, Destination) ->
    ok = filelib:ensure_path(Destination),
    {ok, Names} = file:list_dir(Source),
    lists:foreach(fun(Name) ->
        From = filename:join(Source, Name),
        To = filename:join(Destination, Name),
        case lists:member(Name, ["_build", "priv", "test", "ebin"]) of
            true -> ok;
            false ->
                case filelib:is_dir(From) of
                    true -> copy_package_source(From, To);
                    false -> copy_with_mode(From, To)
                end
        end
    end, Names).

copy_with_mode(From, To) ->
    {ok, _} = file:copy(From, To),
    {ok, #file_info{mode = Mode}} = file:read_file_info(From),
    ok = file:write_file_info(To, #file_info{mode = Mode}).

-doc """
Git state of the checkout: HEAD, the index tree and the porcelain status. A value is
`null` when its git command fails.
""".
-spec source_identity(file:filename()) -> map().
source_identity(Root) ->
    Git = fun(Arguments) ->
        case script_util:run("git", Arguments, #{cwd => check_package:bin(Root)}) of
            #{status := 0, stdout := Out} ->
                string:trim(check_package:printable(Out));
            _ -> null
        end
    end,
    #{head => Git(["rev-parse", "--verify", "HEAD"]),
      index_tree => Git(["write-tree"]),
      status => Git(["status", "--porcelain"]),
      artifact_identity => <<"Package SHA256 values bind the actual compiled source inputs">>}.

-doc "Rebar3 configuration that sends the `hexpm` repository to the registry at `Url`.".
-spec repo_config(unicode:chardata(), binary()) -> binary().
repo_config(Url, PublicKey) ->
    Quoted = fun(Text) -> io_lib:write_string(unicode:characters_to_list(Text)) end,
    iolist_to_binary(["{rebar_packages_cdn, ", Quoted(Url), "}.\n",
                      "{hex, [{repos, replace, [#{name => <<\"hexpm\">>, repo_url => <<",
                      Quoted(Url), ">>, repo_public_key => <<", Quoted(PublicKey),
                      ">>}]}]}.\n"]).

%% Run

-doc """
Run the source-package check and return the exit status: 0 when the receipt says `PASS`.
""".
-spec run(file:filename()) -> 0 | 1.
run(Root) ->
    Started = erlang:monotonic_time(microsecond),
    Output = filename:join([Root, "_build", "source-package-check"]),
    Attempt = filename:join(Output, "run-" ++ integer_to_list(erlang:system_time(nanosecond))),
    ok = filelib:ensure_path(Attempt),
    ok = check_package:delete_file(filename:join(Output, "receipt.json")),
    Receipt = ets:new(source_package_receipt, [set, private]),
    Pins = read_pins(Root),
    initial_receipt(Root, Pins, Receipt),
    Context = #{root => Root, attempt => Attempt, receipt => Receipt, pins => Pins},
    try
        ok = check(Context),
        set(Receipt, result, <<"PASS">>)
    catch
        error:{check_timeout, Message} ->
            set(Receipt, error, Message),
            set(Receipt, owned_cleanup, <<"UNVERIFIED after forced check-runner timeout">>);
        error:{check_failed, Message} ->
            set(Receipt, error, Message);
        Class:Reason:Stack ->
            set(Receipt, error, check_package:printable(check_package:bin(
                io_lib:format("~p:~p~n~p", [Class, Reason, Stack]))))
    end,
    set(Receipt, seconds, (erlang:monotonic_time(microsecond) - Started) / 1.0e6),
    Final = maps:from_list(ets:tab2list(Receipt)),
    ok = file:write_file(filename:join(Attempt, "receipt.json"), check_package:encode_json(Final)),
    Text = check_package:write_json(filename:join(Output, "receipt.json"), Final),
    io:put_chars(Text),
    case maps:get(result, Final) of
        <<"PASS">> -> 0;
        _ -> 1
    end.

initial_receipt(Root, Pins, Receipt) ->
    Machine = uname("-m"),
    lists:foreach(fun({Key, Value}) -> set(Receipt, Key, Value) end,
        [{result, <<"FAIL">>}, {platform, check_package:bin([uname("-s"), "-", uname("-r"),
                                                            "-", Machine])},
         {machine, Machine}, {tools, Pins}, {commands, []},
         {source_sha256, maps:from_list([{check_package:bin(Name),
                                          script_util:sha256_hex({file, filename:join(Root, Name)})}
             || Name <- ["scripts/package/check_source_package.erl",
                         "tools/source_package_registry.escript",
                         "scripts/package/check_package.erl", "scripts/lib/script_util.erl",
                         "tools/package-tool.json", ".tool-versions"]])},
         {packages, #{}}, {publication, <<"UNVERIFIED; local artifacts only">>}]).

uname(Flag) ->
    string:trim(script_util:run_ok("uname", [Flag], #{})).

check(#{root := Root, receipt := Receipt, pins := Pins} = Context) ->
    Tools = tools_dir(Root),
    Runtime = runtime(),
    ok = verify_prepared(Root, Tools, Pins, Runtime),
    set(Receipt, prepared_tool_sha256,
        script_util:sha256_hex({file, filename:join(Tools, "prepared.json")})),
    set(Receipt, runtime, Runtime),
    set(Receipt, source, source_identity(Root)),
    Temp = script_util:with_tmp_dir("erlang-source-consumer", fun(Temp) ->
        ok = consume(Context#{temp => Temp, tools => Tools}),
        Temp
    end),
    set(Receipt, temporary_consumer_removed, not filelib:is_file(Temp)).

consume(#{temp := Temp, tools := Tools, pins := Pins, receipt := Receipt} = Context) ->
    Public = filename:join([Temp, "registry", "public"]),
    Tarballs = filename:join(Public, "tarballs"),
    ok = filelib:ensure_path(Tarballs),
    lists:foreach(fun(Pin) ->
        Tarball = pinned_tarball(Tools, Pin),
        {ok, _} = file:copy(Tarball, filename:join(Tarballs, filename:basename(Tarball)))
    end, Pins),
    Base = check_package:base_env(),
    _ = registry_metadata(Context, Base),
    Registry = start_registry(Public, #{}),
    try serve(Context#{public => Public, tarballs => Tarballs, registry => Registry}, Base)
    after
        {Requests, Retired} = stop_registry(Registry),
        set(Receipt, requests, Requests),
        set(Receipt, registry_retired, Retired),
        Retired orelse check_package:fail("registry did not retire", [])
    end.

serve(#{temp := Temp, root := Root, attempt := Attempt, receipt := Receipt, public := Public,
        tarballs := Tarballs, registry := Registry, pins := Pins} = Context, Base) ->
    Url = registry_url(Registry),
    % Rebar3 3.28 overrides the hexpm URL after reading repo config.
    Env = Base#{<<"HEX_CDN">> => check_package:bin(Url)},
    {ok, PublicKey} = file:read_file(filename:join(Public, "public_key")),
    RepoConfig = repo_config(Url, PublicKey),
    PluginVersion = binary_to_list(maps:get(<<"version">>, pin(<<"rebar3_hex">>, Pins))),
    BuildConfig = filename:join(Temp, "build-config"),
    ok = write_rebar_config(BuildConfig, ["{plugins, [{rebar3_hex, ",
                                          io_lib:write_string(PluginVersion), "}]}.\n",
                                          RepoConfig]),
    BuildEnv = maps:merge(Env, check_package:rebar_dirs(BuildConfig,
                                                        filename:join(Temp, "build-cache"))),
    Stage = filename:join([Temp, "build", ?APP]),
    ok = copy_package_source(filename:join([Root, "apps", ?APP]), Stage),
    _ = run_logged(Context, ["rebar3", "hex", "build", "package"], Stage, BuildEnv, false),
    Artifact = case filelib:wildcard(filename:join([Stage, "_build", "default", "lib", ?APP,
                                                    "hex", "*.tar"])) of
        [Built] ->
            Copy = filename:join(Attempt, filename:basename(Built)),
            {ok, _} = file:copy(Built, Copy),
            Copy;
        _ -> check_package:fail("expected one actual Hex artifact for ~ts", [?APP])
    end,
    Package = check_contents(Artifact, ?APP),
    set(Receipt, packages, #{list_to_atom(?APP) => Package}),
    {ok, _} = file:copy(Artifact, filename:join(Tarballs, filename:basename(Artifact))),
    Metadata = case [M || #{<<"name">> := Name} = M <- registry_metadata(Context, BuildEnv),
                          Name =:= list_to_binary(?APP)] of
        [Found | _] -> Found;
        [] -> check_package:fail("registry has no metadata for ~ts", [?APP])
    end,
    set(Receipt, packages, #{list_to_atom(?APP) => Package#{metadata => Metadata}}),
    case maps:get(<<"requirements">>, Metadata, []) of
        Empty when Empty =:= []; Empty =:= #{} -> ok;
        _ -> check_package:fail("core must have no Hex runtime dependencies", [])
    end,
    install(Context#{artifact => Artifact, metadata => Metadata, repo_config => RepoConfig}, Env).

% This consumer has no source checkout, plugin or build cache.
install(#{temp := Temp, root := Root, attempt := Attempt, receipt := Receipt,
          registry := Registry, artifact := Artifact, metadata := Metadata,
          repo_config := RepoConfig} = Context, Env) ->
    Consumer = filename:join(Temp, "consumer"),
    ok = file:make_dir(Consumer),
    ConsumerConfig = filename:join(Temp, "consumer-config"),
    ok = write_rebar_config(ConsumerConfig, RepoConfig),
    Version = binary_to_list(maps:get(<<"version">>, Metadata)),
    ok = file:write_file(filename:join(Consumer, "rebar.config"),
                         ["{deps, [{libtmux_erlang, ", io_lib:write_string(Version), "}]}.\n"]),
    ConsumerEnv = maps:merge(Env, check_package:rebar_dirs(ConsumerConfig,
                                                           filename:join(Temp, "consumer-cache"))),
    First = length(registry_requests(Registry)),
    MissingCompiler = filename:join(Temp, "missing-c-compiler"),
    Failure = run_logged(Context, ["rebar3", "compile"], Consumer,
                         ConsumerEnv#{<<"CC">> => check_package:bin(MissingCompiler)}, true),
    Helper = filename:join([Consumer, "_build", "default", "lib", ?APP, "priv", "tmux_owned_io"]),
    case binary:match(Failure, <<"missing-c-compiler">>) =/= nomatch andalso
         file:read_link_info(Helper) =:= {error, enoent} of
        true -> ok;
        false -> check_package:fail("missing compiler did not fail before helper installation", [])
    end,
    set(Receipt, missing_compiler_rejected, true),
    _ = run_logged(Context, ["rebar3", "compile"], Consumer, ConsumerEnv, false),
    Installed = run_logged(Context, ["escript", registry_script(Root), "installed", Consumer],
                           Consumer, ConsumerEnv, false),
    set(Receipt, installed, json:decode(Installed)),
    {ok, _} = file:copy(filename:join(Consumer, "rebar.lock"),
                        filename:join(Attempt, "consumer-rebar.lock")),
    Lib = filename:join([Consumer, "_build", "default", "lib"]),
    case filelib:is_regular(filename:join([Lib, ?APP, "ebin", ?APP ++ ".app"])) of
        true -> ok;
        false -> check_package:fail("dependency not compiled: ~ts", [?APP])
    end,
    Fetched = [decoded(Path) || Path <- lists:nthtail(First, registry_requests(Registry))],
    case lists:member(check_package:bin("/tarballs/" ++ filename:basename(Artifact)), Fetched) of
        true -> ok;
        false -> check_package:fail("consumer did not fetch source artifact: ~ts", [?APP])
    end,
    set(Receipt, consumer,
        check_package:exercise_consumer(Root, Consumer, filename:join([Lib, ?APP, "ebin"]), #{})),
    set(Receipt, helper_built_from_source, true),
    set(Receipt, source_only_consumer, true).

decoded(Path) ->
    try uri_string:percent_decode(Path)
    catch throw:_ -> Path
    end.

write_rebar_config(ConfigDir, Text) ->
    File = filename:join([ConfigDir, ".config", "rebar3", "rebar.config"]),
    ok = filelib:ensure_path(filename:dirname(File)),
    file:write_file(File, Text).

registry_script(Root) ->
    filename:join([Root, "tools", "source_package_registry.escript"]).

% Build the signed registry files for the archives in `registry/public/tarballs`.
registry_metadata(#{root := Root, temp := Temp, tools := Tools} = Context, Env) ->
    Output = run_logged(Context, ["escript", registry_script(Root),
                                  filename:join([Tools, "hex_core", "ebin"]),
                                  filename:join(Temp, "registry")], Temp, Env, false),
    json:decode(Output).

%% Commands

% Run a command with the check's deadline, keep its log and record it in the receipt.
run_logged(#{root := Root, attempt := Attempt, receipt := Receipt}, Command, Cwd, Env,
           ExpectedFailure) ->
    [Program | _] = Command,
    Result = check_package:execute(Cwd, Command, Env),
    #{status := Status, stdout := Stdout, stderr := Stderr, seconds := Seconds} = Result,
    Code = case Status of
        timeout -> 124;
        error ->
            check_package:fail("cannot run ~ts: ~p", [Program, maps:get(reason, Result, error)]);
        Exit -> Exit
    end,
    Text = <<Stdout/binary, Stderr/binary>>,
    [{commands, Logged}] = ets:lookup(Receipt, commands),
    Log = filename:join(Attempt, "command-" ++ integer_to_list(length(Logged) + 1) ++ ".log"),
    ok = file:write_file(Log, Text),
    Entry = #{command => [check_package:bin(Item) || Item <- Command],
              seconds => Seconds, exit_status => Code, timed_out => Status =:= timeout,
              expected_failure => ExpectedFailure,
              log => check_package:bin(lists:nthtail(length(Root) + 1, Log))},
    set(Receipt, commands, Logged ++ [Entry]),
    case {Status, (Code =/= 0) =:= ExpectedFailure} of
        {timeout, _} ->
            error({check_timeout, check_package:bin(io_lib:format(
                "Command '~ts' timed out after 30 seconds", [lists:join(" ", Command)]))});
        {_, true} ->
            case ExpectedFailure of
                true -> Text;
                false -> Stdout
            end;
        {_, false} ->
            Tail = binary:part(Text, max(0, byte_size(Text) - ?LOG_TAIL),
                               min(byte_size(Text), ?LOG_TAIL)),
            check_package:fail("~ts", [check_package:printable(Tail)])
    end.

%% Registry server

-doc """
Serve the files under `Public` over HTTP on a loopback port chosen by the system.
Every GET or HEAD request is recorded by path and answered with the file, `404` or,
after `limit` requests (default 256), `429`. Responses carry an `ETag` of the file's
SHA-256. Other methods get `405`.
""".
-spec start_registry(file:filename(), #{limit => non_neg_integer()}) -> registry().
start_registry(Public, Options) ->
    Limit = maps:get(limit, Options, ?REQUEST_LIMIT),
    {ok, Listen} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false},
                                      {reuseaddr, true}, {backlog, 128}, {packet, http_bin}]),
    {ok, Port} = inet:port(Listen),
    Owner = spawn_link(fun() -> owner(Listen, Public, Limit) end),
    #{port => Port, owner => Owner}.

-spec registry_url(registry()) -> string().
registry_url(#{port := Port}) ->
    "http://127.0.0.1:" ++ integer_to_list(Port).

-doc "The request paths recorded so far, oldest first, as the client sent them.".
-spec registry_requests(registry()) -> [binary()].
registry_requests(#{owner := Owner}) ->
    ask(Owner, requests).

-doc """
Stop accepting connections, end the handlers and return the recorded request paths and
whether every registry process and the listening socket are gone.
""".
-spec stop_registry(registry()) -> {[binary()], boolean()}.
stop_registry(#{owner := Owner}) ->
    Monitor = erlang:monitor(process, Owner),
    {Requests, Quiet} = ask(Owner, stop),
    receive {'DOWN', Monitor, process, Owner, _} -> ok end,
    {Requests, Quiet andalso not is_process_alive(Owner)}.

ask(Owner, Request) ->
    Monitor = erlang:monitor(process, Owner),
    Tag = make_ref(),
    Owner ! {Request, self(), Tag},
    receive
        {Tag, Answer} ->
            erlang:demonitor(Monitor, [flush]),
            Answer;
        {'DOWN', Monitor, process, Owner, Reason} ->
            error({registry_down, Reason})
    end.

owner(Listen, Public, Limit) ->
    Owner = self(),
    {Acceptor, Monitor} = spawn_monitor(fun() -> accept(Listen, Owner, Public) end),
    owner_loop(#{listen => Listen, acceptor => Acceptor, monitor => Monitor, limit => Limit,
                 count => 0, requests => [], handlers => #{}}).

owner_loop(#{requests := Requests, count := Count, limit := Limit, handlers := Handlers} = State) ->
    receive
        {handler, Pid} ->
            Ref = erlang:monitor(process, Pid),
            owner_loop(State#{handlers := Handlers#{Ref => Pid}});
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Handlers) ->
            owner_loop(State#{handlers := maps:remove(Ref, Handlers)});
        {{record, _}, From, Tag} when Count >= Limit ->
            From ! {Tag, limit},
            owner_loop(State);
        {{record, Path}, From, Tag} ->
            From ! {Tag, ok},
            owner_loop(State#{requests := [Path | Requests], count := Count + 1});
        {requests, From, Tag} ->
            From ! {Tag, lists:reverse(Requests)},
            owner_loop(State);
        {stop, From, Tag} ->
            From ! {Tag, {lists:reverse(Requests), shut_down(State)}}
    end.

% Close the listener, wait for the acceptor, then kill the handlers still running.
shut_down(#{listen := Listen, acceptor := Acceptor, monitor := Monitor, handlers := Handlers}) ->
    ok = gen_tcp:close(Listen),
    Running = await_acceptor(Monitor, Handlers),
    lists:foreach(fun({Ref, Pid}) ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> ok end
    end, maps:to_list(Running)),
    erlang:port_info(Listen) =:= undefined andalso not is_process_alive(Acceptor).

await_acceptor(Monitor, Handlers) ->
    receive
        {handler, Pid} ->
            await_acceptor(Monitor, Handlers#{erlang:monitor(process, Pid) => Pid});
        {'DOWN', Monitor, process, _, _} ->
            Handlers;
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Handlers) ->
            await_acceptor(Monitor, maps:remove(Ref, Handlers))
    end.

accept(Listen, Owner, Public) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> receive go -> serve_connection(Socket, Owner, Public) end end),
            case gen_tcp:controlling_process(Socket, Handler) of
                ok ->
                    Owner ! {handler, Handler},
                    Handler ! go;
                {error, _} ->
                    exit(Handler, kill),
                    ok = gen_tcp:close(Socket)
            end,
            accept(Listen, Owner, Public);
        {error, _} ->
            ok
    end.

serve_connection(Socket, Owner, Public) ->
    Response = case read_request(Socket) of
        {ok, Method, Target} -> answer(Method, Target, Owner, Public);
        error -> response(400, [], <<"bad request">>, true)
    end,
    _ = gen_tcp:send(Socket, Response),
    ok = gen_tcp:close(Socket).

read_request(Socket) ->
    case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT_MS) of
        {ok, {http_request, Method, {abs_path, Target}, _}} ->
            case skip_headers(Socket) of
                ok -> {ok, Method, Target};
                error -> error
            end;
        _ -> error
    end.

skip_headers(Socket) ->
    case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT_MS) of
        {ok, http_eoh} -> ok;
        {ok, {http_header, _, _, _, _}} -> skip_headers(Socket);
        _ -> error
    end.

answer(Method, Target, Owner, Public) when Method =:= 'GET'; Method =:= 'HEAD' ->
    case ask(Owner, {record, Target}) of
        limit -> response(429, [], <<"too many requests">>, true);
        ok ->
            case file_for(Public, Target) of
                {ok, Path} ->
                    {ok, Body} = file:read_file(Path),
                    Tag = <<"\"", (script_util:sha256_hex(Body))/binary, "\"">>,
                    response(200, [{"ETag", Tag}], Body, Method =:= 'GET');
                error -> response(404, [], <<"not found">>, Method =:= 'GET')
            end
    end;
answer(_, _, _, _) ->
    response(405, [{"Allow", "GET, HEAD"}], <<"method not allowed">>, true).

% Map a request target to a regular file under `Public`; a `..` segment maps to nothing.
file_for(Public, Target) ->
    [Raw | _] = binary:split(Target, [<<"?">>, <<"#">>]),
    try uri_string:percent_decode(Raw) of
        Decoded when is_binary(Decoded) ->
            Segments = [S || S <- binary:split(Decoded, <<"/">>, [global]),
                             S =/= <<>>, S =/= <<".">>],
            Safe = not lists:member(<<"..">>, Segments) andalso
                   lists:all(fun(S) -> binary:match(S, <<0>>) =:= nomatch end, Segments),
            Path = filename:join([Public | Segments]),
            case Safe andalso Segments =/= [] andalso filelib:is_regular(Path) of
                true -> {ok, Path};
                false -> error
            end
    catch throw:_ -> error
    end.

response(Status, Headers, Body, WithBody) ->
    Reason = case Status of
        200 -> "OK";
        400 -> "Bad Request";
        404 -> "Not Found";
        405 -> "Method Not Allowed";
        429 -> "Too Many Requests"
    end,
    [io_lib:format("HTTP/1.1 ~b ~s\r\nContent-Length: ~b\r\n", [Status, Reason, byte_size(Body)]),
     "Content-Type: application/octet-stream\r\nConnection: close\r\n",
     [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers], "\r\n",
     [Body || WithBody]].

%% Helpers

tools_dir(Root) ->
    filename:join([Root, "_build", "source-package-tools"]).

pins_file(Root) ->
    filename:join([Root, "tools", "package-tool.json"]).

read_pins(Root) ->
    {ok, Text} = file:read_file(pins_file(Root)),
    #{<<"packages">> := Pins} = json:decode(Text),
    Pins.

pin(Name, Pins) ->
    case [Pin || #{<<"name">> := Found} = Pin <- Pins, Found =:= Name] of
        [Pin] -> Pin;
        _ -> check_package:fail("tools/package-tool.json does not pin ~ts", [Name])
    end.

pinned_tarball(Tools, #{<<"name">> := Name, <<"version">> := Version}) ->
    filename:join(Tools, binary_to_list(<<Name/binary, "-", Version/binary, ".tar">>)).

is_pinned(Path, #{<<"sha256">> := Sha256}) ->
    filelib:is_regular(Path) andalso script_util:sha256_hex({file, Path}) =:= Sha256.

sha256(Data) ->
    script_util:sha256_hex(Data).

remove_tree(Path) ->
    case file:del_dir_r(Path) of
        Done when Done =:= ok; Done =:= {error, enoent} -> ok
    end.

set(Receipt, Key, Value) ->
    true = ets:insert(Receipt, {Key, Value}),
    ok.
