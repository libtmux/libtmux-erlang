-module(generate_capabilities).
-mode(compile).
-moduledoc """
Write the root capabilities.json from the compiled registry. Pass --check to
detect drift and leave the file intact.
""".
-export([main/1, run/2]).

-define(MANIFEST, "capabilities.json").

-spec main([string()]) -> ok.
main(Arguments) ->
    Check = case Arguments of
        [] -> false;
        ["--check"] -> true;
        _ ->
            io:format(standard_error, "usage: generate_capabilities.erl [--check]~n", []),
            halt(2)
    end,
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    case run(Root, Check) of
        ok -> ok;
        {drift, Path} ->
            io:format(standard_error, "capability manifest drift: ~ts~n", [Path]),
            halt(1)
    end.

-doc "Write the registry manifest, or report a missing or stale file in check mode.".
-spec run(file:filename(), boolean()) -> ok | {drift, string()}.
run(Root, Check) ->
    Path = filename:join(Root, ?MANIFEST),
    Bytes = iolist_to_binary(json:format(tmux_capability:manifest())),
    case Check of
        false -> ok = file:write_file(Path, Bytes);
        true ->
            case file:read_file(Path) of
                {ok, Bytes} -> ok;
                _ -> {drift, ?MANIFEST}
            end
    end.
