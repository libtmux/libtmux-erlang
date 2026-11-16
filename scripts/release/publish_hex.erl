% Publish the qualified package and its prebuilt documentation to Hex.
-module(publish_hex).
-moduledoc """
Publish `libtmux_erlang` and its prebuilt documentation to Hex with Rebar3.

```console
$ escript scripts/release/publish_hex.erl --published false
```

`--published true` skips the package, which Hex already holds, and publishes
only the documentation. The release workflow passes the `published` output of
`check_release.erl`. Documentation comes from `_build/docs/core`. An empty or
unset `HEX_API_KEY` is removed from the publisher's environment so Rebar3 does
not mistake it for a key. Each command waits for Hex to finish, within ten
minutes. The script prints each command's output and stops at the first
failure.
""".
-mode(compile).
-export([main/1, plan/2, environment/1]).
-export_type([command/0]).

-define(APP, "libtmux_erlang").
-define(DEADLINE_MS, 600000).

-type command() :: [string()].

-spec main([string()]) -> no_return().
main(["--published", Published]) when Published =:= "true"; Published =:= "false" ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    Options = #{cwd => unicode:characters_to_binary(Root),
                env => environment(os:getenv("HEX_API_KEY")),
                timeout_ms => ?DEADLINE_MS},
    lists:foreach(fun(Command) -> publish(Command, Options) end,
                  plan(Root, Published =:= "true")),
    halt(0);
main(_) ->
    io:format(standard_error, "usage: publish_hex.erl --published true|false~n", []),
    halt(2).

-doc """
The Rebar3 commands to run from `Root`: the package unless Hex already holds
it, then the documentation.
""".
-spec plan(file:filename(), boolean()) -> [command()].
plan(Root, AlreadyPublished) ->
    Package = ["rebar3", "as", "release", "hex", "publish", "package",
               "--app", ?APP, "--yes", "--wait"],
    Docs = ["rebar3", "as", "release", "hex", "publish", "docs", "--app", ?APP,
            "--yes", "--wait", "--doc-dir", filename:join(Root, "_build/docs/core")],
    case AlreadyPublished of
        true -> [Docs];
        false -> [Package, Docs]
    end.

-doc """
The environment overrides for the publisher: unset `HEX_API_KEY` when it is
missing or empty.
""".
-spec environment(string() | false) -> #{binary() => false}.
environment(false) -> #{<<"HEX_API_KEY">> => false};
environment("") -> #{<<"HEX_API_KEY">> => false};
environment(_) -> #{}.

publish([Program | Arguments] = Command, Options) ->
    io:format("$ ~s~n", [lists:join(" ", Command)]),
    #{status := Status, stdout := Stdout, stderr := Stderr} =
        script_util:run(Program, Arguments, Options),
    io:format("~ts~ts", [Stdout, Stderr]),
    Status =:= 0 orelse begin
        io:format(standard_error, "publish failed: ~p~n", [Status]),
        halt(1)
    end.
