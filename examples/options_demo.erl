-module(options_demo).
-moduledoc "Use local options to mark workspace ownership without inheritance.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"options">>, launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            Owner = <<"@libtmux-owner">>,
            none = tmux_option:get(Session, Owner, #{}),
            {ok, _} = tmux_option:set(Session, Owner, <<"build-workspace">>,
                #{only_if_unset => true}),
            {ok, <<"build-workspace">>} = tmux_option:get(Session, Owner, #{}),
            {ok, Window} = tmux_window:create(Session,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            none = tmux_option:get(Window, <<"remain-on-exit">>, #{}),
            {ok, Effective} = tmux_option:get(Window, <<"remain-on-exit">>,
                #{inherit => true}),
            {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
            {ok, <<"on">>} = tmux_option:get(Window, <<"remain-on-exit">>, #{}),
            {ok, _} = tmux_option:unset(Window, <<"remain-on-exit">>),
            none = tmux_option:get(Window, <<"remain-on-exit">>, #{}),
            {ok, Effective} = tmux_option:get(Window, <<"remain-on-exit">>,
                #{inherit => true}),
            Env = <<"update-environment">>,
            {ok, _} = tmux_option:set(Session, {Env, 7}, <<>>),
            {ok, #{7 := <<>>}} = tmux_option:get(Session, Env, #{}),
            none = tmux_option:get(Session, {Env, 8}, #{}),
            #{owner => <<"build-workspace">>, restored_inheritance => true,
              empty_entry_preserved => true, missing_entry => true}
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
