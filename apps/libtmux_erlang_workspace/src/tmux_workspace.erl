-module(tmux_workspace).
-moduledoc """
Load a versioned JSON workspace as validated, immutable desired state.

`load/1` reads a local file and resolves working directories. It uses
`tmux_json:decode/1` for bounded JSON, duplicate keys and exact numbers.
`to_map/1` exposes the normalized document for inspection. Neither call
contacts tmux, resolves an endpoint to a socket, or executes a launch.
Planning, applying changes and a workspace CLI are not implemented here.

Version 1 requires `version`, `endpoint` and nonempty `sessions`. Sessions
require `name` and `windows`; windows require `name` and `panes`, with optional
`layout`. Panes require exactly one of `argv` or `shell`; `cwd` defaults to
the workspace file's directory. Unknown fields fail validation. Shell text is
inert data: loading it does not authorize its later execution. No environment
interpolation occurs. Endpoint names must be resolved by host policy.

An optional document `id` makes identity independent of its filename.
Otherwise identity is SHA-256 of the canonical source filename. Every entity
accepts an optional `key`; omission uses its JSON pointer. Reordering entries
therefore changes derived keys. Keys are unique across the whole workspace.

The file limit is 256 KiB, JSON depth is 32, each collection has at most 64
entries and the document has at most 2048 entities. Launches have at most
256 argv elements and 32 KiB of encoded arguments. Text must be UTF-8 without
NUL bytes. IDs and keys have at most 128 bytes; names have at most 256 bytes.
Layouts are the five standard named tmux layouts. Names exclude controls and
backslashes; session names also exclude `.` and `:`, which tmux rewrites.

Source and working-directory paths resolve symlinks before parent components,
with at most 40 symlink traversals per path. Working directories must exist.
Filesystem calls are synchronous and have no I/O deadline. Checks assume a
trusted local filesystem; concurrent replacement of files or directories is
not an atomic snapshot or a filesystem sandbox. Errors contain a basename
and a JSON path rather than disclosing the full source filename.
""".
-include_lib("kernel/include/file.hrl").
-export([load/1, to_map/1]).
-export_type([t/0, document/0, session/0, window/0, pane/0, error/0]).
-define(MAX_BYTES, 262144).

-doc "A validated workspace value returned by `load/1`; inspect it with `to_map/1`.".
-opaque t() :: {workspace, document()}.
-doc "Normalized desired state. endpoint is a host-configuration key, not a socket.".
-type document() :: #{version := 1, id := binary(), endpoint := binary(),
                      sessions := nonempty_list(session())}.
-doc "One desired session with a workspace-wide stable key and ordered windows.".
-type session() :: #{key := binary(), name := binary(),
                     windows := nonempty_list(window())}.
-doc "One desired window. An omitted layout leaves that property unmanaged.".
-type window() :: #{key := binary(), name := binary(), layout => binary(),
                    panes := nonempty_list(pane())}.
-doc "One desired pane with a canonical cwd and an explicit, inert launch specification.".
-type pane() :: #{key := binary(), cwd := binary(),
                  launch := #{argv := nonempty_list(binary())} | #{shell := binary()}}.
-doc "Validation or filesystem failure. path uses binary field names and zero-based array indexes.".
-type error() :: #{code := atom(), path := [binary() | non_neg_integer()],
                   file => binary(), reason => atom(), limit => non_neg_integer()}.

-doc """
Read and validate a regular UTF-8 JSON file. Performs filesystem I/O only.

Accepts a UTF-8 filename binary or Unicode character list. The loader reads
at most 256 KiB plus one overflow byte and closes its file on every result.
Relative cwd values use the canonical source directory, not the caller's
working directory. `t:error/0` distinguishes invalid schema, file errors,
oversized documents and missing working directories. No error adopts or
modifies a tmux resource.
""".
-spec load(file:filename_all()) -> {ok, t()} | {error, error()}.
load(Filename) ->
    try filename_binary(Filename) of
        Input ->
            Label = filename:basename(Input),
            try
                Source = canonical(Input, regular, [], file_error),
                Document = decoded(read_document(Source)),
                {ok, {workspace, document(Document, Source)}}
            catch
                throw:{workspace_error, Detail} -> {error, Detail#{file => Label}}
            end
    catch
        throw:{workspace_error, Detail} -> {error, Detail}
    end.

-doc """
Return the normalized `t:document/0` without I/O. Values remain immutable.
Canonical cwd values and launch text are retained for later planning; callers
decide whether those values are appropriate to display or persist.
""".
-spec to_map(t()) -> document().
to_map({workspace, Document}) -> Document.

filename_binary(Filename) when is_list(Filename); is_binary(Filename) ->
    try unicode:characters_to_binary(Filename) of
        Binary when is_binary(Binary), byte_size(Binary) > 0,
                    byte_size(Binary) =< 4096 ->
            case binary:match(Binary, <<0>>) of
                nomatch -> Binary;
                _ -> reject(invalid_file, [])
            end;
        _ -> reject(invalid_file, [])
    catch error:badarg -> reject(invalid_file, []) end;
filename_binary(_) -> reject(invalid_file, []).

read_document(Source) ->
    case file:read_file_info(Source) of
        {ok, #file_info{size = Size}} when Size > ?MAX_BYTES ->
            reject(document_limit, []);
        {ok, _} -> ok;
        {error, Reason} -> reject(file_error, [], Reason)
    end,
    case file:open(Source, [read, raw, binary]) of
        {ok, File} ->
            try
                case file:read_file_info(File) of
                    {ok, #file_info{type = regular}} -> ok;
                    {ok, _} -> reject(not_regular_file, []);
                    {error, R1} -> reject(file_error, [], R1)
                end,
                case file:read(File, ?MAX_BYTES + 1) of
                    {ok, Binary} when byte_size(Binary) =< ?MAX_BYTES -> Binary;
                    {ok, _} -> reject(document_limit, []);
                    eof -> <<>>;
                    {error, R2} -> reject(file_error, [], R2)
                end
            after ok = file:close(File) end;
        {error, Reason2} -> reject(file_error, [], Reason2)
    end.

decoded(Binary) ->
    case tmux_json:decode(Binary) of
        {ok, Value} -> Value;
        {error, Detail} -> throw({workspace_error, Detail})
    end.

document(Value, Source) ->
    Path = [],
    Map = object(Value, [<<"version">>, <<"id">>, <<"endpoint">>, <<"sessions">>], Path),
    case required(<<"version">>, Map, Path) of
        1 -> ok;
        _ -> reject(unsupported_version, [<<"version">>])
    end,
    Id = case maps:find(<<"id">>, Map) of
        {ok, Explicit} -> text(Explicit, 1, 128, [<<"id">>]);
        error -> binary:encode_hex(crypto:hash(sha256, Source), lowercase)
    end,
    Endpoint = text(required(<<"endpoint">>, Map, Path), 1, 128, [<<"endpoint">>]),
    {Sessions, _} = entities(required(<<"sessions">>, Map, Path), session,
                             [<<"sessions">>], filename:dirname(Source), #{}),
    #{version => 1, id => Id, endpoint => Endpoint, sessions => Sessions}.

entities(Values, Kind, Path, Directory, Seen) ->
    collection(Values, Path, 64),
    {Rows, {_Index, Keys}} = lists:mapfoldl(fun(Value, {Index, Keys0}) ->
        {Row, Keys1} = entity(Kind, Value, Path ++ [Index], Directory, Keys0),
        {Row, {Index + 1, Keys1}}
    end, {0, Seen}, Values),
    {Rows, Keys}.

entity(Kind, Value, Path, Directory, Seen) ->
    Fields = case Kind of
        session -> [<<"key">>, <<"name">>, <<"windows">>];
        window -> [<<"key">>, <<"name">>, <<"layout">>, <<"panes">>];
        pane -> [<<"key">>, <<"cwd">>, <<"argv">>, <<"shell">>]
    end,
    Map = object(Value, Fields, Path),
    Key = case maps:find(<<"key">>, Map) of
        {ok, Explicit} -> text(Explicit, 1, 128, Path ++ [<<"key">>]);
        error -> pointer(Path)
    end,
    case maps:is_key(Key, Seen) of
        true -> reject(duplicate_key, Path ++ [<<"key">>]);
        false when map_size(Seen) >= 2048 -> reject(entity_limit, Path);
        false -> ok
    end,
    Keys = Seen#{Key => true},
    case Kind of
        pane ->
            CwdPath = Path ++ [<<"cwd">>],
            Cwd = text(maps:get(<<"cwd">>, Map, <<".">>), 1, 4096, CwdPath),
            Canonical = canonical(filename:absname(Cwd, Directory), directory,
                                  CwdPath, invalid_directory),
            {#{key => Key, cwd => Canonical, launch => launch(Map, Path)}, Keys};
        _ ->
            NamePath = Path ++ [<<"name">>],
            Name = name(required(<<"name">>, Map, Path), Kind, NamePath),
            {Field, ChildKind} = case Kind of
                session -> {<<"windows">>, window};
                window -> {<<"panes">>, pane}
            end,
            {Children, Keys1} = entities(required(Field, Map, Path), ChildKind,
                                        Path ++ [Field], Directory, Keys),
            Row = #{key => Key, name => Name},
            case Kind of
                session -> {Row#{windows => Children}, Keys1};
                window -> {layout(Map, Path, Row#{panes => Children}), Keys1}
            end
    end.

layout(Map, Path, Row) ->
    case maps:find(<<"layout">>, Map) of
        error -> Row;
        {ok, Value} ->
            case lists:member(Value, [<<"even-horizontal">>, <<"even-vertical">>,
                    <<"main-horizontal">>, <<"main-vertical">>, <<"tiled">>]) of
                true -> Row#{layout => Value};
                false -> reject(invalid_layout, Path ++ [<<"layout">>])
            end
    end.

launch(Map, Path) ->
    case {maps:find(<<"argv">>, Map), maps:find(<<"shell">>, Map)} of
        {{ok, Arguments}, error} ->
            ArgPath = Path ++ [<<"argv">>],
            collection(Arguments, ArgPath, 256),
            {Values, _} = lists:mapfoldl(fun(Value, Index) ->
                Min = case Index of 0 -> 1; _ -> 0 end,
                {text(Value, Min, 32768, ArgPath ++ [Index]), Index + 1}
            end, 0, Arguments),
            case lists:sum([byte_size(V) + 3 || V <- Values]) =< 32768 of
                true -> #{argv => Values};
                false -> reject(launch_limit, ArgPath)
            end;
        {error, {ok, Shell}} ->
            #{shell => text(Shell, 1, 32768, Path ++ [<<"shell">>])};
        {error, error} -> reject(missing_launch, Path);
        _ -> reject(ambiguous_launch, Path)
    end.

object(Value, Fields, Path) when is_map(Value) ->
    case lists:sort(maps:keys(maps:without(Fields, Value))) of
        [] -> Value;
        [Unknown | _] -> reject(unknown_field, Path ++ [Unknown])
    end;
object(_, _, Path) -> reject(expected_object, Path).

required(Field, Map, Path) ->
    case maps:find(Field, Map) of
        {ok, Value} -> Value;
        error -> reject(missing_field, Path ++ [Field])
    end.

collection(Values, Path, Max) ->
    case is_list(Values) andalso length(Values) > 0 andalso length(Values) =< Max of
        true -> ok;
        false -> reject(invalid_collection, Path)
    end.

text(Value, Min, Max, Path) when is_binary(Value), byte_size(Value) >= Min,
                                 byte_size(Value) =< Max ->
    case binary:match(Value, <<0>>) =:= nomatch andalso
         unicode:characters_to_binary(Value) =:= Value of
        true -> Value;
        false -> reject(invalid_text, Path)
    end;
text(_, _, _, Path) -> reject(invalid_text, Path).

name(Value, Kind, Path) ->
    Name = text(Value, 1, 256, Path),
    Characters = unicode:characters_to_list(Name),
    case lists:all(fun(C) ->
        C >= 32 andalso not (C >= 127 andalso C =< 159) andalso C =/= $\\ andalso
            (Kind =/= session orelse (C =/= $. andalso C =/= $:))
    end, Characters) of
        true -> Name;
        false -> reject(invalid_name, Path)
    end.

pointer(Path) ->
    iolist_to_binary([[<<"/">>, case Item of
        N when is_integer(N) -> integer_to_binary(N);
        Field -> Field
    end] || Item <- Path]).

canonical(Input, Kind, Path, Code) ->
    Absolute = case filename:pathtype(Input) of
        absolute -> Input;
        relative ->
            case file:get_cwd() of
                {ok, Cwd} -> filename:absname(Input, Cwd);
                {error, CwdReason} -> reject(Code, Path, CwdReason)
            end
    end,
    [<<"/">> | Parts] = filename:split(Absolute),
    Resolved = resolve(Parts, <<"/">>, 0, Path, Code),
    case file:read_file_info(Resolved) of
        {ok, #file_info{type = Kind}} -> Resolved;
        {ok, _} when Kind =:= regular -> reject(not_regular_file, Path);
        {ok, _} -> reject(Code, Path, enotdir);
        {error, Reason} -> reject(Code, Path, Reason)
    end.

resolve([], Current, _, _, _) -> Current;
resolve([<<".">> | Rest], Current, Links, Path, Code) ->
    resolve(Rest, Current, Links, Path, Code);
resolve([<<"..">> | Rest], Current, Links, Path, Code) ->
    resolve(Rest, filename:dirname(Current), Links, Path, Code);
resolve([Part | Rest], Current, Links, Path, Code) ->
    Next = filename:join(Current, Part),
    case file:read_link_info(Next) of
        {ok, #file_info{type = symlink}} when Links >= 40 -> reject(Code, Path, eloop);
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Next) of
                {ok, Target} ->
                    [<<"/">> | Parts] = filename:split(filename:absname(Target, Current)),
                    resolve(Parts ++ Rest, <<"/">>, Links + 1, Path, Code);
                {error, Reason} -> reject(Code, Path, Reason)
            end;
        {ok, #file_info{type = directory}} -> resolve(Rest, Next, Links, Path, Code);
        {ok, _} when Rest =:= [] -> Next;
        {ok, _} -> reject(Code, Path, enotdir);
        {error, Reason} -> reject(Code, Path, Reason)
    end.

-spec reject(atom(), [term()]) -> no_return().
reject(Code, Path) -> throw({workspace_error, #{code => Code, path => Path}}).
-spec reject(atom(), [term()], atom()) -> no_return().
reject(Code, Path, Reason) ->
    throw({workspace_error, #{code => Code, path => Path, reason => Reason}}).
