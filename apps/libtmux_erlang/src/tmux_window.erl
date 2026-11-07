-module(tmux_window).
-moduledoc """
Create physical windows in a session and act through their registered IDs.

create accepts name, cwd, env, launch and detach, using the session's next
available index. It defaults to detached. get explicitly reads current fields;
rename returns the command result and leaves previous records unchanged.
Launch and environment options follow `tmux_session:create/2`.
An empty shell command does not portably keep the window alive: older tmux
releases execute it as a shell command. Use a running program when needed.
Creation returns a fresh observed row or an error retaining a completed
mutation and its result if the follow-up observation fails.

kill destroys the physical window and all its links. It does not mean unlink
one session membership. These calls perform I/O after validating their inputs.
select_layout changes the physical window's layout across all its session links;
previously observed pane geometry remains unchanged in captured values.
""".
-export([create/2, get/2, rename/2, kill/1, select_layout/2]).

-export_type([create_options/0, layout/0]).
-doc "Physical-window creation options; defaults to a detached window at the next free session index.".
-type create_options() :: #{name => binary(), cwd => binary(), env => #{binary() => binary()},
    launch => tmux_command:launch_spec(), detach => boolean()}.
-doc "A built-in arrangement, its exact binary name, or a serialized layout. Native JSON v2 requires tmux 3.8.".
-type layout() :: even_horizontal | even_vertical | main_horizontal | main_vertical |
                  tiled | binary().

-doc """
Create a physical window in the session's next free index and observe it.
Defaults to detached. Launch, cwd and environment follow `tmux_session:create/2`.
Performs I/O and retains completed-mutation details if observation fails.
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
Destroy the physical window and all of its session links. This does not
unlink only one membership. Performs I/O after origin and target validation.
""".
-spec kill(tmux_model:window()) -> {ok, map()} | {error, map()}.
kill(Window) -> tmux_target:act(window, Window, <<"kill-window">>, []).

-doc """
Select a built-in arrangement or restore a literal serialized layout for this
registered physical window. Binary names must exactly match one of the five
built-ins; abbreviations and other names are rejected. Legacy serialized
layouts need four hexadecimal checksum digits, a comma and nonempty data.
This guard avoids a malformed-header crash in tmux 3.3 and 3.3a.

Native JSON v2 layouts require a bounded JSON object with V = 2 and an L object.
They return unsupported_capability on tmux before 3.8 without dispatching a
tmux command. This preserves `get/2` layout restoration on newer servers.

Execution unzooms the window and changes it in every linked session. tmux
validates serialized geometry; malformed geometry can return a command error.
The layout argument uses no shell or format expansion. Existing rows are not
refreshed; use `get/2` or a
fresh snapshot to observe layout and pane geometry.

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
