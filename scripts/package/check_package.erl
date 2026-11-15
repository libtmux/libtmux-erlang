% Check native imports from a compiled OTP archive outside the checkout.
-module(check_package).
-moduledoc """
Check the compiled OTP archive as an installed consumer.

```console
$ escript scripts/package/check_package.erl [--dialyzer]
```

Run `rebar3 compile` first, and `rebar3 dialyzer` before `--dialyzer`. The
script assembles `libtmux_erlang` from `_build/default/lib`, unpacks it into a
private directory outside the checkout and runs the installed-consumer
commands there. It writes `_build/package-check/receipt.json` and exits 0 only
when every command passed.

`check_source_package` and `check_hex_install` call `exercise_consumer/4` to
run the same commands against a Hex source installation.
""".
-mode(compile).
-include_lib("kernel/include/file.hrl").
-export([main/1, assemble_archive/3, archive_members/2, extract_archive/2,
         exercise_consumer/4, stage_consumer/2, consumer_files/0, consumer_commands/2,
         dialyzer_commands/3, consumer_env/2, base_env/0, rebar_env/2, rebar_dirs/2,
         select_tmux/2, run_command/4, execute/3, receipt/3, run_script/1, write_json/2,
         encode_json/1, fail/2, bin/1, printable/1, round6/1, delete_file/1]).
-export_type([command/0, env/0]).

-define(APP, "libtmux_erlang").
-define(COMMAND_TIMEOUT_MS, 30000).
-define(CONSUMER_SCRUBBED, ["ERL_LIBS", "TMUX", "TMUX_PANE"]).
-define(REBAR_SCRUBBED, ["ERL_LIBS", "TMUX", "TMUX_PANE", "REBAR_CONFIG", "HEX_API_KEY",
                         "HEX_CDN", "HEX_UNSAFE_REGISTRY", "HEX_NO_VERIFY_REPO_ORIGIN",
                         "HEX_TRUSTED_MIRROR_URL", "HEX_MIRROR_URL"]).

-doc "A program followed by its arguments.".
-type command() :: [unicode:chardata(), ...].
-doc "Environment overrides for a child: a binary value sets, `false` unsets.".
-type env() :: #{binary() => binary() | false}.

-spec main([string()]) -> no_return().
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    case Arguments of
        [] -> run_script(fun() -> run(Root, #{dialyzer => false}) end);
        ["--dialyzer"] -> run_script(fun() -> run(Root, #{dialyzer => true}) end);
        [Help] when Help =:= "-h"; Help =:= "--help" ->
            io:format("usage: check_package.erl [--dialyzer]~n"),
            halt(0);
        _ ->
            io:format(standard_error, "usage: check_package.erl [--dialyzer]~n", []),
            halt(2)
    end.

-doc """
Run `Fun`, which returns an exit status, and halt with it. A failed check prints
its message to standard error and exits 1.
""".
-spec run_script(fun(() -> non_neg_integer())) -> no_return().
run_script(Fun) ->
    Status = try Fun()
    catch
        error:{check_failed, Message} ->
            io:format(standard_error, "~ts~n", [Message]),
            1;
        Class:Reason:Stack ->
            io:format(standard_error, "~p:~p~n~p~n", [Class, Reason, Stack]),
            1
    end,
    halt(Status).

run(Root, Options) ->
    Started = erlang:monotonic_time(microsecond),
    ArtifactDir = filename:join([Root, "_build", "package-check"]),
    ok = filelib:ensure_path(ArtifactDir),
    ReceiptFile = filename:join(ArtifactDir, "receipt.json"),
    ok = delete_file(ReceiptFile),
    {Archive, Prefix} = assemble_archive(Root, ?APP, ArtifactDir),
    {Commands, Temp} = script_util:with_tmp_dir("tmux-erlang-consumer", fun(Temp) ->
        ok = extract_archive(Archive, Temp),
        Ebin = filename:join([Temp, Prefix, "ebin"]),
        {exercise_consumer(Root, Temp, Ebin, Options), Temp}
    end),
    false = filelib:is_file(Temp),
    Seconds = (erlang:monotonic_time(microsecond) - Started) / 1.0e6,
    Receipt = receipt(script_util:sha256_hex({file, Archive}), Commands, round6(Seconds)),
    io:put_chars(write_json(ReceiptFile, Receipt)),
    0.

-doc """
Assemble `App` from its compiled build output as a gzip-compressed tar archive in
`ArtifactDir` and return its path and the top-level directory name. The bytes
depend only on the input files and their executable bits.
""".
-spec assemble_archive(file:filename(), string(), file:filename()) ->
    {file:filename(), string()}.
assemble_archive(Root, App, ArtifactDir) ->
    Members = archive_members(Root, App),
    Prefix = App ++ "-0.0.0+development",
    Archive = filename:join(ArtifactDir, App ++ "-otp.tar.gz"),
    Tar = script_util:with_tmp_dir("package-archive", fun(Directory) ->
        Path = filename:join(Directory, "archive.tar"),
        {ok, Descriptor} = erl_tar:open(Path, [write]),
        Fixed = [{atime, 0}, {mtime, 0}, {ctime, 0}, {uid, 0}, {gid, 0}],
        lists:foreach(fun({Name, Source, Mode}) ->
            ok = erl_tar:add(Descriptor, {Prefix ++ "/" ++ Name, read(Source)},
                             [{mode, Mode} | Fixed])
        end, Members),
        ok = erl_tar:close(Descriptor),
        read(Path)
    end),
    ok = file:write_file(Archive, zlib:gzip(Tar)),
    {Archive, Prefix}.

-doc """
List the archive members as `{NameInArchive, SourcePath, Mode}`: the compiled
`ebin` files, `LICENSE`, `CHANGELOG.md` and everything under `priv`. Fails when
the application is not compiled.
""".
-spec archive_members(file:filename(), string()) ->
    [{string(), file:filename(), 8#644 | 8#755}].
archive_members(Root, App) ->
    Application = filename:join([Root, "_build", "default", "lib", App]),
    Ebin = filename:join(Application, "ebin"),
    Beams = [Name || Name <- list_sorted(Ebin), filelib:is_regular(filename:join(Ebin, Name))],
    case Beams =/= [] andalso filelib:is_regular(filename:join(Ebin, App ++ ".app")) of
        true -> ok;
        false -> fail("Run mise exec -- rebar3 compile first", [])
    end,
    Compiled = [{"ebin/" ++ Name, filename:join(Ebin, Name)} || Name <- Beams],
    Texts = [{Name, filename:join([Root, "apps", App, Name])}
             || Name <- ["LICENSE", "CHANGELOG.md"]],
    Priv = [{filename:join(["priv" | Relative]), Path}
            || {Relative, Path} <- walk(filename:join(Application, "priv"), [])],
    [{Name, Path, mode(Path)} || {Name, Path} <- Compiled ++ Texts ++ Priv].

-spec extract_archive(file:filename(), file:filename()) -> ok.
extract_archive(Archive, Directory) ->
    case erl_tar:extract(Archive, [compressed, {cwd, Directory}]) of
        ok -> ok;
        {error, Reason} -> fail("cannot unpack ~ts: ~p", [Archive, Reason])
    end.

-doc """
Run the installed public consumers against the application in `InstalledEbin`.
`Temp` is the consumer directory and its working directory. `Options` may set
`dialyzer` to run the type consumers too. Returns one receipt per command and
fails at the first command that exits nonzero.
""".
-spec exercise_consumer(file:filename(), file:filename(), file:filename(),
                        #{dialyzer => boolean()}) -> [map()].
exercise_consumer(Root, Temp, InstalledEbin, Options) ->
    Plt = case maps:get(dialyzer, Options, false) of
        true -> plt(Root);
        false -> none
    end,
    ok = stage_consumer(Root, Temp),
    Env = consumer_env(Temp, tmux_executable()),
    Run = fun({Kind, Command}) ->
        run_command(Root, Temp, Command, #{env => Env, json => Kind =:= json})
    end,
    Commands = lists:map(Run, consumer_commands(Temp, InstalledEbin)),
    case Plt of
        none -> Commands;
        _ ->
            ok = stage_type_consumer(Root, Temp),
            Commands ++ lists:map(Run, dialyzer_commands(Temp, InstalledEbin, Plt))
    end.

-doc """
Files the consumer receives from the checkout, as `{Source, Destination}` paths
relative to the repository root and the consumer directory.
""".
-spec consumer_files() -> [{string(), string()}].
consumer_files() ->
    [{"examples/native_consumer.erl", "native_consumer.erl"},
     {"test/tmux_test_fixture.erl", "tmux_test_fixture.erl"},
     {"tools/run_examples.escript", "tools/run_examples.escript"},
     {"test/tmux_test_fixture.erl", "test/tmux_test_fixture.erl"}]
    ++ [{"examples/" ++ Demo ++ ".erl", "examples/" ++ Demo ++ ".erl"} || Demo <- demos()]
    ++ python_files().

% The Python watcher and job helper that Erlang replacements retire; delete these
% entries with them.
python_files() ->
    [{"test/tmux_fixture_watch.py", "consumer-ebin/tmux_fixture_watch.py"},
     {"test/tmux_fixture_watch.py", "test/tmux_fixture_watch.py"},
     {"examples/terminal_job.py", "examples/terminal_job.py"}].

demos() ->
    ["filter_demo", "inspect_demo", "readme_demo", "linked_graph", "job_demo",
     "options_demo", "buffer_demo", "pane_demo", "config_demo", "pipe_demo", "hook_demo",
     "key_demo", "command_demo", "control_demo", "plan_demo", "batch_demo", "typing_demo"].

-doc """
Create the consumer's working directories and copy `consumer_files/0` and the
retained-model fixture into `Temp`. Fails when a source is missing or a
directory already exists.
""".
-spec stage_consumer(file:filename(), file:filename()) -> ok.
stage_consumer(Root, Temp) ->
    lists:foreach(fun(Name) -> ok = file:make_dir(filename:join(Temp, Name)) end,
                  ["consumer-ebin", "tools", "test", "examples", "legacy"]),
    lists:foreach(fun({Source, Destination}) ->
        copy(filename:join(Root, Source), filename:join(Temp, Destination))
    end, consumer_files()),
    ok = file:write_file(filename:join([Temp, "legacy", "tmux_model.erl"]), legacy_model()).

stage_type_consumer(Root, Temp) ->
    TypeSources = filename:join(Temp, "type-consumer"),
    ok = file:make_dir(TypeSources),
    lists:foreach(fun(Name) ->
        copy(filename:join([Root, "test", "consumers", Name]), filename:join(TypeSources, Name))
    end, ["model_types_ok.erl", "model_types_bad.erl"]),
    copy(filename:join([Root, "tools", "check_model_types.escript"]),
         filename:join([Temp, "tools", "check_model_types.escript"])).

-doc """
The installed-consumer commands, each tagged `json` when its standard output is
a JSON receipt. Commands run in `Temp` in the listed order.
""".
-spec consumer_commands(file:filename(), file:filename()) ->
    [{plain | json, command()}].
consumer_commands(Temp, InstalledEbin) ->
    ConsumerEbin = filename:join(Temp, "consumer-ebin"),
    Helper = filename:join([filename:dirname(InstalledEbin), "priv", "tmux_owned_io"]),
    [{json, ["escript", "tools/run_examples.escript", "--ebin", InstalledEbin]},
     {plain, ["erlc", "-Werror", "+debug_info", "-pa", InstalledEbin, "-o", ConsumerEbin,
              "native_consumer.erl", "tmux_test_fixture.erl"]},
     {plain, ["erl", "-noshell", "-noinput", "-pa", InstalledEbin, "-pa", ConsumerEbin,
              "-eval", "ok = native_consumer:run(), halt(0)."]},
     % A separate VM retains a native value whose captured definition lacks the
     % new field. Changing only model_version on a new row misses this.
     {plain, ["erl", "-noshell", "-noinput", "-pa", InstalledEbin, "-eval", legacy_eval()]},
     {plain, [Helper, "--exec-one", "/bin/true"]},
     {plain, ["erl", "-noshell", "-noinput", "-pa", InstalledEbin, "-eval", transport_eval()]},
     % OTP makes a bare top-level app path absolute; ./ retains the relative priv
     % path needed to exercise child-cwd independence.
     {plain, ["erl", "-noshell", "-noinput", "-pa", "./" ++ relative(InstalledEbin, Temp),
              "-pa", ConsumerEbin, "-eval", endpoint_eval()]}].

-doc "The Dialyzer commands for `--dialyzer`, run after `stage_consumer/2` and the type sources.".
-spec dialyzer_commands(file:filename(), file:filename(), file:filename()) ->
    [{plain | json, command()}].
dialyzer_commands(Temp, InstalledEbin, Plt) ->
    ConsumerEbin = filename:join(Temp, "consumer-ebin"),
    [{plain, ["dialyzer", "--plt", Plt, filename:join(ConsumerEbin, "native_consumer.beam"),
              filename:join(ConsumerEbin, "tmux_test_fixture.beam"), "-r", InstalledEbin]},
     {json, ["escript", "tools/check_model_types.escript", InstalledEbin, Plt,
             filename:join(Temp, "type-consumer")]}].

legacy_model() ->
    ~"""
    -module(tmux_model).
    -export([old_pane/0]).
    -export_record([pane]).
    -record #pane{id, origin = none, snapshot_id = none, model_version = 1}.
    old_pane() -> #pane{id = <<"%1">>}.

    """.

legacy_eval() ->
    eval(~"""
    {tmux_model, Current, Name} = code:get_object_code(tmux_model),
    {ok, tmux_model, Legacy} = compile:file("legacy/tmux_model.erl", [binary]),
    {module, tmux_model} = code:load_binary(tmux_model, "legacy", Legacy),
    Old = tmux_model:old_pane(), Table = ets:new(retained_rows, []),
    true = ets:insert(Table, {pane, Old}),
    {module, tmux_model} = code:load_binary(tmux_model, Name, Current),
    {error, #{code := invalid_row}} = tmux_model:validate(Old),
    [{pane, Retained}] = ets:lookup(Table, pane),
    {error, #{code := invalid_row}} = tmux_model:validate(Retained),
    {ok, Fresh} = tmux_model:pane(#{id => <<"%1">>}),
    2 = tmux_model:model_version(Fresh),
    {ok, Fresh} = tmux_model:validate(Fresh),
    true = ets:delete(Table), halt(0).
    """).

transport_eval() ->
    eval(~"""
    {ok, #{stdout := <<0,255,10>>, stderr := <<>>, exit_status := 0,
    cleanup := complete}} = tmux_transport:run(<<"/bin/cat">>, [],
    #{stdin => <<0,255,10>>}),
    ok = application:stop(libtmux_erlang), halt(0).
    """).

endpoint_eval() ->
    eval(~"""
    Executable = unicode:characters_to_binary(os:getenv("LIBTMUX_TEST_TMUX")),
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try #{socket := Socket} = tmux_test_fixture:info(Fixture),
    ok = native_consumer:run_endpoint(Socket, Executable)
    after ok = tmux_test_fixture:close(Fixture) end,
    ok = application:stop(libtmux_erlang), halt(0).
    """).

eval(Lines) ->
    binary:replace(Lines, <<"\n">>, <<" ">>, [global]).

-doc """
Environment overrides for the consumer commands: the build search path and the
tmux session variables are removed, and the tmux executable and a crash dump
inside `Temp` are set.
""".
-spec consumer_env(file:filename(), unicode:chardata()) -> env().
consumer_env(Temp, Tmux) ->
    maps:merge(scrub(?CONSUMER_SCRUBBED),
               #{<<"LIBTMUX_TEST_TMUX">> => bin(Tmux),
                 <<"ERL_CRASH_DUMP">> => bin(filename:join(Temp, "erl_crash.dump"))}).

-doc """
Environment overrides every Rebar3 build command starts from: build, Hex and tmux
variables are removed and `ERL_FLAGS` defaults to `+S 4:4`.
""".
-spec base_env() -> env().
base_env() ->
    Flags = case os:getenv("ERL_FLAGS") of
        false -> "+S 4:4";
        Value -> Value
    end,
    maps:put(<<"ERL_FLAGS">>, bin(Flags), scrub(?REBAR_SCRUBBED)).

-doc "`base_env/0` with the Rebar3 configuration and caches moved to `ConfigDir` and `CacheDir`.".
-spec rebar_env(file:filename(), file:filename()) -> env().
rebar_env(ConfigDir, CacheDir) ->
    maps:merge(base_env(), rebar_dirs(ConfigDir, CacheDir)).

-doc "The variables that point Rebar3 at a private configuration directory and cache.".
-spec rebar_dirs(file:filename(), file:filename()) -> env().
rebar_dirs(ConfigDir, CacheDir) ->
    #{<<"REBAR_GLOBAL_CONFIG_DIR">> => bin(ConfigDir),
      <<"REBAR_CACHE_DIR">> => bin(CacheDir),
      <<"REBAR_GLOBAL_CACHE_DIR">> => bin(CacheDir)}.

scrub(Names) ->
    #{bin(Name) => false || Name <- Names}.

tmux_executable() ->
    select_tmux(os:getenv("LIBTMUX_TEST_TMUX"), os:find_executable("tmux")).

-doc """
Pick the tmux executable: `LIBTMUX_TEST_TMUX` when set and non-empty, else the
one found on `PATH`. It must be an absolute path.
""".
-spec select_tmux(string() | false, string() | false) -> string().
select_tmux(Variable, Found) ->
    Tmux = case Variable of
        Set when is_list(Set), Set =/= "" -> Set;
        _ -> Found
    end,
    case is_list(Tmux) andalso filename:pathtype(Tmux) =:= absolute of
        true -> Tmux;
        false -> fail("The installed endpoint check requires an absolute tmux executable", [])
    end.

plt(Root) ->
    case filelib:wildcard(filename:join([Root, "_build", "default", "*_plt"])) of
        [Plt] -> Plt;
        _ -> fail("Run mise exec -- rebar3 dialyzer first", [])
    end.

-doc """
Run `Command` in `Cwd` with the 30 second deadline the checks use. Returns the
captured result and keeps standard output and standard error separate.
""".
-spec execute(file:filename(), command(), env()) -> script_util:result().
execute(Cwd, [Program | Arguments], Env) ->
    script_util:run(Program, Arguments,
                    #{cwd => bin(Cwd), env => Env, timeout_ms => ?COMMAND_TIMEOUT_MS}).

-doc """
Run `Command` and return its receipt: `program`, `command` (with `Cwd` shown as
`<consumer>` and `Root` as `<repo>`), `exit_status` and `seconds`, plus the
decoded `output` when `json` is set. Options are `env` and `json`. A command
that fails, times out or prints invalid JSON raises with its output.
""".
-spec run_command(file:filename(), file:filename(), command(),
                  #{env => env(), json => boolean()}) -> map().
run_command(Root, Cwd, [Program | _] = Command, Options) ->
    Result = execute(Cwd, Command, maps:get(env, Options, #{})),
    #{status := Status, stdout := Stdout, stderr := Stderr, seconds := Seconds} = Result,
    Receipt = #{program => bin(filename:basename(Program)),
                command => [display(Item, Cwd, Root) || Item <- Command],
                exit_status => Status,
                seconds => round6(Seconds)},
    case Status of
        0 -> ok;
        _ -> fail("~ts failed (~p):~n~ts",
                  [Program, Status, printable(<<Stdout/binary, Stderr/binary>>)])
    end,
    case maps:get(json, Options, false) of
        false -> Receipt;
        true -> Receipt#{output => decode(Program, Stdout)}
    end.

decode(Program, Stdout) ->
    try json:decode(Stdout)
    catch error:Reason -> fail("~ts printed invalid JSON: ~p", [Program, Reason])
    end.

display(Item, Cwd, Root) ->
    Text = binary:replace(bin(Item), bin(Cwd), <<"<consumer>">>, [global]),
    binary:replace(Text, bin(Root), <<"<repo>">>, [global]).

-doc "The receipt `check_package` writes after every command passed.".
-spec receipt(binary(), [map()], float()) -> map().
receipt(ArchiveSha256, Commands, Seconds) ->
    #{result => <<"PASS">>,
      scope => <<"Compiled OTP archive, native records, doctest, helper adapter, "
                 "owned startup and borrowed endpoint">>,
      archive_sha256 => ArchiveSha256,
      commands => Commands,
      temporary_consumer_removed => true,
      seconds => Seconds,
      hex_source_package => <<"UNVERIFIED">>,
      installed_helper_adapter => <<"PASS">>,
      public_borrowed_endpoint => <<"PASS">>,
      public_owned_endpoint => <<"PASS: installed README uses private startup, graph "
                                 "operations and token-based retirement">>,
      public_command_builders => <<"PASS: installed commands example builds captured "
                                   "targets, rejects foreign origins and executes "
                                   "through one-shot operations">>,
      public_control_attachment => <<"PASS: installed control example verifies "
                                     "same-connection identity, attachment counts, "
                                     "unchanged dimensions and native detachment">>,
      relative_code_path_child_cwd => <<"PASS">>,
      public_domain_consumer => <<"PASS: session lifecycle, pane topology, literal "
                                  "names, window/pane deletion and session cleanup">>,
      retained_native_model => <<"PASS: old native shape in process and ETS is rejected "
                                 "after loading model version 2; fresh rows validate">>,
      public_input_consumer => <<"PASS: text/native key delivery and normal job exit "
                                 "after EOF">>,
      public_hook_consumer => <<"PASS: sparse registration, manual execution, empty "
                                "override and local removal">>,
      public_layout_consumer => <<"PASS: restore native serialized layouts after "
                                  "changing arrangement; require JSON v2 on tmux 3.8+">>,
      public_snapshot_consumer => <<"PASS: captured graph, native pane lists, "
                                    "relationships and coverage">>,
      public_filter_consumer => <<"PASS: local selection, graph filter, wire round trip, "
                                  "cardinality and prepared context">>,
      public_option_consumer => <<"PASS: local ownership, sparse arrays and inherited "
                                  "restoration">>,
      documentation_examples => <<"PASS: first program, graph, jobs, options, buffers, "
                                  "pane topology, configuration, pipe consumer, hooks, "
                                  "keys and command builders from the installed archive">>,
      public_tmux_command_api => <<"PARTIAL: command values, operations and initial "
                                   "domain facades">>,
      publication => <<"UNVERIFIED">>}.

-doc "Encode `Term` as JSON indented by two spaces, with a trailing newline.".
-spec encode_json(term()) -> binary().
encode_json(Term) ->
    iolist_to_binary(json:format(Term, #{indent => 2})).

-doc "Write `Term` to `Path` as indented JSON and return the text written.".
-spec write_json(file:filename(), term()) -> binary().
write_json(Path, Term) ->
    Text = encode_json(Term),
    ok = file:write_file(Path, Text),
    Text.

-doc "Raise a failed check whose message is the formatted text.".
-spec fail(io:format(), [term()]) -> no_return().
fail(Format, Arguments) ->
    error({check_failed, bin(io_lib:format(Format, Arguments))}).

-doc "Convert text to a binary.".
-spec bin(unicode:chardata()) -> binary().
bin(Text) when is_binary(Text) -> Text;
bin(Text) ->
    case unicode:characters_to_binary(Text) of
        Binary when is_binary(Binary) -> Binary
    end.

-doc "Replace bytes that are not UTF-8 with U+FFFD, so the text is safe to encode as JSON.".
-spec printable(binary()) -> binary().
printable(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Text when is_binary(Text) -> Text;
        {error, Valid, <<_, Rest/binary>>} ->
            <<Valid/binary, 16#FFFD/utf8, (printable(Rest))/binary>>;
        {incomplete, Valid, _} ->
            <<Valid/binary, 16#FFFD/utf8>>
    end.

-doc "Round seconds to microseconds.".
-spec round6(number()) -> float().
round6(Seconds) ->
    round(Seconds * 1.0e6) / 1.0e6.

-spec delete_file(file:filename()) -> ok.
delete_file(Path) ->
    case file:delete(Path) of
        Done when Done =:= ok; Done =:= {error, enoent} -> ok
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> Data;
        {error, Reason} -> fail("cannot read ~ts: ~p", [Path, Reason])
    end.

copy(Source, Destination) ->
    case file:copy(Source, Destination) of
        {ok, _} -> ok;
        {error, Reason} -> fail("cannot copy ~ts: ~p", [Source, Reason])
    end.

list_sorted(Directory) ->
    case file:list_dir(Directory) of
        {ok, Names} -> lists:sort(Names);
        {error, _} -> []
    end.

walk(Directory, Relative) ->
    lists:flatmap(fun(Name) ->
        Path = filename:join(Directory, Name),
        case file:read_link_info(Path) of
            {ok, #file_info{type = directory}} -> walk(Path, Relative ++ [Name]);
            _ -> [{Relative ++ [Name], Path} || filelib:is_regular(Path)]
        end
    end, list_sorted(Directory)).

mode(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{mode = Mode}} when Mode band 8#100 =/= 0 -> 8#755;
        _ -> 8#644
    end.

relative(Path, Base) ->
    Prefix = filename:split(Base),
    case lists:split(length(Prefix), filename:split(Path)) of
        {Prefix, Rest} when Rest =/= [] -> filename:join(Rest);
        _ -> fail("~ts is not inside ~ts", [Path, Base])
    end.
