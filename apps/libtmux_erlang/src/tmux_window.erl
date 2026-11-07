-module(tmux_window).
-moduledoc """
Create physical windows in a session and act through their registered IDs.

`create/2` accepts name, cwd, env, launch and detach, using the
session's next available index. It defaults to detached. `get/2`
reads current fields; `rename/2` returns the command result and
leaves previous records unchanged. Launch and environment options follow
`tmux_session:create/2`. An empty shell command does not portably keep the
window alive: older tmux releases execute it as a shell command. Use a running
program when needed. Creation returns a fresh observed row or an error
retaining a completed mutation and its result if the follow-up observation
fails.

`kill/1` destroys the physical window and all its links. Use
`tmux_window_link:unlink/2` to remove one session membership. These calls
perform I/O after validating their inputs. `select_layout/2`
changes the physical window's layout across all its session links; previously
observed pane geometry remains unchanged in captured values.
""".
-export([create/2, get/2, rename/2, kill/1, respawn/2, select_layout/2]).

-export_type([create_options/0, respawn_options/0, layout/0]).
-doc "Physical-window creation options; defaults to a detached window at the next free session index.".
-type create_options() :: #{name => binary(), cwd => binary(), env => #{binary() => binary()},
    launch => tmux_command:launch_spec(), detach => boolean()}.
-doc "Physical-window respawn options. Defaults: force false, launch previous, saved cwd. A forced respawn removes other panes.".
-type respawn_options() :: #{force => boolean(), launch => tmux_command:respawn_spec(),
                             cwd => binary(), env => #{binary() => binary()}}.
-doc "A built-in arrangement, its exact binary name, or a serialized layout. Native JSON v2 requires tmux 3.8.".
-type layout() :: even_horizontal | even_vertical | main_horizontal | main_vertical |
                  tiled | binary().

-doc """
Create a physical window in the session's next free index and observe it.
Defaults to detached. Launch, cwd and environment follow
`tmux_session:create/2`. Performs I/O and retains completed-mutation details
if observation fails.
""".
-spec create(tmux_model:session(), create_options()) -> {ok, tmux_model:window()} | {error, map()}.
create(Session, Options) ->
    maybe
        {ok, Flags, Launch} ?= tmux_args:launch_options(Options, [{name, text_format, <<"-n">>}]),
        {ok, Server, Target} ?= tmux_target:resolve(session, Session),
        {ok, Result} ?= tmux_target:run(Server, <<"new-window">>,
            [<<"-P">>, <<"-F">>, <<"#{window_id}">>, <<"-t">>, Target] ++
            Flags ++ [<<"--">> | Launch]),
        tmux_observe:created(Server, window, Result)
    end.

-doc """
Explicitly read a physical window by stable ID. Returns a fresh record or
target_gone. Physical windows do not have a universal session or window index.
""".
-spec get(tmux_server:t(), tmux_model:window_id()) -> {ok, tmux_model:window()} | {error, map()}.
get(Server, Id) -> tmux_observe:get(Server, window, Id).

-doc """
Rename the registered physical window with a literal name. Performs I/O and
returns the command result. Captured rows and snapshots remain unchanged.
""".
-spec rename(tmux_model:window(), binary()) -> {ok, map()} | {error, map()}.
rename(Window, Name) ->
    maybe
        {ok, [_, Literal]} ?= tmux_args:options(#{name => Name}, [{name, text_format, <<"-n">>}]),
        tmux_target:act(window, Window, <<"rename-window">>, [Literal])
    end.

-doc """
Destroy the physical window and all of its session links. This does not unlink
only one membership. Performs I/O after origin and target validation.
""".
-spec kill(tmux_model:window()) -> {ok, map()} | {error, map()}.
kill(Window) -> tmux_target:act(window, Window, <<"kill-window">>, []).

-doc """
Respawn a registered physical window across all its session links. tmux keeps
the first pane's ID, removes the other panes and rebuilds a single-pane
layout. force defaults false: a window with a running pane normally returns
command_error. force = true permits closing existing PTYs. Command completion
does not establish former-job termination or application readiness. Other
panes can already be removed if a later spawn step fails. Respawn also selects
this window in tmux's resolved session. For a window linked into several
sessions, tmux chooses that context from the physical ID; this facade does not
pin selection or environment to a captured membership.

launch defaults to previous and reuses the retained pane's saved command.
Explicit argv and shell maps, saved cwd and fresh-spawn environment rules
follow `tmux_pane:respawn/2`, using the resolved session's environment. This
physical-window mutation affects every link. Performs I/O after validation and
returns the command result without refreshing rows. Use `get/2` or a new
snapshot for current data.
""".
-spec respawn(tmux_model:window(), respawn_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
respawn(Window, Options) ->
    maybe
        {ok, Flags, Launch} ?= tmux_args:respawn_options(Options),
        {ok, Server, Target} ?= tmux_target:resolve(window, Window),
        tmux_target:run(Server, <<"respawn-window">>,
            Flags ++ [<<"-t">>, Target, <<"--">> | Launch])
    end.

-doc """
Select a built-in arrangement or restore a literal serialized layout for this
registered physical window. Binary names must exactly match one of the five
built-ins; abbreviations and other names are rejected. Legacy serialized
layouts need four hexadecimal checksum digits, a comma and nonempty data. This
guard avoids a malformed-header crash in tmux 3.3 and 3.3a.

Native JSON v2 layouts require a bounded JSON object with V = 2 and an L
object. They return unsupported_capability on tmux before 3.8 without
dispatching a tmux command. This preserves `get/2` layout restoration on newer
servers.

Execution unzooms the window and changes it in every linked session. tmux
validates serialized geometry; malformed geometry can return a command error.
The layout argument uses no shell or format expansion. Existing rows are not
refreshed; use `get/2` or a fresh snapshot to observe layout and pane
geometry.

Unsupported atom names fail before dispatch:

```erlang
1> tmux_window:select_layout(invalid_row, unknown_layout).
{error,#{code => invalid_layout,path => [layout]}}
```
""".
-spec select_layout(tmux_model:window(), layout()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
select_layout(Window, Layout) ->
    maybe
        {ok, Argument, Kind} ?= layout_argument(Layout),
        {ok, Server, Target} ?= tmux_target:resolve(window, Window),
        ok ?= require_layout(Kind, Server),
        tmux_target:run(Server, <<"select-layout">>,
            [<<"-t">>, Target, <<"--">>, Argument])
    end.

layout_argument(even_horizontal) -> {ok, <<"even-horizontal">>, base};
layout_argument(even_vertical) -> {ok, <<"even-vertical">>, base};
layout_argument(main_horizontal) -> {ok, <<"main-horizontal">>, base};
layout_argument(main_vertical) -> {ok, <<"main-vertical">>, base};
layout_argument(tiled) -> {ok, <<"tiled">>, base};
layout_argument(Layout) when is_binary(Layout) ->
    Result = maybe
        {ok, _} ?= tmux_command:raw(<<"select-layout">>, [Layout]),
        {ok, _} ?= tmux_schema:value(#{type => text}, Layout),
        layout_kind(Layout)
    end,
    case Result of
        {ok, _, _} -> Result;
        {error, Detail} -> {error, Detail#{path => [layout]}}
    end;
layout_argument(_) -> {error, #{code => invalid_layout, path => [layout]}}.

layout_kind(Layout) ->
    Names = [<<"even-horizontal">>, <<"even-vertical">>, <<"main-horizontal">>,
             <<"main-vertical">>, <<"tiled">>],
    case lists:member(Layout, Names) orelse legacy_header(Layout) of
        true -> {ok, Layout, base};
        false ->
            case tmux_json:decode(Layout) of
                {ok, #{<<"V">> := 2, <<"L">> := Root}} when is_map(Root) ->
                    {ok, Layout, json_v2};
                _ -> {error, #{code => invalid_layout}}
            end
    end.

%% A short/nonhex header leaves an uninitialized error cause in 3.3/3.3a.
%% Require the complete legacy header before those servers can parse it.
legacy_header(<<A, B, C, D, $,, Body/binary>>) when byte_size(Body) > 0 ->
    lists:all(fun(Byte) ->
        is_integer(Byte, $0, $9) orelse is_integer(Byte, $a, $f) orelse
        is_integer(Byte, $A, $F)
    end, [A, B, C, D]);
legacy_header(_) -> false.

require_layout(base, _) -> ok;
require_layout(json_v2, Server) ->
    maybe
        {ok, Version} ?= tmux_server:version(Server),
        case tmux_version:at_least(Version, {3, 8}) of
            true -> ok;
            false -> {error, #{code => unsupported_capability,
                capability => layout_json, minimum => {3, 8}}}
        end
    end.
