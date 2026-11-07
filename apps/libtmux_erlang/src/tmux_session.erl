-module(tmux_session).
-moduledoc """
Create and observe sessions, or act on a session's registered stable ID.

create accepts name, window_name, width, height, cwd, env, launch and detach.
Creation defaults to detached with tmux's configured shell/command. launch is
default_shell, an argv map, or an explicit shell map. env augments tmux's
inherited environment. tmux supplies PATH, SHELL, PWD and TMUX_PANE after that
merge, so those entries may be replaced. Names and cwd are literal format
values; tmux's stored name rules still apply. Creation never adopts an existing
session by name.

An empty shell command can exit immediately and remove its session. It does
not request the empty-pane behavior of split-window. Use a running program
when later operations require the session to remain alive.

create and get explicitly read the new/current row through several one-shot
commands. These reads are not atomic. If creation succeeds but observation
fails, the error retains mutation = completed and the original command result.
rename and kill return command results without refreshing the input record.
Detached rows require tmux_server:bind before actions. Every call performs I/O
except when validation rejects its arguments first.
""".
-export([create/2, get/2, rename/2, kill/1]).

-spec create(tmux_server:t(), map()) -> {ok, tmux_model:session()} | {error, map()}.
create(Server, Options) ->
    maybe
        {ok, Flags, Launch} ?= tmux_args:launch_options(Options,
            [{name, text_format, <<"-s">>}, {window_name, text_format, <<"-n">>},
             {width, dimension, <<"-x">>}, {height, dimension, <<"-y">>}]),
        {ok, Result} ?= tmux_target:run(Server, <<"new-session">>,
            [<<"-P">>, <<"-F">>, <<"#{session_id}">>] ++ Flags ++ [<<"--">> | Launch]),
        tmux_observe:created(Server, session, Result)
    end.

-spec get(tmux_server:t(), tmux_model:session_id()) -> {ok, tmux_model:session()} | {error, map()}.
get(Server, Id) -> tmux_observe:get(Server, session, Id).

-spec rename(tmux_model:session(), binary()) -> {ok, map()} | {error, map()}.
rename(Session, Name) ->
    maybe
        {ok, [_, Literal]} ?= tmux_args:options(#{name => Name}, [{name, text_format, <<"-n">>}]),
        tmux_target:act(session, Session, <<"rename-session">>, [Literal])
    end.

-spec kill(tmux_model:session()) -> {ok, map()} | {error, map()}.
kill(Session) -> tmux_target:act(session, Session, <<"kill-session">>, []).
