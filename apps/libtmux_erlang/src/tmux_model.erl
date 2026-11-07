%% Generated from schema/entities.json by tools/generate_schema.escript.
-module(tmux_model).
-moduledoc """
Validated native domain records. Constructors perform no tmux I/O.

Missing optional observations remain not_loaded; required identity fields
must be supplied. Unavailable capabilities remain
unavailable. Neither state means an empty relation or known absence.
Rows created by `new/2` and the entity constructors are detached.
Use `tmux_server:bind/2` to register a fresh observed row for actions;
use `m:tmux_snapshot` for captured graph relationships.
""".
-export_record([session, window, window_link, pane]).
-export([new/2, validate/1, entity/1, get/2, to_map/1, origin/1,
         snapshot_id/1, model_version/1, bind/3]).
-export([session/1, window/1, window_link/1, pane/1]).
-export_type([row/0, pane_id/0, window_id/0, session_id/0,
              session/0, window/0, window_link/0, pane/0]).

-doc "A canonical pane ID binary in the percent namespace; nominal checking is by Dialyzer.".
-nominal pane_id() :: binary().
-doc "A canonical physical-window ID binary in the at-sign namespace.".
-nominal window_id() :: binary().
-doc "A canonical session ID binary in the dollar namespace.".
-nominal session_id() :: binary().

-record #session{
    id :: session_id(),
    name = not_loaded :: binary() | not_loaded | unavailable,
    attached_count = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    attached = not_loaded :: boolean() | not_loaded | unavailable,
    created = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    origin = none :: none | reference(),
    snapshot_id = none :: none | reference(),
    model_version = 1 :: pos_integer()
}.

-record #window{
    id :: window_id(),
    name = not_loaded :: binary() | not_loaded | unavailable,
    width = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    height = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    pane_count = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    layout = not_loaded :: binary() | not_loaded | unavailable,
    origin = none :: none | reference(),
    snapshot_id = none :: none | reference(),
    model_version = 1 :: pos_integer()
}.

-record #window_link{
    session_id :: session_id(),
    window_id :: window_id(),
    index :: non_neg_integer(),
    active = not_loaded :: boolean() | not_loaded | unavailable,
    origin = none :: none | reference(),
    snapshot_id = none :: none | reference(),
    model_version = 1 :: pos_integer()
}.

-record #pane{
    id :: pane_id(),
    window_id = not_loaded :: window_id() | not_loaded | unavailable,
    index = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    active = not_loaded :: boolean() | not_loaded | unavailable,
    current_command = not_loaded :: binary() | not_loaded | unavailable,
    current_path = not_loaded :: binary() | not_loaded | unavailable,
    width = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    height = not_loaded :: non_neg_integer() | not_loaded | unavailable,
    pid = not_loaded :: pos_integer() | none | not_loaded | unavailable,
    title = not_loaded :: binary() | not_loaded | unavailable,
    dead = not_loaded :: boolean() | not_loaded | unavailable,
    exit_status = not_loaded :: integer() | none | not_loaded | unavailable,
    origin = none :: none | reference(),
    snapshot_id = none :: none | reference(),
    model_version = 1 :: pos_integer()
}.

-doc "One schema-defined native domain record, with separate origin and capture metadata.".
-type row() :: #session{} | #window{} | #window_link{} | #pane{}.
-doc "A validated session observation. Native records are experimental in OTP 29.".
-type session() :: #session{}.
-doc "A validated window observation. Native records are experimental in OTP 29.".
-type window() :: #window{}.
-doc "A validated window_link observation. Native records are experimental in OTP 29.".
-type window_link() :: #window_link{}.
-doc "A validated pane observation. Native records are experimental in OTP 29.".
-type pane() :: #pane{}.

-doc """
Construct a detached row from validated observations.

```erlang
1> {ok, Pane} = tmux_model:new(pane, #{id => <<"%1">>, width => 120}), ok.
ok
2> tmux_model:get(width, Pane).
120
```
""".
-spec new(atom(), map()) -> {ok, row()} | {error, map()}.
new(Entity, Fields) ->
    maybe
        {ok, Normalized} ?= tmux_schema:normalize(Entity, Fields),
        {ok, build(Entity, Normalized)}
    end.

-doc "Construct a detached session row, validating required fields and scalar bounds without tmux I/O.".
-spec session(map()) -> {ok, session()} | {error, map()}.
session(Fields) -> new(session, Fields).

-doc "Construct a detached window row, validating required fields and scalar bounds without tmux I/O.".
-spec window(map()) -> {ok, window()} | {error, map()}.
window(Fields) -> new(window, Fields).

-doc "Construct a detached window_link row, validating required fields and scalar bounds without tmux I/O.".
-spec window_link(map()) -> {ok, window_link()} | {error, map()}.
window_link(Fields) -> new(window_link, Fields).

-doc "Construct a detached pane row, validating required fields and scalar bounds without tmux I/O.".
-spec pane(map()) -> {ok, pane()} | {error, map()}.
pane(Fields) -> new(pane, Fields).

-doc "Validate native row shape, model version and normalized observations. Exported records do not enforce these invariants at construction. Performs no I/O.".
-spec validate(term()) -> {ok, row()} | {error, map()}.
validate(Row) ->
    case row_metadata(Row) of
        {Entity, 1, Origin, Snapshot}
          when (Origin =:= none orelse is_reference(Origin)),
               (Snapshot =:= none orelse is_reference(Snapshot)) ->
            Fields = to_map(Row),
            case tmux_schema:normalize(Entity, Fields) of
                {ok, Fields} -> {ok, Row};
                {ok, _} -> {error, #{code => unnormalized_row, path => []}};
                {error, _} = Error -> Error
            end;
        _ -> {error, #{code => invalid_row, path => []}}
    end.

-doc "Return the built-in entity kind of a native row without I/O.".
-spec entity(row()) -> atom().
entity(#session{}) -> session;
entity(#window{}) -> window;
entity(#window_link{}) -> window_link;
entity(#pane{}) -> pane.

-doc "Read the opaque origin token, or none for a detached row. This does not revalidate endpoint lifetime.".
-spec origin(row()) -> none | reference().
origin(#session{origin = Value}) -> Value;
origin(#window{origin = Value}) -> Value;
origin(#window_link{origin = Value}) -> Value;
origin(#pane{origin = Value}) -> Value.

-doc "Read the capture identity, or none when not associated with a snapshot. Performs no I/O.".
-spec snapshot_id(row()) -> none | reference().
snapshot_id(#session{snapshot_id = Value}) -> Value;
snapshot_id(#window{snapshot_id = Value}) -> Value;
snapshot_id(#window_link{snapshot_id = Value}) -> Value;
snapshot_id(#pane{snapshot_id = Value}) -> Value.

-doc "Read the native model version. Unknown versions fail validation; record internals are not a persistence format.".
-spec model_version(row()) -> pos_integer().
model_version(#session{model_version = Value}) -> Value;
model_version(#window{model_version = Value}) -> Value;
model_version(#window_link{model_version = Value}) -> Value;
model_version(#pane{model_version = Value}) -> Value.

-doc "Return domain field values without origin or capture metadata. This is not the portable filter wire representation. Performs no I/O.".
-spec to_map(row()) -> map().
to_map(Row = #session{}) -> #{id => Row#session.id, name => Row#session.name, attached_count => Row#session.attached_count, attached => Row#session.attached, created => Row#session.created};
to_map(Row = #window{}) -> #{id => Row#window.id, name => Row#window.name, width => Row#window.width, height => Row#window.height, pane_count => Row#window.pane_count, layout => Row#window.layout};
to_map(Row = #window_link{}) -> #{session_id => Row#window_link.session_id, window_id => Row#window_link.window_id, index => Row#window_link.index, active => Row#window_link.active};
to_map(Row = #pane{}) -> #{id => Row#pane.id, window_id => Row#pane.window_id, index => Row#pane.index, active => Row#pane.active, current_command => Row#pane.current_command, current_path => Row#pane.current_path, width => Row#pane.width, height => Row#pane.height, pid => Row#pane.pid, title => Row#pane.title, dead => Row#pane.dead, exit_status => Row#pane.exit_status}.

-doc "Read a permitted domain field without I/O. Unknown fields raise unknown_field; unloaded and unavailable values remain distinct.".
-spec get(atom(), row()) -> term().
get(id, #session{id = Value}) -> Value;
get(name, #session{name = Value}) -> Value;
get(attached_count, #session{attached_count = Value}) -> Value;
get(attached, #session{attached = Value}) -> Value;
get(created, #session{created = Value}) -> Value;
get(id, #window{id = Value}) -> Value;
get(name, #window{name = Value}) -> Value;
get(width, #window{width = Value}) -> Value;
get(height, #window{height = Value}) -> Value;
get(pane_count, #window{pane_count = Value}) -> Value;
get(layout, #window{layout = Value}) -> Value;
get(session_id, #window_link{session_id = Value}) -> Value;
get(window_id, #window_link{window_id = Value}) -> Value;
get(index, #window_link{index = Value}) -> Value;
get(active, #window_link{active = Value}) -> Value;
get(id, #pane{id = Value}) -> Value;
get(window_id, #pane{window_id = Value}) -> Value;
get(index, #pane{index = Value}) -> Value;
get(active, #pane{active = Value}) -> Value;
get(current_command, #pane{current_command = Value}) -> Value;
get(current_path, #pane{current_path = Value}) -> Value;
get(width, #pane{width = Value}) -> Value;
get(height, #pane{height = Value}) -> Value;
get(pid, #pane{pid = Value}) -> Value;
get(title, #pane{title = Value}) -> Value;
get(dead, #pane{dead = Value}) -> Value;
get(exit_status, #pane{exit_status = Value}) -> Value;
get(Field, Row) -> error({unknown_field, entity(Row), Field}).

-doc false.
-spec bind(row(), reference(), reference()) -> row().
bind(Row = #session{}, Origin, Snapshot)
  when is_reference(Origin), is_reference(Snapshot) ->
    {ok, Row} = validate(Row),
    Row#session{origin = Origin, snapshot_id = Snapshot};
bind(Row = #window{}, Origin, Snapshot)
  when is_reference(Origin), is_reference(Snapshot) ->
    {ok, Row} = validate(Row),
    Row#window{origin = Origin, snapshot_id = Snapshot};
bind(Row = #window_link{}, Origin, Snapshot)
  when is_reference(Origin), is_reference(Snapshot) ->
    {ok, Row} = validate(Row),
    Row#window_link{origin = Origin, snapshot_id = Snapshot};
bind(Row = #pane{}, Origin, Snapshot)
  when is_reference(Origin), is_reference(Snapshot) ->
    {ok, Row} = validate(Row),
    Row#pane{origin = Origin, snapshot_id = Snapshot}.

row_metadata(#session{model_version = V, origin = O, snapshot_id = S}) ->
    {session, V, O, S};
row_metadata(#window{model_version = V, origin = O, snapshot_id = S}) ->
    {window, V, O, S};
row_metadata(#window_link{model_version = V, origin = O, snapshot_id = S}) ->
    {window_link, V, O, S};
row_metadata(#pane{model_version = V, origin = O, snapshot_id = S}) ->
    {pane, V, O, S};
row_metadata(_) -> invalid.

build(session, Fields) -> #session{
    id = maps:get(id, Fields),
    name = maps:get(name, Fields),
    attached_count = maps:get(attached_count, Fields),
    attached = maps:get(attached, Fields),
    created = maps:get(created, Fields)
};
build(window, Fields) -> #window{
    id = maps:get(id, Fields),
    name = maps:get(name, Fields),
    width = maps:get(width, Fields),
    height = maps:get(height, Fields),
    pane_count = maps:get(pane_count, Fields),
    layout = maps:get(layout, Fields)
};
build(window_link, Fields) -> #window_link{
    session_id = maps:get(session_id, Fields),
    window_id = maps:get(window_id, Fields),
    index = maps:get(index, Fields),
    active = maps:get(active, Fields)
};
build(pane, Fields) -> #pane{
    id = maps:get(id, Fields),
    window_id = maps:get(window_id, Fields),
    index = maps:get(index, Fields),
    active = maps:get(active, Fields),
    current_command = maps:get(current_command, Fields),
    current_path = maps:get(current_path, Fields),
    width = maps:get(width, Fields),
    height = maps:get(height, Fields),
    pid = maps:get(pid, Fields),
    title = maps:get(title, Fields),
    dead = maps:get(dead, Fields),
    exit_status = maps:get(exit_status, Fields)
}.
