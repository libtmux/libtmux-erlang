-module(generate_capabilities_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

manifest_drift_test() ->
    script_util:with_tmp_dir("capability-manifest", fun(Root) ->
        Path = filename:join(Root, "capabilities.json"),
        ?assertEqual({drift, "capabilities.json"}, generate_capabilities:run(Root, true)),
        ok = generate_capabilities:run(Root, false),
        ok = generate_capabilities:run(Root, true),
        {ok, Bytes} = file:read_file(Path),
        Expected = iolist_to_binary(json:encode(tmux_capability:manifest())),
        ?assertEqual(json:decode(Expected), json:decode(Bytes)),
        ok = file:write_file(Path, <<"{}\n">>),
        ?assertEqual({drift, "capabilities.json"}, generate_capabilities:run(Root, true)),
        ?assertEqual({ok, <<"{}\n">>}, file:read_file(Path))
    end).
