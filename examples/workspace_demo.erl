-module(workspace_demo).
-moduledoc "Load a real workspace file and inspect its desired object graph.".
-export([run/0]).

-spec run() -> map().
run() ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    Directory = <<"/tmp/ltm-workspace-demo-", Suffix/binary>>,
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    Output = try
        Path = filename:join(Directory, <<"workspace.json">>),
        {ok, _} = file:copy("examples/workspace.json", Path),
        {ok, Workspace} = tmux_workspace:load(Path),
        #{id := Id, endpoint := Endpoint, sessions := [Session]} =
            tmux_workspace:to_map(Workspace),
        #{name := SessionName, windows := [Window]} = Session,
        #{name := WindowName, layout := <<"even-horizontal">>,
          panes := [Build, Shell]} = Window,
        #{cwd := Directory, launch := #{argv := Arguments}} = Build,
        [<<"rebar3">>, <<"shell">>] = Arguments,
        #{cwd := Directory, launch := #{shell := <<"exec erl">>}} = Shell,
        #{workspace_id => Id, endpoint => Endpoint,
          session => SessionName, window => WindowName, panes => 2,
          first_pane_key => maps:get(key, Build), canonical_cwd => true,
          shell_declared => true, launched => false}
    after
        ok = file:del_dir_r(Directory)
    end,
    {error, enoent} = file:read_file_info(Directory),
    Output#{files_removed => true}.
