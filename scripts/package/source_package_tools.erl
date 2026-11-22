-module(source_package_tools).
-moduledoc "Provision pinned Hex tools and bind their cache to source, BEAM and runtime identities.".
-export([prepare/1, ensure_pins/3, unpack_core/2, compile_core/1, runtime/0,
         prepared_manifest/3, verify_prepared/4, tools_dir/1, read_pins/1, pin/2,
         pinned_tarball/2]).

-define(DOWNLOAD_LIMIT, 8 * 1024 * 1024).
-define(PREPARE_COMMAND, "escript scripts/package/check_source_package.erl --prepare").

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

-spec tools_dir(file:filename()) -> file:filename().
tools_dir(Root) ->
    filename:join([Root, "_build", "source-package-tools"]).

pins_file(Root) ->
    filename:join([Root, "tools", "package-tool.json"]).

-spec read_pins(file:filename()) -> [map()].
read_pins(Root) ->
    {ok, Text} = file:read_file(pins_file(Root)),
    #{<<"packages">> := Pins} = json:decode(Text),
    Pins.

-spec pin(binary(), [map()]) -> map().
pin(Name, Pins) ->
    case [Pin || #{<<"name">> := Found} = Pin <- Pins, Found =:= Name] of
        [Pin] -> Pin;
        _ -> check_package:fail("tools/package-tool.json does not pin ~ts", [Name])
    end.

-spec pinned_tarball(file:filename(), map()) -> file:filename().
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
