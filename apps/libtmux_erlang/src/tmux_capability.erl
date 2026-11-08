-module(tmux_capability).
-moduledoc """
Look up source-derived native command declarations and feature minimums.

`commands/1` and `command/2` describe the exact source profiles in `profiles/0`.
They do not contact tmux, interpret its arguments or qualify another build.
Canonical command names are lookup keys; aliases remain metadata. A native
declaration does not mean this library provides a typed facade for it. Use
`tmux_command:raw/2` for an explicit trusted command.

`describe/1` reports selected native feature minimums. `require/2` compares a
parsed version with one of those minimums; it does not perform I/O or dispatch
the command. Numeric minimum checks also accept uncatalogued and tracking
versions, preserving the distinction from exact parser discovery. They do not
establish runtime or CI qualification. Use `tmux_server:version/1` to obtain the
version captured by a registered endpoint.

The [generated reference](commands-reference.md) records source profiles and
parser declarations. Maintaining the catalogue needs a tmux source checkout;
installed consumers use compiled data and OTP only.
""".
-export([profiles/0, commands/1, command/2, describe/1, require/2]).
-export_type([feature/0, feature_info/0, command_info/0]).

-doc "Selected native capabilities; these do not introduce new typed command options.".
-type feature() :: native_list_filter | send_client_keys | key_list_format | layout_json.
-doc "Source-sampled profiles, native commands, description and numeric minimum.".
-type feature_info() :: #{minimum := {non_neg_integer(), non_neg_integer()},
    commands := [binary()], description := binary(), versions := [binary()]}.
-doc """
Native alias, flag declaration and positional bounds, with the exact source
file, commit and SHA-256. none means no alias or an unbounded positional upper
limit. Additional argument callbacks and runtime checks remain tmux's concern.
""".
-type command_info() :: #{alias := binary() | none, argument_spec := binary(),
    min_args := non_neg_integer(), max_args := non_neg_integer() | none,
    source := #{file := binary(), commit := binary(), sha256 := binary()}}.

-doc "List the exact source profile names in catalogue order. Performs no I/O.".
-spec profiles() -> [binary()].
profiles() -> maps:get(versions, tmux_capability_data:all()).

-doc """
Return sorted canonical command names for an exact catalogued stable version.
Tracking and uncatalogued versions return unsupported_command_catalogue.
This is pure source discovery; it does not execute list-commands.
""".
-spec commands(tmux_version:t()) -> {ok, [binary()]} | {error, map()}.
commands(Version) ->
    maybe
        {ok, Profile} ?= profile(Version),
        Data = maps:get(commands, tmux_capability_data:all()),
        {ok, lists:sort([Name || {Name, Variants} <- maps:to_list(Data),
            variant(Profile, Variants) =/= none])}
    end.

-doc """
Look up one canonical native command in an exact source profile. Returns
unknown_command for aliases or unknown names, unsupported_command when a
known command is absent from that profile, and unsupported_command_catalogue
for uncatalogued or tracking versions. Performs no I/O.

```erlang
1> {ok, V} = tmux_version:parse(<<"tmux 3.3">>), ok.
ok
2> {ok, C} = tmux_capability:command(V, <<"send-keys">>), ok.
ok
3> maps:get(file, maps:get(source, C)).
<<"cmd-send-keys.c">>
```
""".
-spec command(tmux_version:t(), binary()) -> {ok, command_info()} | {error, map()}.
command(Version, Name) ->
    maybe
        {ok, Profile} ?= profile(Version),
        Data = tmux_capability_data:all(),
        case maps:find(Name, maps:get(commands, Data)) of
            error -> {error, #{code => unknown_command, command => Name}};
            {ok, Variants} -> case variant(Profile, Variants) of
                none -> {error, #{code => unsupported_command,
                    command => Name, version => Profile}};
                {ok, Metadata} ->
                    File = maps:get(file, Metadata),
                    Source = maps:get(Profile, maps:get(sources, Data)),
                    {ok, (maps:remove(file, Metadata))#{source => #{file => File,
                        commit => maps:get(commit, Source),
                        sha256 => maps:get(File, maps:get(files, Source))}}}
            end
        end
    end.

-doc """
Return a selected native feature's source-derived minimum and sampled
profiles. Unknown features return unknown_capability. Performs no I/O;
`require/2` applies the minimum to a parsed version.
""".
-spec describe(feature()) -> {ok, feature_info()} | {error, map()}.
describe(Feature) when is_atom(Feature) ->
    Features = maps:get(features, tmux_capability_data:all()),
    case maps:find(atom_to_binary(Feature, utf8), Features) of
        {ok, #{minimum := [Major, Minor]} = Info} ->
            {ok, Info#{minimum => {Major, Minor}}};
        error -> {error, #{code => unknown_capability, capability => Feature}}
    end;
describe(Feature) -> {error, #{code => unknown_capability, capability => Feature}}.

-doc """
Require a native feature's numeric major/minor floor without dispatching I/O.
An older version returns unsupported_capability with capability and minimum.
Patch letters and tracking markers do not promote an older minor version.
Unknown features and malformed parsed versions return distinct errors.

```erlang
1> {ok, V} = tmux_version:parse(<<"tmux 3.4">>), ok.
ok
2> tmux_capability:require(V, send_client_keys).
ok
```
""".
-spec require(tmux_version:t(), feature()) -> ok | {error, map()}.
require(Version, Feature) ->
    maybe
        ok ?= valid_version(Version),
        {ok, #{minimum := Minimum}} ?= describe(Feature),
        case tmux_version:at_least(Version, Minimum) of
            true -> ok;
            false -> {error, #{code => unsupported_capability,
                capability => Feature, minimum => Minimum}}
        end
    end.

variant(_, []) -> none;
variant(Profile, [#{versions := Versions, metadata := Metadata} | Rest]) ->
    case lists:member(Profile, Versions) of
        true -> {ok, Metadata};
        false -> variant(Profile, Rest)
    end.

profile(Version) ->
    maybe
        ok ?= valid_version(Version),
        #{major := Major, minor := Minor, patch := Patch, tracking := Tracking} = Version,
        Prefix = case Tracking of true -> <<"next-">>; false -> <<>> end,
        Profile = <<Prefix/binary, (integer_to_binary(Major))/binary, $.,
            (integer_to_binary(Minor))/binary, Patch/binary>>,
        case lists:member(Profile, profiles()) of
            true -> {ok, Profile};
            false -> {error, #{code => unsupported_command_catalogue, version => Profile}}
        end
    end.

valid_version(#{major := Major, minor := Minor, patch := Patch, tracking := Tracking})
  when is_integer(Major), Major >= 0, is_integer(Minor), Minor >= 0,
       is_boolean(Tracking) ->
    case Patch of
        <<>> -> ok;
        <<C>> when C >= $a, C =< $z -> ok;
        _ -> {error, #{code => invalid_version}}
    end;
valid_version(_) -> {error, #{code => invalid_version}}.
