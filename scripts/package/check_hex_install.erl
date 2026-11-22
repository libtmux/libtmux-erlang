% Install the public Hex release in a clean consumer and run the quickstart.
-module(check_hex_install).
-moduledoc """
Install a published `libtmux_erlang` release from Hex into an empty consumer
and run the reader quickstart on an owned tmux server.

```console
$ escript scripts/package/check_hex_install.erl VERSION
```

The release verifier runs it after approval. `VERSION` must be SemVer without
build metadata. The consumer has no checkout, plugin or build cache and no Hex
credentials, and the C helper must build from the packaged source. The script
writes `_build/checks/hex-install.json`: `UNVERIFIED` when the install starts and
`PASS` only after every command passed, so a failed run never leaves `PASS`.
""".
-mode(compile).
-export([main/1, run/2]).

-define(APP, "libtmux_erlang").

-spec main([string()]) -> no_return().
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    case Arguments of
        [Version] when Version =/= "-h", Version =/= "--help" ->
            check_package:run_script(fun() -> run(Root, Version) end);
        [Help] when Help =:= "-h"; Help =:= "--help" ->
            io:format("usage: check_hex_install.erl VERSION~n"),
            halt(0);
        _ ->
            io:format(standard_error, "usage: check_hex_install.erl VERSION~n", []),
            halt(2)
    end.

-doc """
Check `Version`, install it from Hex into a private consumer and write the receipt.
Returns the exit status 0; any failure raises and leaves the `UNVERIFIED` receipt.
""".
-spec run(file:filename(), string()) -> 0.
run(Root, Version) ->
    ok = validate_version(Version),
    Started = erlang:monotonic_time(microsecond),
    Output = filename:join([Root, "_build", "checks", "hex-install.json"]),
    ok = filelib:ensure_path(filename:dirname(Output)),
    ok = file:write_file(Output, [json:encode(#{result => <<"UNVERIFIED">>,
                                                version => check_package:bin(Version),
                                                reason => <<"public installation started">>}),
                                  "\n"]),
    {Compile, Quickstart, Temp} = script_util:with_tmp_dir("erlang-hex-consumer", fun(Temp) ->
        Consumer = filename:join(Temp, "consumer"),
        ok = file:make_dir(Consumer),
        Env = check_package:rebar_env(filename:join(Temp, "config"), filename:join(Temp, "cache")),
        ok = file:write_file(filename:join(Consumer, "rebar.config"),
                             ["{deps, [{libtmux_erlang, ", io_lib:write_string(Version),
                              "}]}.\n"]),
        Compile = check_package:run_command(Root, Consumer, ["rebar3", "compile"],
                                            #{env => Env}),
        Installed = filename:join([Consumer, "_build", "default", "lib", ?APP]),
        filelib:is_regular(filename:join([Installed, "priv", "tmux_owned_io"])) orelse
            check_package:fail("public source installation did not build the helper", []),
        Quickstart = check_package:exercise_quickstart(Root, Consumer,
                                                      filename:join(Installed, "ebin")),
        {Compile, Quickstart, Temp}
    end),
    Receipt = #{result => <<"PASS">>,
                version => check_package:bin(Version),
                source => <<"public hexpm registry; empty consumer and build cache">>,
                compile => Compile,
                consumers => [Quickstart],
                temporary_consumer_removed => not filelib:is_file(Temp),
                seconds => check_package:round6((erlang:monotonic_time(microsecond) - Started)
                                                / 1.0e6)},
    io:put_chars(check_package:write_json(Output, Receipt)),
    0.

% The release check owns the rule; its failure becomes this script's message.
validate_version(Version) ->
    try check_release:validate_version(Version, none) of
        Version -> ok
    catch error:{release, Message} -> check_package:fail("~ts", [Message])
    end.
