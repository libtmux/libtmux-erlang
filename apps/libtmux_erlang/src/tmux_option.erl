-module(tmux_option).
-moduledoc """
Read and change explicit tmux option tables through registered references.

A session, physical window or pane selects its own local table. Global tables
use {server, Server}, {session_defaults, Server} or {window_defaults, Server}.
Built-in canonical names and scopes are checked against pinned source metadata;
tmux otherwise lets a name override the supplied scope flags. Hooks require a
separate command API and are rejected here. Prefixes and aliases are rejected.

get requires an explicit options map. Local-only reads are the default;
inherit = true follows tmux's table parents (pane -> window -> window defaults,
or session -> session defaults). Server options have no parent. A missing local
value or array entry returns none; an empty binary or empty array is a value.
Arrays return maps of indexes to binary values, preserving sparse indexes.
There is no hidden capture refresh or cache of option values.

Values are NUL-free binary tmux text bytes, including non-UTF-8 bytes. No shell
or format expansion is applied by this API. tmux still interprets a built-in
option according to its type: formats, shell commands and command options may
execute later when tmux uses them. This API is for trusted application code.
Numeric and flag values are canonical binary text on reads, not Erlang numbers.

Only the seven catalogue versions listed by `catalogue/1` are accepted for
built-ins, including exact patch letters; tracking and unknown versions fail
closed. User options beginning @ do not need a built-in catalogue. The raw
command API remains available for deliberate newer-server integration.
All mutations are one-shot I/O with observed identity checks, not transactions.
Timeouts can leave an unknown remote outcome; mutations are never retried here.
""".
-export([get/3, set/3, set/4, unset/2, describe/2, catalogue/1]).
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
Return source metadata for a canonical built-in name and a parsed daemon version,
without I/O. Unknown names, unavailable names, tracking builds and uncatalogued
versions have distinct errors. The catalogue describes scopes and parser types;
it does not qualify runtime behavior or authorize hook execution.

```erlang
1> {ok, V} = tmux_version:parse(<<"tmux 3.3">>), ok.
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
version, without I/O. Supported catalogues are 3.3, 3.3a, 3.4, 3.5a, 3.6b,
3.7c and 3.8. The generated reference records source commits and file digests.
""".
-spec catalogue(tmux_version:t()) -> {ok, #{binary() => metadata()}} | {error, map()}.
catalogue(Version) ->
    maybe
        {ok, Profile} ?= profile(Version),
        {ok, maps:from_list([{Name, Meta} || Name <- tmux_option_data:names(),
            {ok, Meta} <- [find(Profile, Name, tmux_option_data:variants(Name))]])}
    end.

-doc """
Read one option or array, performing I/O after validation. Missing local values
and array entries return none; known empty strings and arrays return {ok, Value}.
inherit = true reads through tmux's parent tables. Unknown fields are rejected.
Errors retain backend diagnostics; a missing target never becomes absence.
""".
-spec get(scope(), key(), read_options()) -> {ok, value()} | none | {error, map()}.
get(Scope, Key, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options, [{inherit, flag, <<"-A">>}]),
        {ok, Server, ScopeArgs, Name, Index, Meta} ?= prepare(Scope, Key, read),
        {ok, Literal} ?= tmux_command:literal_format(Name),
        {ok, Version} ?= tmux_server:version(Server),
        Result = tmux_target:run(Server, <<"show-options">>,
            ScopeArgs ++ Flags ++ [<<"--">>, Literal]),
        read_result(Result, Name, Index, Meta, Version)
    end.

-doc """
Set one scalar or indexed array entry with default write options. Performs I/O;
see `set/4` for append, only-if-unset, parsing and unknown-outcome semantics.
""".
-spec set(scope(), key(), binary()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
set(Scope, Key, Value) -> set(Scope, Key, Value, #{}).

-doc """
Set a literal binary value, after scope/version/owner validation. Array writes
require {Name, Index}; this avoids tmux's whole-array separator grammar. append
uses tmux's type-specific -a semantics. only_if_unset checks the local table;
already-set is a backend error, with no suppressed errors or compare-and-swap
guarantee. Values must be supplied explicitly; an empty flag value retains
tmux's native toggle behavior. A successful result proves command completion,
not later effects of a stored command or format. Performs I/O; never retries.
""".
-spec set(scope(), key(), binary(), write_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
set(Scope, Key, Value, Options) ->
    maybe
        ok ?= value(Value),
        {ok, Flags} ?= tmux_args:options(Options,
            [{append, flag, <<"-a">>}, {only_if_unset, flag, <<"-o">>}]),
        {ok, Server, ScopeArgs, Name, Index, _} ?= prepare(Scope, Key, write),
        {ok, Literal} ?= tmux_command:literal_format(indexed(Name, Index)),
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
        {ok, Server, ScopeArgs, Name, Index, _} ?= prepare(Scope, Key, unset),
        {ok, Literal} ?= tmux_command:literal_format(indexed(Name, Index)),
        tmux_target:run(Server, <<"set-option">>, ScopeArgs ++ [<<"-u">>, <<"--">>, Literal])
    end.

prepare(Scope, Key, Action) ->
    maybe
        {ok, Name, Index} ?= key(Key),
        {ok, Kind, Target} ?= scope(Scope),
        {ok, Variants} ?= known(Name),
        ok ?= precheck(Kind, Index, Action, Variants),
        {ok, Server, ScopeArgs} ?= owner(Kind, Target),
        {ok, Meta} ?= case Name of
            <<$@, _/binary>> -> {ok, user_metadata()};
            _ ->
                maybe
                    {ok, Version} ?= tmux_server:version(Server),
                    {ok, Specific} ?= describe(Version, Name),
                    ok ?= allowed(Kind, Index, Action, Specific),
                    {ok, Specific}
                end
        end,
        {ok, Server, ScopeArgs, Name, Index, Meta}
    end.

scope({Kind, Server}) when Kind =:= server; Kind =:= session_defaults; Kind =:= window_defaults ->
    {ok, Kind, Server};
scope(Row) ->
    maybe
        {ok, Valid} ?= tmux_model:validate(Row),
        case tmux_model:entity(Valid) of
            Kind when Kind =:= session; Kind =:= window; Kind =:= pane -> {ok, Kind, Valid};
            _ -> {error, #{code => wrong_target_kind}}
        end
    end.

owner(server, Server) -> {ok, Server, [<<"-s">>]};
owner(session_defaults, Server) -> {ok, Server, [<<"-g">>]};
owner(window_defaults, Server) -> {ok, Server, [<<"-g">>, <<"-w">>]};
owner(Kind, Row) ->
    maybe
        {ok, Server, Target} ?= tmux_target:resolve(Kind, Row),
        Flags = case Kind of session -> []; window -> [<<"-w">>]; pane -> [<<"-p">>] end,
        {ok, Server, Flags ++ [<<"-t">>, Target]}
    end.

known(<<$@, _/binary>>) -> {ok, [{[], user_metadata()}]};
known(Name) ->
    case tmux_option_data:variants(Name) of
        [] -> {error, #{code => unknown_tmux_option, name => Name}};
        Variants -> {ok, Variants}
    end.

user_metadata() -> #{scopes => [server, session, window, pane], type => string,
                     array => false, hook => false}.

precheck(Kind, Index, Action, Variants) ->
    Checks = [allowed(Kind, Index, Action, M) || {_, M} <- Variants],
    case lists:member(ok, Checks) of true -> ok; false -> hd(Checks) end.

allowed(_, _, _, #{hook := true}) -> {error, #{code => hook_requires_api}};
allowed(Kind, Index, Action, #{scopes := Scopes, array := Array}) ->
    Actual = case Kind of session_defaults -> session; window_defaults -> window; _ -> Kind end,
    case {lists:member(Actual, Scopes), Array, Index, Action} of
        {false, _, _, _} -> {error, #{code => wrong_option_scope, actual => Actual, allowed => Scopes}};
        {true, false, N, _} when N =/= none -> {error, #{code => not_an_array}};
        {true, true, none, write} -> {error, #{code => array_index_required}};
        _ -> ok
    end.

key({Name, Index}) when is_integer(Index, 0, 2147483647) ->
    maybe {ok, Name, none} ?= key(Name), {ok, Name, Index} end;
key(Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 1024 ->
    case binary:match(Name, [<<0>>, <<"[">>, <<"]">>]) of
        nomatch ->
            case Name of
                <<$@>> -> {error, #{code => invalid_option_key}};
                _ -> {ok, Name, none}
            end;
        _ -> {error, #{code => invalid_option_key}}
    end;
key(_) -> {error, #{code => invalid_option_key}}.

value(Value) when is_binary(Value), byte_size(Value) =< 32768 ->
    case binary:match(Value, <<0>>) of
        nomatch -> ok;
        _ -> {error, #{code => invalid_option_value}}
    end;
value(_) -> {error, #{code => invalid_option_value}}.

indexed(Name, none) -> Name;
indexed(Name, Index) -> <<Name/binary, $[, (integer_to_binary(Index))/binary, $]>>.

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
