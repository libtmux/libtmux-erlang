-module(tmux_window_link).
-moduledoc """
Act on a physical window's observed membership in a particular session.

A window link is identified by session ID, window index and expected physical
window ID. It has no stable tmux link ID. These calls check that the observed
membership still names the expected window before dispatching an action.
Missing or replaced membership returns stale_link. A link that moves away and
back to the same coordinates and physical window cannot be distinguished.

The preflight and action use separate one-shot commands. Concurrent changes
after preflight can still affect the action; this is not atomic
compare-and-act. All input rows must belong to the same registered owner.
Re-read or explicitly bind rows when using another owner. Closed owners and
known restarts invalidate their rows. Every call performs explicit I/O after
validating its arguments.

Use `tmux_window:kill/1` to destroy a physical window across all memberships.
Use `unlink/2` to remove one membership. Existing rows and
snapshots are never refreshed by actions; use `get/3` or a
new snapshot for current memberships.
""".
-export([get/3, select/1, link/3, move/3, swap/3, unlink/2, check/2]).
-export_type([index/0, placement_options/0, swap_options/0, unlink_options/0]).

-doc "An explicit tmux window index; relative and next-free selectors are not accepted.".
-type index() :: 0..2147483647.
-doc "Destination index is required. Defaults: detach true, replace false. Replacement may destroy the destination window.".
-type placement_options() :: #{index := index(), detach => boolean(), replace => boolean()}.
-doc "Maps detach to tmux's -d flag, default true.".
-type swap_options() :: #{detach => boolean()}.
-doc "Force defaults false. Force permits unlinking the last membership and destroying its physical window.".
-type unlink_options() :: #{force => boolean()}.

-doc """
Read a current membership at the explicit session ID and index. The returned
native row carries its registered owner and a new observation identity.
Returns target_gone if the session or index is absent. This read does not make
later actions atomic and does not refresh previously captured links.

Invalid indexes are rejected before I/O:

```erlang
1> tmux_window_link:get(invalid_server, <<"$0">>, -1).
{error,#{code => invalid_option,path => [index]}}
```
""".
-spec get(tmux_server:t(), tmux_model:session_id(), index()) ->
    {ok, tmux_model:window_link()} | {error, map()}.
get(Server, SessionId, Index) ->
    maybe
        {ok, IndexBytes} ?= index(Index),
        {ok, SessionTarget} ?= tmux_target:selector(session, SessionId),
        {ok, Origin} ?= tmux_server:origin(Server),
        {ok, #{stdout := Output}} ?= tmux_target:run(Server, <<"list-windows">>,
            [<<"-t">>, SessionTarget,
             <<"-f">>, <<"#{==:#{window_index},", IndexBytes/binary, "}">>, <<"-F">>,
             <<"#{session_id}\t#{window_index}\t#{window_id}\t#{window_active}">>]),
        {ok, Row} ?= decode(Output, SessionId, Index),
        {ok, Server} ?= tmux_server:from_origin(Origin),
        {ok, tmux_model:bind(Row, Origin, make_ref())}
    end.

-doc """
Select this membership as its session's current window after checking the
expected physical window. Performs I/O and returns the command result.
""".
-spec select(tmux_model:window_link()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
select(Link) ->
    maybe
        {ok, Server} ?= tmux_target:owner(window_link, Link),
        {ok, _, Target} ?= check(Server, Link),
        tmux_target:run(Server, <<"select-window">>, [<<"-t">>, Target])
    end.

-doc """
Add another membership of this link's physical window to the destination
session and explicit index. Defaults to detached and refuses an occupied
index. replace = true maps to tmux -k and can destroy the occupied window.
Returns the command result; use `get/3` to observe the new membership. The
source membership remains. Session groups and renumber-windows retain their
tmux semantics. Performs I/O after owner and membership checks.
""".
-spec link(tmux_model:window_link(), tmux_model:session(), placement_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
link(Link, Session, Options) -> place(<<"link-window">>, Link, Session, Options).

-doc """
Move this membership to the destination session and explicit index, leaving
its physical window's other links intact. Placement options follow `link/3`.
Moving the final window out of a session can destroy that session; automatic
renumbering and session groups can change other memberships. Captured rows
remain unchanged. Returns the command result after observed preflight.
""".
-spec move(tmux_model:window_link(), tmux_model:session(), placement_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
move(Link, Session, Options) -> place(<<"move-window">>, Link, Session, Options).

-doc """
Swap the physical windows at two checked memberships. Other links to either
window remain intact. detach maps to tmux -d and defaults true. tmux applies
its session-selection and group-synchronization rules. Returns the command
result; old rows still name their original expected windows and can become
stale. Performs I/O, with the documented gap between preflight and action.
""".
-spec swap(tmux_model:window_link(), tmux_model:window_link(), swap_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
swap(Source, Destination, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options, [{detach, flag, <<"-d">>}], #{detach => true}),
        {ok, Server} ?= tmux_target:same_owner(window_link, Source, window_link, Destination),
        {ok, _, From} ?= check(Server, Source),
        {ok, _, To} ?= check(Server, Destination),
        tmux_target:run(Server, <<"swap-window">>,
            Flags ++ [<<"-s">>, From, <<"-t">>, To])
    end.

-doc """
Remove one checked membership. force defaults false, retaining tmux's
protection for windows linked to only one session. force = true permits
removing the last link, destroying that physical window and possibly its
session. Duplicate links within one session retain tmux's native protection
rules. Performs I/O and returns the command result without refreshing rows.
""".
-spec unlink(tmux_model:window_link(), unlink_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
unlink(Link, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options, [{force, flag, <<"-k">>}], #{}),
        {ok, Server} ?= tmux_target:owner(window_link, Link),
        {ok, _, Target} ?= check(Server, Link),
        tmux_target:run(Server, <<"unlink-window">>, Flags ++ [<<"-t">>, Target])
    end.

place(Command, Link, Session, Options) ->
    maybe
        {ok, Index, Flags} ?= placement(Options),
        {ok, Server} ?= tmux_target:same_owner(window_link, Link, session, Session),
        {ok, _, Source} ?= check(Server, Link),
        {ok, SessionTarget} ?= tmux_target:selector(session, tmux_model:get(id, Session)),
        Target = <<SessionTarget/binary, Index/binary>>,
        tmux_target:run(Server, Command, Flags ++ [<<"-s">>, Source, <<"-t">>, Target])
    end.

placement(Options) when is_map(Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(maps:remove(index, Options),
            [{detach, flag, <<"-d">>}, {replace, flag, <<"-k">>}], #{detach => true}),
        {ok, Index} ?= case maps:find(index, Options) of
            {ok, Value} -> index(Value);
            error -> {error, #{code => missing_option, path => [index]}}
        end,
        {ok, Index, Flags}
    end;
placement(_) -> {error, #{code => invalid_options, path => []}}.

index(Value) when is_integer(Value, 0, 2147483647) -> {ok, integer_to_binary(Value)};
index(_) -> {error, #{code => invalid_option, path => [index]}}.

-doc false.
-spec check(tmux_server:t(), tmux_model:window_link()) ->
    {ok, tmux_model:window_link(), binary()} | {error, map()}.
check(Server, Link) ->
    SessionId = tmux_model:get(session_id, Link),
    Index = tmux_model:get(index, Link),
    Expected = tmux_model:get(window_id, Link),
    case get(Server, SessionId, Index) of
        {ok, Current} ->
            case tmux_model:get(window_id, Current) of
                Expected ->
                    {ok, Current, <<SessionId/binary, $:, (integer_to_binary(Index))/binary>>};
                Actual -> {error, #{code => stale_link, expected => Expected, actual => Actual}}
            end;
        {error, #{code := target_gone} = Cause} ->
            {error, #{code => stale_link, expected => Expected, cause => Cause}};
        {error, _} = Error -> Error
    end.

decode(<<>>, _, _) -> {error, #{code => target_gone}};
decode(Output, SessionId, Index) when byte_size(Output) =< 256 ->
    IndexBytes = integer_to_binary(Index),
    case binary:split(Output, <<"\t">>, [global]) of
        [SessionId, IndexBytes, WindowId, <<Active, $\n>>] when Active =:= $0; Active =:= $1 ->
            tmux_model:window_link(#{session_id => SessionId, index => Index,
                window_id => WindowId, active => Active =:= $1});
        _ -> {error, #{code => invalid_observation, entity => window_link}}
    end;
decode(_, _, _) -> {error, #{code => invalid_observation, entity => window_link}}.
