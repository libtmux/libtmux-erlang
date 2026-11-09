-module(tmux_option).
-moduledoc """
Read and change explicit tmux option tables through registered references.

Session, physical window and pane records from `m:tmux_model` select their
local tables. Global tables use {server, Server}, {session_defaults, Server}
or {window_defaults, Server}. Built-in canonical names and scopes are checked
against pinned source metadata; tmux otherwise lets a name override the
supplied scope flags. `m:tmux_hook` owns hook registration and execution;
hooks are rejected here. Prefixes and aliases are rejected.

`get/3` requires an explicit options map. Local-only reads are the
default; inherit = true follows tmux's table parents (pane -> window -> window
defaults, or session -> session defaults). Server options have no parent. A
missing local value or array entry returns none; an empty binary or empty
array is a value. Arrays return maps of indexes to binary values, preserving
sparse indexes. There is no hidden capture refresh or cache of option values.
`get_many/3` reads the same scalar key from up to seven local rows through one
bounded native sequence, retaining local-only semantics by default.

Values are NUL-free binary tmux text bytes, including non-UTF-8 bytes. No
shell or format expansion is applied by this API. tmux still interprets a
built-in option according to its type: formats, shell commands and command
options may execute later when tmux uses them. This API is for trusted
application code. Numeric and flag values are canonical binary text on reads,
not Erlang numbers.

Built-in metadata covers every released version in the supported tmux
3.3a–3.8 range, including exact patch letters. Tracking and unknown versions
fail closed. User options beginning @ do not need a built-in
catalogue. The raw `tmux_command:raw/2` remains available for deliberate
newer-server integration. All mutations are one-shot I/O with observed
identity checks, not transactions. Timeouts can leave an unknown remote
outcome; mutations are never retried here. See the [scoped options
guide](options.md) for ownership and inheritance.
""".
-export([get/3, get_many/3, set/3, set/4, unset/2, describe/2, catalogue/1]).
-export_type([scope/0, key/0, metadata/0, read_options/0, write_options/0, value/0]).

-doc "A registered local entity or an explicitly selected global option table.".
-type scope() :: tmux_model:session() | tmux_model:window() | tmux_model:pane() |
    {server | session_defaults | window_defaults, tmux_server:t()}.
-doc "Canonical binary name; arrays use a structured non-negative index, never bracket syntax.".
-type key() :: binary() | {binary(), non_neg_integer()}.
-doc "Source-derived scope, parser type, array and executable-hook metadata.".
-type metadata() :: #{scopes := [server | session | window | pane],
    type := choice | colour | command | flag | key | number | string,
    array := boolean(), hook := boolean()}.
-doc "Local-only unless inherit is true. Unknown options and non-Booleans are errors.".
-type read_options() :: #{inherit => boolean()}.
-doc "append maps to -a; only_if_unset maps to -o and reports already-set errors. Both default false.".
-type write_options() :: #{append => boolean(), only_if_unset => boolean()}.
-doc "Canonical tmux text bytes for a scalar/entry, or a sparse map for a whole array.".
-type value() :: binary() | #{non_neg_integer() => binary()}.

-doc """
Return source metadata for a canonical built-in name and a parsed daemon
version, without I/O. Unknown names, unavailable names, tracking builds and
uncatalogued versions have distinct errors. The catalogue describes scopes and
parser types; it does not qualify runtime behavior or authorize hook
execution.

```erlang
1> {ok, V} = tmux_version:parse(<<"tmux 3.3a">>), ok.
ok
2> {ok, M} = tmux_option:describe(V, <<"exit-empty">>), ok.
ok
3> maps:get(scopes, M).
[server]
```
""".
-spec describe(tmux_version:t(), binary()) -> {ok, metadata()} | {error, map()}.
describe(Version, Name) ->
    maybe
        {ok, Profile} ?= profile(Version),
        case tmux_option_data:variants(Name) of
            [] -> {error, #{code => unknown_tmux_option, name => Name}};
            Variants -> find(Profile, Name, Variants)
        end
    end.

-doc """
Return all canonical built-in option and hook metadata for one exact parsed
version, without I/O. Catalogues cover every release from 3.3a through 3.8;
historical 3.3 metadata remains available for source discovery. The generated
reference records each release's source commit and file digests.
""".
-spec catalogue(tmux_version:t()) -> {ok, #{binary() => metadata()}} | {error, map()}.
catalogue(Version) ->
    maybe
        {ok, Profile} ?= profile(Version),
        {ok, maps:from_list([{Name, Meta} || Name <- tmux_option_data:names(),
            {ok, Meta} <- [find(Profile, Name, tmux_option_data:variants(Name))]])}
    end.

-doc """
Read one option or array, performing I/O after validation. Missing local
values and array entries return none; known empty strings and arrays return
{ok, Value}. inherit = true reads through tmux's parent tables. Unknown fields
are rejected. Errors retain backend diagnostics; a missing target never
becomes absence. Use `set/4` to write a value and `unset/2` to restore
inheritance.
""".
-spec get(scope(), key(), read_options()) -> {ok, value()} | none | {error, map()}.
get(Scope, Key, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options, [{inherit, flag, <<"-A">>}]),
        {ok, Server, ScopeArgs, Name, Index, Meta} ?= tmux_option_scope:prepare(Scope, Key, read, option),
        {ok, Literal} ?= tmux_command:literal_format(Name),
        {ok, Version} ?= tmux_server:version(Server),
        Result = tmux_target:run(Server, <<"show-options">>,
            ScopeArgs ++ Flags ++ [<<"--">>, Literal]),
        read_result(Result, Name, Index, Meta, Version)
    end.

-doc """
Read one scalar option from one to seven local rows on the same registered
endpoint. Performs one bounded native sequence after validating every scope.
Results follow input order; each entry is binary text or none for a missing
local value. `t:read_options/0` controls inheritance as in `get/3`.

Names use ASCII letters, digits, dots, underscores and hyphens, with an
optional leading @ for user options. Global tables, arrays, indexed keys,
hooks and command options are unsupported. Use `get/3` for broader option
reads and `tmux_hook:get/3` for hooks.
Invalid scopes, unsupported keys and different owners fail before dispatch.

Each read is bracketed by matching native target-ID observations. Unresolved
or mismatched IDs reject the batch. The checks do not prove topology membership
or completed destruction: older tmux may retain an unlinked pane through
queued references. The sequence provides interval observations and the same
server-incarnation guarantee as `get/3`. Ambient command configuration applies
to both paths.

Stdout is bounded to 1 MiB and stderr to 64 KiB for the whole sequence, with
the endpoint's 2500 ms command deadline. Seven 32 KiB values fit even under
the qualified worst-case native quoting expansion. Larger external values
may exceed that aggregate output bound. Any command, framing or decoding
failure rejects the entire result, retaining native outcome and cleanup
evidence. There is no partial-success result, hidden refresh or value cache.
""".
-spec get_many(nonempty_list(tmux_model:session() | tmux_model:window() |
    tmux_model:pane()), binary(), read_options()) ->
    {ok, [binary() | none]} | {error, map()}.
get_many(Scopes, Name, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options, [{inherit, flag, <<"-A">>}]),
        {ok, Server, Command, Rows} ?= tmux_option_batch:prepare(Scopes, Name, Flags),
        {ok, Version} ?= tmux_server:version(Server),
        {ok, Result} ?= tmux_server:command(Server, Command, #{}),
        case tmux_option_batch:decode(Name, maps:get(stdout, Result), Rows, Version) of
            {ok, _} = Success -> Success;
            {error, Error} -> {error, maps:merge(Result, Error)}
        end
    end.

-doc """
Set one scalar or indexed array entry with default write options. Performs
I/O; see `set/4` for append, only-if-unset, parsing and unknown-outcome
semantics.
""".
-spec set(scope(), key(), binary()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
set(Scope, Key, Value) -> set(Scope, Key, Value, #{}).

-doc """
Set a literal binary value, after scope/version/owner validation. Array writes
require {Name, Index}; this avoids tmux's whole-array separator grammar.
append uses tmux's type-specific -a semantics. only_if_unset checks the local
table; already-set is a backend error, with no suppressed errors or
compare-and-swap guarantee. Values must be supplied explicitly; an empty flag
value retains tmux's native toggle behavior. A successful result proves
command completion, not later effects of a stored command or format. Performs
I/O; never retries.
""".
-spec set(scope(), key(), binary(), write_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
set(Scope, Key, Value, Options) ->
    maybe
        ok ?= value(Value),
        {ok, Flags} ?= tmux_args:options(Options,
            [{append, flag, <<"-a">>}, {only_if_unset, flag, <<"-o">>}]),
        {ok, Server, ScopeArgs, Name, Index, _} ?= tmux_option_scope:prepare(Scope, Key, write, option),
        {ok, Literal} ?= tmux_command:literal_format(tmux_option_scope:indexed(Name, Index)),
        tmux_target:run(Server, <<"set-option">>,
            ScopeArgs ++ Flags ++ [<<"--">>, Literal, Value])
    end.

-doc """
Remove a local option or one indexed entry. Removing a local option restores
inheritance; removing an entry leaves a local array, possibly empty. Unsetting
a global built-in resets tmux's default; user options are removed. Missing
local values are a successful tmux no-op. No pane-wide -U action is implied.
Performs I/O and returns the command result without refreshing captured rows.
""".
-spec unset(scope(), key()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
unset(Scope, Key) ->
    maybe
        {ok, Server, ScopeArgs, Name, Index, _} ?= tmux_option_scope:prepare(Scope, Key, unset, option),
        {ok, Literal} ?= tmux_command:literal_format(tmux_option_scope:indexed(Name, Index)),
        tmux_target:run(Server, <<"set-option">>, ScopeArgs ++ [<<"-u">>, <<"--">>, Literal])
    end.

value(Value) when is_binary(Value), byte_size(Value) =< 32768 ->
    case binary:match(Value, <<0>>) of
        nomatch -> ok;
        _ -> {error, #{code => invalid_option_value}}
    end;
value(_) -> {error, #{code => invalid_option_value}}.

profile(#{major := Major, minor := Minor, patch := Patch, tracking := false}) ->
    Profile = <<(integer_to_binary(Major))/binary, $., (integer_to_binary(Minor))/binary, Patch/binary>>,
    case lists:member(Profile, tmux_option_data:versions()) of
        true -> {ok, Profile};
        false -> {error, #{code => unsupported_option_catalogue, version => Profile}}
    end;
profile(_) -> {error, #{code => unsupported_option_catalogue}}.

find(_, Name, []) -> {error, #{code => unsupported_tmux_option, name => Name}};
find(Profile, Name, [{Versions, Meta} | Rest]) ->
    case lists:member(Profile, Versions) of
        true -> {ok, Meta};
        false -> find(Profile, Name, Rest)
    end.

read_result({ok, #{stdout := Output}}, Name, Index, Meta, Version) ->
    case tmux_option_codec:decode(Name, Output, Meta, Version) of
        {ok, Entries} when is_map(Entries), Index =/= none ->
            case maps:find(Index, Entries) of {ok, Value} -> {ok, Value}; error -> none end;
        Result -> Result
    end;
read_result({error, #{code := command_error, stderr := Stderr}} = Error, <<$@, _/binary>> = Name, _, _, _) ->
    case Stderr =:= <<"invalid option: ", Name/binary, $\n>> of true -> none; false -> Error end;
read_result(Result, _, _, _, _) -> Result.
