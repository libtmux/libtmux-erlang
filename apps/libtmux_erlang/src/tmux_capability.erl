-module(tmux_capability).
-moduledoc """
Look up native command declarations and feature requirements.

`commands/1` and `command/2` look up declarations by canonical name in the
source profiles in `profiles/0`. The profiles cover the supported tmux
3.3a–3.8 releases. Use `tmux_command:raw/2` to send an explicit trusted command.

`describe/1` reports the minimum release and older-daemon behavior for each
feature. Read the daemon version captured by the endpoint with
`tmux_server:version/1`, then pass it to `decision/2` or `require/2`. Operations
verify the endpoint before dispatch. A minimum check compares versions only.

`manifest/0` lists the operation gates. See the
[command reference](commands-reference.md) for the pinned source profiles.
""".
-export([profiles/0, commands/1, command/2, features/0, describe/1,
         decision/2, require/2, manifest/0]).
-export_type([feature/0, feature_info/0, command_info/0]).

-doc "Native capabilities described by this library.".
-type feature() :: native_list_filter | send_client_keys | key_list_format | layout_json |
    paste_sanitize | cleaned_names | rename_replaces | strict_named_target | control_no_detach |
    control_stream | program_history | pane_exit_events.
-doc """
The minimum release, public APIs and native commands. `handling` reports
refusal, fallback, or a native behavior difference. `versions` lists the
source profiles used to derive the minimum where available. `decision/2`
adds `supported` for the requested daemon version.
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
Unknown features return `unknown_capability`. `decision/2` applies the
minimum to a parsed version. For source-derived features the minimum names
the first sampled release with the feature.
""".
-spec describe(feature()) -> {ok, feature_info()} | {error, map()}.
describe(Feature) ->
    case maps:find(Feature, registry()) of
        {ok, Info} -> {ok, Info};
        error -> {error, #{code => unknown_capability, capability => Feature}}
    end.

-doc """
Return feature metadata with a `supported` boolean for the supplied version.
When `supported` is false, `handling` says how calls behave below the minimum.
This is a pure version comparison.

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
An older version returns `unsupported_capability` with the feature name,
`found`, `required` and a `hint`. `minimum` also holds the required release.
Development builds and RCs precede the corresponding stable release.
Unknown features and malformed parsed versions return distinct errors.

```erlang
1> {ok, V} = tmux_version:parse(<<"tmux 3.3a">>), ok.
ok
2> {error, Detail} = tmux_capability:require(V, send_client_keys), ok.
ok
3> maps:with([found, required], Detail).
#{found => <<"3.3a">>,required => <<"3.4">>}
```
""".
-spec require(tmux_version:t(), feature()) -> ok | {error, map()}.
require(Version, Feature) ->
    maybe
        {ok, #{minimum := Minimum, supported := Supported}} ?= decision(Version, Feature),
        case Supported of
            true -> ok;
            false -> {error, #{code => unsupported_capability,
                capability => Feature, minimum => Minimum,
                found => tmux_version:format(Version), required => Minimum,
                hint => <<"Use a tmux daemon at or above the required release.">>}}
        end
    end.

-doc """
Return the operation gates as a JSON-compatible map. The runtime floor applies
independently of each feature minimum.
""".
-spec manifest() -> map().
manifest() ->
    #{schema => <<"libtmux-capabilities/1">>, port => <<"erlang">>,
      floor => #{minimum => tmux_version:floor()},
      capabilities => [manifest_entry(Feature, Info) ||
          Feature <- features(), {ok, Info} <- [describe(Feature)],
          maps:get(handling, Info) =/= native_behavior]}.

manifest_entry(Feature, Info) ->
    #{minimum := Minimum, name := Name, description := Description,
      commands := Commands, flags := Flags, apis := Apis, handling := Handling} = Info,
    Entry = #{id => manifest_id(Feature),
        name => Name, summary => Description, since => Minimum, apis => Apis,
        handling => atom_to_binary(Handling),
        commands => [#{command => Command, flags => maps:get(Command, Flags, [])}
                     || Command <- Commands]},
    case Handling of
        refuse -> Entry#{error => <<"unsupported_capability">>};
        fallback -> Entry#{fallback => maps:get(fallback, Info)}
    end.

manifest_id(key_list_format) -> <<"list-keys-format">>;
manifest_id(control_no_detach) -> <<"control-no-detach-on-destroy">>;
manifest_id(Feature) -> binary:replace(atom_to_binary(Feature), <<"_">>, <<"-">>, [global]).

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
      pane_exit_events => #{minimum => <<"3.8">>, name => <<"Native pane exit events">>,
          description => <<"Wait for a pane's native death event without changing hooks.">>,
          commands => [<<"wait-for">>],
          flags => #{<<"wait-for">> => [<<"-E">>, <<"-F">>, <<"-l">>]},
          apis => [<<"tmux_pane:wait_exit/2">>], handling => fallback,
          fallback => <<"supervised-pane-died-hook">>, versions => [<<"3.8">>]},
      program_history => #{minimum => <<"3.8">>, name => <<"Program history counters">>,
          description => <<"Report discarded lines in an owned program's final screen.">>,
          commands => [<<"display-message">>, <<"capture-pane">>],
          flags => #{<<"display-message">> => [<<"-F">>], <<"capture-pane">> => [<<"-C">>, <<"-P">>, <<"-S">>]},
          apis => [<<"tmux_program:run/3">>, <<"tmux_program:start/3">>],
          handling => refuse, versions => [<<"3.8">>]},
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
          description => <<"Return an error when a named buffer is missing.">>,
          commands => [<<"delete-buffer">>, <<"set-buffer">>],
          flags => #{<<"delete-buffer">> => [<<"-b">>],
                    <<"set-buffer">> => [<<"-b">>, <<"-n">>]},
          apis => [<<"tmux_buffer:delete/2">>, <<"tmux_buffer:rename/3">>],
          handling => fallback, fallback => <<"show-buffer-before-named-operation">>},
      control_stream => #{minimum => <<"3.3a">>, name => <<"Pane output and notifications">>,
          description => <<"Read live pane bytes and events on an owned or borrowed endpoint.">>,
          commands => [<<"attach-session">>, <<"display-message">>],
          flags => #{<<"attach-session">> => [<<"-E">>, <<"-f">>], <<"display-message">> => [<<"-p">>]},
          apis => [<<"tmux_stream:subscribe/3">>], handling => refuse},
      control_no_detach => #{minimum => <<"3.6">>, name => <<"Control session switching">>,
          description => <<"Keep a control client attached when its session is destroyed.">>,
          commands => [<<"attach-session">>], flags => #{<<"attach-session">> => [<<"-f">>]},
          apis => [<<"tmux_control:attach/3">>], handling => fallback,
          fallback => <<"omit-no-detach-on-destroy">>}}.

native_feature(Feature, Name, Apis, Flags) ->
    Data = maps:get(features, tmux_capability_data:all()),
    #{versions := [Minimum | _]} = Info = maps:get(atom_to_binary(Feature), Data),
    Info#{minimum => Minimum,
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
