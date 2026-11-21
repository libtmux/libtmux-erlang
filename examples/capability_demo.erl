-module(capability_demo).
-moduledoc "Inspect daemon feature decisions inside an owned endpoint scope.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            {ok, Vsn} = tmux_server:version(Server),
            {ok, Layout} = tmux_capability:decision(Vsn, layout_json),
            {ok, Control} = tmux_capability:decision(Vsn, control_no_detach),
            {error, #{code := unknown_capability}} =
                tmux_capability:decision(Vsn, unknown),
            #{daemon_version => tmux_version:format(Vsn),
              json_layout => maps:with([supported, minimum, handling], Layout),
              control => maps:with([supported, handling, fallback], Control)}
        end),
    Result.
