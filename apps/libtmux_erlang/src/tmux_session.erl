-module(tmux_session).
-moduledoc """
Create and observe sessions, or act on a session's registered stable ID.

`create/2` accepts name, window_name, width, height, cwd, env,
launch and detach. Creation defaults to detached with tmux's configured
shell/command. launch is default_shell, an argv map, or an explicit shell map.
env augments tmux's inherited environment. tmux supplies PATH, SHELL, PWD and
TMUX_PANE after that merge, so those entries may be replaced. Names and cwd
are literal format values; tmux's stored name rules still apply. Creation
never adopts an existing session by name.

An empty shell command can exit immediately and remove its session. It does
not request the empty-pane behavior of split-window. Use a running program
when later operations require the session to remain alive.

`create/2` and `get/2` explicitly read the
new/current row through several one-shot commands. These reads are not atomic.
If creation succeeds but observation fails, the error retains mutation =
completed and the original command result. `rename/2` and
`kill/1` return command results without refreshing the input
record. Detached rows require `tmux_server:bind/2` before actions.
`rename_command/2` builds a reusable value without tmux I/O; the other calls
perform I/O after validation.

`select/2` switches one explicitly named attached client to a session. It
never attaches a client or infers the current client. Use
`tmux_window_link:select/1` to select a session's window membership instead.
""".
-export([create/2, get/2, rename/2, rename_command/2, select/2, select/3, kill/1]).

-export_type([create_options/0, select_options/0]).
-doc "Session creation options. Launch defaults to the configured shell; creation defaults to detached.".
-type create_options() :: #{name => binary(), window_name => binary(),
    width => 1..65535, height => 1..65535, cwd => binary(),
    env => #{binary() => binary()}, launch => tmux_command:launch_spec(), detach => boolean()}.

-doc "Session selection options. update_environment defaults to false, preserving the destination environment.".
-type select_options() :: #{update_environment => boolean()}.

-doc """
Create a detached session by default and explicitly observe the returned row.
Options include name, window_name, dimensions, cwd, env and launch. Performs
I/O; an observation failure after successful creation retains mutation =
completed and the original command result. Existing names are not adopted.
""".
-spec create(tmux_server:t(), create_options()) -> {ok, tmux_model:session()} | {error, map()}.
create(Server, Options) ->
    maybe
        {ok, Flags, Launch} ?= tmux_args:launch_options(Options,
            [{name, text_format, <<"-s">>}, {window_name, text_format, <<"-n">>},
             {width, dimension, <<"-x">>}, {height, dimension, <<"-y">>}]),
        {ok, Result} ?= tmux_target:run(Server, <<"new-session">>,
            [<<"-P">>, <<"-F">>, <<"#{session_id}">>] ++ Flags ++ [<<"--">> | Launch]),
        tmux_observe:created(Server, session, Result)
    end.

-doc """
Read fresh session fields through explicit one-shot commands. The session ID
is stable within the observed server incarnation. Returns target_gone when
tmux no longer has that session; it never refreshes an existing record.
""".
-spec get(tmux_server:t(), tmux_model:session_id()) -> {ok, tmux_model:session()} | {error, map()}.
get(Server, Id) -> tmux_observe:get(Server, session, Id).

-doc """
Rename the registered session using a literal name and return the command
result. Performs I/O. Previously captured records keep their old names;
detached or stale references fail validation before the action.
""".
-spec rename(tmux_model:session(), binary()) -> {ok, map()} | {error, map()}.
rename(Session, Name) ->
    maybe
        {ok, Command} ?= rename_command(Session, Name),
        tmux_target:execute(Command)
    end.

-doc """
Build a literal rename command without tmux I/O. Validates the row and keeps
its captured origin; endpoint liveness is checked during execution. Submit
the value to `tmux_server:command/3` or `tmux_operation:start/3` with its original
endpoint. Existing session records retain their captured name.

Detached rows require `tmux_server:bind/2` first. Building a command does not
execute it or make a repeated mutation safe.

```erlang
1> tmux_session:rename_command(invalid_row, <<"work">>).
{error,#{code => invalid_row,path => []}}
```
""".
-spec rename_command(tmux_model:session(), binary()) -> {ok, tmux_command:t()} | {error, map()}.
rename_command(Session, Name) ->
    maybe
        {ok, [_, Literal]} ?= tmux_args:options(#{name => Name}, [{name, text_format, <<"-n">>}]),
        {ok, Origin, Target} ?= tmux_target:captured_target(session, Session),
        tmux_command:generated(session_rename, Origin, [<<"-t">>, Target, <<"--">>, Literal])
    end.

-doc """
Switch an explicitly named attached client to this registered session,
preserving the session environment. Performs I/O. See `select/3` for client
lookup, environment updates and disconnection races.

An empty client name cannot select an implicit current client:

```erlang
1> tmux_session:select(invalid_session, <<>>).
{error,#{code => invalid_client,path => [client]}}
```
""".
-spec select(tmux_model:session(), binary()) -> {ok, map()} | {error, map()}.
select(Session, Client) -> select(Session, Client, #{}).

-doc """
Switch one attached client, selected by its literal native client name or TTY
path, to the session's registered stable ID. Performs I/O and returns the
command result; existing rows remain captured values. Obtain the name from
the caller's own client context, such as tmux's `client_name` format. There
is no default client and this call never attaches one.

`update_environment` defaults to false (`switch-client -E`). When true, tmux
updates the destination session environment using its `update-environment`
option and that client's environment; listed variables absent from the client
can be marked for removal. Running pane processes retain their environment.

Names are nonempty NUL-free binaries of at most 32 KiB. Trailing-colon aliases
are rejected. Native lookup matches an exact name or TTY path, including its
`/dev/`-relative alias; there is no prefix or pattern matching. A disconnected
name returns `client_not_found`. Names and TTY paths can be reused by a later
connection; this API does not identify a client incarnation atomically. A
missing destination returns `target_gone`. See `tmux_server:bind/2` for detached
session rows and `tmux_window_link:select/1` for window selection.
""".
-spec select(tmux_model:session(), binary(), select_options()) ->
    {ok, map()} | {error, map()}.
select(Session, Client, Options) ->
    maybe
        ok ?= client_name(Client),
        {ok, []} ?= tmux_args:options(Options,
            [{update_environment, boolean, <<>>}]),
        {ok, Server, Target} ?= tmux_target:resolve(session, Session),
        Flags = case maps:get(update_environment, Options, false) of
            true -> [];
            false -> [<<"-E">>]
        end,
        case tmux_target:run(Server, <<"switch-client">>,
            Flags ++ [<<"-c">>, Client, <<"-t">>, Target]) of
            {error, #{code := command_error,
                      stderr := <<"can't find client: ", _/binary>>} = Error} ->
                {error, Error#{code => client_not_found}};
            Result -> Result
        end
    end.

client_name(Name) when is_binary(Name), byte_size(Name) > 0,
                       byte_size(Name) =< 32768 ->
    case binary:last(Name) =/= $: andalso binary:match(Name, <<0>>) =:= nomatch of
        true -> ok;
        false -> {error, #{code => invalid_client, path => [client]}}
    end;
client_name(_) -> {error, #{code => invalid_client, path => [client]}}.

-doc """
Destroy this registered session. Performs I/O and returns the command result;
this is a destructive session action, not endpoint cleanup. References must
belong to a live registered owner.
""".
-spec kill(tmux_model:session()) -> {ok, map()} | {error, map()}.
kill(Session) -> tmux_target:act(session, Session, <<"kill-session">>, []).
