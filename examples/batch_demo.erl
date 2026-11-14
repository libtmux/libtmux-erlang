-module(batch_demo).
-moduledoc "Run several commands in one tmux client and read an option batch.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            Cat = #{launch => #{argv => [<<"/bin/cat">>]}},
            {ok, Session} = tmux_session:create(Server,
                Cat#{name => <<"batch">>}),
            {ok, Window} = tmux_window:create(Session, Cat),
            Id = tmux_model:get(id, Session),
            {ok, Rename} = tmux_session:rename_command(Session, <<"batched">>),
            {ok, Stage} = tmux_command:raw(<<"set-option">>,
                [<<"-t">>, Id, <<"@stage">>, <<"built">>]),
            {ok, Owner} = tmux_command:raw(<<"set-option">>,
                [<<"-t">>, Id, <<"@owner">>, <<"batch-demo">>]),
            % Three commands, one native sequence. A failure can leave a prefix.
            {ok, Sequence} = tmux_command:sequence([Rename, Stage, Owner]),
            {ok, #{exit_status := 0}} =
                tmux_server:command(Server, Sequence, #{}),
            {ok, Renamed} = tmux_session:get(Server, Id),
            {ok, [<<"built">>, none]} =
                tmux_option:get_many([Session, Window], <<"@stage">>, #{}),
            #{commands => 3, session_name => tmux_model:get(name, Renamed),
              stage => <<"built">>, window_stage => none}
        end),
    Result.
