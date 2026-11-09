-module(workspace_apply_demo).
-moduledoc "Apply a workspace and verify an empty second plan.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    Directory = <<"/tmp/ltm-workspace-apply-", Suffix/binary>>,
    ok = file:make_dir(Directory),
    Result = tmux_scope:run_or_error(fun() ->
        ok = file:change_mode(Directory, 8#700),
        Source = filename:join(Directory, <<"workspace.json">>),
        PlanFile = filename:join(Directory, <<"plan.json">>),
        {ok, _} = file:copy("examples/workspace_apply.json", Source),
        {ok, Output} = tmux_server:with_owned(#{executable => Executable},
            fun(Server) ->
                {ok, Plan} = tmux_workspace_plan:new(Source, Server, #{}),
                ok = tmux_workspace_plan:write(Plan, PlanFile),
                {ok, Stored} = tmux_workspace_plan:read(PlanFile),
                {ok, #{completed := Completed}} =
                    tmux_workspace_apply:run(Stored, Server, #{}),
                true = length(Completed) > 0,
                {ok, Snapshot} = tmux_server:snapshot(Server),
                [Session] = tmux_snapshot:sessions(Snapshot),
                <<"project">> = tmux_model:get(name, Session),
                {ok, [Window]} =
                    tmux_snapshot:related(windows, Session, Snapshot),
                <<"api">> = tmux_model:get(name, Window),
                {ok, Panes} = tmux_snapshot:related(panes, Window, Snapshot),
                2 = length(Panes),
                {ok, Settled} = tmux_workspace_plan:new(Source, Server, #{}),
                #{<<"steps">> := []} = tmux_workspace_plan:to_map(Settled),
                {ok, #{completed := []}} =
                    tmux_workspace_apply:run(Settled, Server, #{}),
                #{sessions => 1, windows => 1, panes => 2,
                  plan_round_trip => true, second_plan_empty => true}
            end),
        Output
    end, fun() -> file:del_dir_r(Directory) end),
    {error, enoent} = file:read_file_info(Directory),
    Result#{files_removed => true}.
