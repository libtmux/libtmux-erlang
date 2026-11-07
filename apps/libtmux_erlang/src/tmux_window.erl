-module(tmux_window).
-moduledoc """
Create physical windows in a session and act through their registered IDs.

create accepts name, cwd, env, launch and detach, using the session's next
available index. It defaults to detached. get explicitly reads current fields;
rename returns the command result and leaves previous records unchanged.
Launch and environment options follow tmux_session:create/2.
An empty shell command does not portably keep the window alive: older tmux
releases execute it as a shell command. Use a running program when needed.
Creation returns a fresh observed row or an error retaining a completed
mutation and its result if the follow-up observation fails.

kill destroys the physical window and all its links. It does not mean unlink
one session membership. These calls perform I/O after validating their inputs.
""".
-export([create/2, get/2, rename/2, kill/1]).

-spec create(tmux_model:session(), map()) -> {ok, tmux_model:window()} | {error, map()}.
create(Session, Options) ->
    maybe
        {ok, Flags, Launch} ?= tmux_args:launch_options(Options, [{name, text_format, <<"-n">>}]),
        {ok, Server, Target} ?= tmux_target:resolve(session, Session),
        {ok, Result} ?= tmux_target:run(Server, <<"new-window">>,
            [<<"-P">>, <<"-F">>, <<"#{window_id}">>, <<"-t">>, Target] ++
            Flags ++ [<<"--">> | Launch]),
        tmux_observe:created(Server, window, Result)
    end.

-spec get(tmux_server:t(), tmux_model:window_id()) -> {ok, tmux_model:window()} | {error, map()}.
get(Server, Id) -> tmux_observe:get(Server, window, Id).

-spec rename(tmux_model:window(), binary()) -> {ok, map()} | {error, map()}.
rename(Window, Name) ->
    maybe
        {ok, [_, Literal]} ?= tmux_args:options(#{name => Name}, [{name, text_format, <<"-n">>}]),
        tmux_target:act(window, Window, <<"rename-window">>, [Literal])
    end.

-spec kill(tmux_model:window()) -> {ok, map()} | {error, map()}.
kill(Window) -> tmux_target:act(window, Window, <<"kill-window">>, []).
