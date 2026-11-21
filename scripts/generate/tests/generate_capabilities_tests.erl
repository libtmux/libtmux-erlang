-module(generate_capabilities_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

manifest_drift_test() ->
    script_util:with_tmp_dir("capability-manifest", fun(Root) ->
        ok = filelib:ensure_path(filename:join([Root, "apps", "libtmux_erlang"])),
        ok = generate_capabilities:run(Root, false),
        ok = generate_capabilities:run(Root, true),
        lists:foreach(fun(Path) ->
            Target = filename:join(Root, Path),
            {ok, Original} = file:read_file(Target),
            ok = file:write_file(Target, <<"{}\n">>),
            ?assertEqual({drift, Path}, generate_capabilities:run(Root, true)),
            ok = file:write_file(Target, Original)
        end, ["capabilities.json", "apps/libtmux_erlang/capabilities.json"]),
        ok = generate_capabilities:run(Root, true)
    end).
