-module(tmux_capability).
-moduledoc """
Look up source-derived native command declarations and feature minimums.

`commands/1` and `command/2` describe the exact source profiles in `profiles/0`.
Profiles cover every release in the supported tmux 3.3a–3.8 range. They do not
contact tmux, interpret its arguments or qualify another build.
Canonical command names are lookup keys; aliases remain metadata. A native
declaration does not mean this library provides a typed facade for it. Use
`tmux_command:raw/2` for an explicit trusted command.

`features/0` lists the names accepted by `describe/1` and `decision/2`.
`describe/1` reports feature minimums and older-daemon behavior. `require/2` compares a
parsed version with one of those minimums; it does not perform I/O or dispatch
the command. Minimum checks accept uncatalogued releases but rank tracking
builds and release candidates below the corresponding stable release. They do not
establish runtime or CI qualification. Use `tmux_server:version/1` to obtain the
version captured by a registered endpoint; this cached value is not a fresh
liveness check. Operations still verify their endpoint before dispatch.

`manifest/0` describes operation gates for documentation consumers. Native
buffer-name and rename behavior is available through `decision/2` but is not
an operation gate. These informational entries are omitted from the manifest.

The [generated reference](commands-reference.md) records source profiles and
parser declarations. Maintaining the catalogue needs a tmux source checkout;
installed consumers use compiled data and OTP only.
""".
-export([profiles/0, commands/1, command/2, features/0, describe/1,
         decision/2, require/2, manifest/0]).
-export_type([feature/0, feature_info/0, command_info/0]).

-doc "Selected native capabilities; these do not introduce new typed command options.".
-type feature() :: native_list_filter | send_client_keys | key_list_format | layout_json |
    paste_sanitize | cleaned_names | rename_replaces | strict_named_target | control_no_detach.
-doc """
The minimum release spelling, public API names and native commands. handling is
refuse, fallback or native_behavior; the latter describes an observed native
rule rather than a library admission gate. versions lists sampled source
profiles when the command catalogue derives the minimum. It is not a list of
runtime-qualified releases. fallback names the older-daemon path when present.
decision/2 also supplies supported; describe/1 leaves that field absent.
""".
-type feature_info() :: #{minimum := binary(), name := binary(),
    commands := [binary()], description := binary(), apis := [binary()],
    handling := refuse | fallback | native_behavior,
    flags := #{binary() => [binary()]}, versions => [binary()], fallback => binary(),
    supported => boolean()}.
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

-doc "Return the sorted names accepted by describe/1 and decision/2. Performs no I/O.".
-spec features() -> [feature()].
features() -> lists:sort(maps:keys(registry())).

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
1> {ok, V} = tmux_version:parse(<<"tmux 3.3a">>), ok.
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
Return a feature's minimum, affected APIs and behavior below that minimum.
Unknown features return unknown_capability. Performs no I/O; `decision/2`
applies the minimum to a parsed version. Native catalogue entries name their
first sampled release, not necessarily their historical upstream introduction.
""".
-spec describe(feature()) -> {ok, feature_info()} | {error, map()}.
describe(Feature) ->
    case maps:find(Feature, registry()) of
        {ok, Info} -> {ok, Info};
        error -> {error, #{code => unknown_capability, capability => Feature}}
    end.

-doc """
Return feature metadata with a supported boolean for the supplied version.
An unsupported flag can have an older-daemon fallback; inspect handling.
Unknown features and malformed versions return distinct errors. Performs no
I/O and grants no authority to operate on a server.

```erlang
1> {ok, V} = tmux_version:parse(<<"tmux 3.3a">>), ok.
ok
2> {ok, Info} = tmux_capability:decision(V, control_no_detach), ok.
ok
3> maps:with([supported, handling], Info).
#{handling => fallback,supported => false}
```
""".
-spec decision(tmux_version:t(), feature()) ->
    {ok, feature_info()} | {error, map()}.
decision(Version, Feature) ->
    maybe
        ok ?= valid_version(Version),
        {ok, #{minimum := Minimum} = Info} ?= describe(Feature),
        {ok, Info#{supported => tmux_version:at_least(Version, Minimum)}}
    end.

-doc """
Require a feature's release floor without dispatching I/O.
An older version returns unsupported_capability with capability and minimum.
Development builds and RCs precede the corresponding stable release.
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
        {ok, #{minimum := Minimum, supported := Supported}} ?= decision(Version, Feature),
        case Supported of
            true -> ok;
            false -> {error, #{code => unsupported_capability,
                capability => Feature, minimum => Minimum}}
        end
    end.

-doc """
Return the JSON-compatible operation-gate manifest without I/O. It uses the same
registry as decision/2 and require/2. Informational native_behavior entries are
excluded; the library floor applies independently of each feature minimum.
""".
-spec manifest() -> map().
manifest() ->
    #{schema => <<"libtmux-capabilities/1">>, port => <<"erlang">>,
      floor => #{minimum => <<"3.3a">>},
      capabilities => [manifest_entry(Feature, Info) ||
          Feature <- features(), {ok, Info} <- [describe(Feature)],
          maps:get(handling, Info) =/= native_behavior]}.

manifest_entry(Feature, Info) ->
    #{minimum := Minimum, name := Name, description := Description,
      commands := Commands, flags := Flags, apis := Apis, handling := Handling} = Info,
    Entry = #{id => binary:replace(atom_to_binary(Feature), <<"_">>, <<"-">>, [global]),
        name => Name, summary => Description, since => Minimum, apis => Apis,
        handling => atom_to_binary(Handling),
        error => case Handling of refuse -> <<"unsupported_capability">>; fallback -> false end,
        commands => [#{command => Command, flags => maps:get(Command, Flags, [])}
                     || Command <- Commands]},
    maps:merge(Entry, maps:with([fallback], Info)).

registry() ->
    #{native_list_filter => native_feature(native_list_filter, <<"Native list filters">>,
          [<<"tmux_capability:require/2">>],
          #{<<"list-sessions">> => [<<"-f">>], <<"list-windows">> => [<<"-f">>],
            <<"list-panes">> => [<<"-f">>]}),
      send_client_keys => native_feature(send_client_keys, <<"Client-directed keys">>,
          [<<"tmux_capability:require/2">>], #{<<"send-keys">> => [<<"-K">>, <<"-c">>]}),
      key_list_format => native_feature(key_list_format, <<"Formatted key listings">>,
          [<<"tmux_capability:require/2">>], #{<<"list-keys">> => [<<"-F">>]}),
      layout_json => native_feature(layout_json, <<"JSON window layouts">>,
          [<<"tmux_window:select_layout/2">>, <<"tmux_capability:require/2">>], #{}),
      paste_sanitize => #{minimum => <<"3.7">>, name => <<"Paste sanitization">>,
          description => <<"Request native paste sanitization; raw paste uses -S on newer daemons.">>,
          commands => [<<"paste-buffer">>], flags => #{<<"paste-buffer">> => [<<"-S">>]},
          apis => [<<"tmux_buffer:paste/3">>], handling => refuse},
      cleaned_names => #{minimum => <<"3.7">>, name => <<"Cleaned buffer names">>,
          description => <<"The daemon cleans buffer names before storing them.">>,
          commands => [<<"load-buffer">>], flags => #{},
          apis => [<<"tmux_buffer:capabilities/1">>], handling => native_behavior},
      rename_replaces => #{minimum => <<"3.4">>, name => <<"Replacing buffer names">>,
          description => <<"Renaming a buffer can replace an existing destination.">>,
          commands => [<<"set-buffer">>], flags => #{<<"set-buffer">> => [<<"-n">>]},
          apis => [<<"tmux_buffer:rename/3">>], handling => native_behavior},
      strict_named_target => #{minimum => <<"3.4">>, name => <<"Strict named buffers">>,
          description => <<"A missing named buffer does not select the newest buffer.">>,
          commands => [<<"delete-buffer">>, <<"set-buffer">>], flags => #{},
          apis => [<<"tmux_buffer:delete/2">>, <<"tmux_buffer:rename/3">>],
          handling => fallback, fallback => <<"show-buffer-before-named-operation">>},
      control_no_detach => #{minimum => <<"3.6">>, name => <<"Control session switching">>,
          description => <<"Keep a control client attached when its session is destroyed.">>,
          commands => [<<"attach-session">>], flags => #{<<"attach-session">> => [<<"-f">>]},
          apis => [<<"tmux_control:attach/3">>], handling => fallback,
          fallback => <<"omit-no-detach-on-destroy">>}}.

native_feature(Feature, Name, Apis, Flags) ->
    Data = maps:get(features, tmux_capability_data:all()),
    #{minimum := [Major, Minor]} = Info = maps:get(atom_to_binary(Feature), Data),
    Info#{minimum => <<(integer_to_binary(Major))/binary, $., (integer_to_binary(Minor))/binary>>,
          name => Name, apis => Apis, flags => Flags, handling => refuse}.

variant(_, []) -> none;
variant(Profile, [#{versions := Versions, metadata := Metadata} | Rest]) ->
    case lists:member(Profile, Versions) of
        true -> {ok, Metadata};
        false -> variant(Profile, Rest)
    end.

profile(Version) ->
    maybe
        ok ?= valid_version(Version),
        Profile = tmux_version:format(Version),
        case lists:member(Profile, profiles()) of
            true -> {ok, Profile};
            false -> {error, #{code => unsupported_command_catalogue, version => Profile}}
        end
    end.

valid_version(#{major := Major, minor := Minor, patch := Patch, tracking := Tracking} = Version)
  when is_integer(Major), Major >= 0, is_integer(Minor), Minor >= 0,
       is_boolean(Tracking) ->
    case {Tracking, Patch, maps:get(candidate, Version, none)} of
        {_, <<>>, none} -> ok;
        {false, <<>>, Candidate} when is_integer(Candidate), Candidate > 0 -> ok;
        {false, <<C>>, none} when C >= $a, C =< $z -> ok;
        _ -> {error, #{code => invalid_version}}
    end;
valid_version(_) -> {error, #{code => invalid_version}}.
