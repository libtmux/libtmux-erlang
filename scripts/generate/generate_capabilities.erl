%% Export the library's operation gates for documentation and package consumers.
-module(generate_capabilities).
-mode(compile).
-moduledoc """
Write capabilities.json from the compiled tmux_capability registry.
--check refuses stale or missing copies without rewriting them.
""".
-export([main/1, run/2]).

-spec main([string()]) -> ok.
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    Check = case Arguments of
        [] -> false;
        ["--check"] -> true;
        _ ->
            io:format(standard_error,
                "usage: generate_capabilities.erl [--check]~n", []),
            halt(2)
    end,
    case run(Root, Check) of
        ok -> ok;
        {drift, Path} ->
            io:format(standard_error, "capability manifest drift: ~ts~n", [Path]),
            halt(1)
    end.

-doc "Write both registry manifests, or return the first stale path in check mode.".
-spec run(file:filename(), boolean()) -> ok | {drift, string()}.
run(Root, Check) ->
    Bytes = iolist_to_binary([json:format(tmux_capability:manifest()), $\n]),
    files(Root, ["capabilities.json", "apps/libtmux_erlang/capabilities.json"], Bytes, Check).

files(_, [], _, _) -> ok;
files(Root, [Path | Rest], Bytes, Check) ->
    Target = filename:join(Root, Path),
    case Check of
        false ->
            ok = file:write_file(Target, Bytes),
            files(Root, Rest, Bytes, Check);
        true ->
            case file:read_file(Target) of
                {ok, Bytes} -> files(Root, Rest, Bytes, Check);
                _ -> {drift, Path}
            end
    end.
