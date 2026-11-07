-module(tmux_hook).
-moduledoc """
Store builtin hook commands and run them in an explicit observed context.

`set/3` replaces one indexed entry. `append/3` uses tmux's first vacant index;
`clear/2` leaves an empty local array and `unset/2` restores inheritance.
`get/3` reads local values unless inheritance is requested. Commands are
`t:tmux_command:t/0` values, rendered by `tmux_command:to_config/1` before tmux
parses and stores them. A successful write confirms registration, while later
hook effects need their own completion evidence.

Table scope and execution context are separate. `run/2` selects a session,
checked window link or checked pane/link pair. Physical windows can belong to
several sessions; a link preserves the chosen session and index. Preflight and
dispatch are separate observations, with no atomic compare-and-act guarantee.
Known restarts and closed owners invalidate references. Captured rows never
refresh during these actions.

Names and table scopes use the exact source-derived version catalogue from
`tmux_option:catalogue/1`. User options, prefixes and aliases are rejected.
The native custom-event and monitor interfaces are outside this API. Deliberate
raw integration remains available through `tmux_command:raw/2`. Calls perform
I/O after validation and never retry uncertain mutations. The
[hook guide](hooks.md) demonstrates registration and an effect acknowledgement.
""".
-export([get/3, set/3, append/3, clear/2, unset/2, run/2]).
-export_type([scope/0, context/0, commands/0, value/0]).

-doc """
A registered local table or explicit global session/window defaults; see
`t:tmux_option:scope/0`.
""".
-type scope() :: tmux_model:session() | tmux_model:window() | tmux_model:pane() |
    {session_defaults | window_defaults, tmux_server:t()}.
-doc """
A session's current context, one observed membership, or a pane in that
membership.
""".
-type context() :: tmux_model:session() | tmux_model:window_link() |
    {pane, tmux_model:pane(), tmux_model:window_link()}.
-doc """
One validated command or a nonempty list; at most 256 commands and 32 KiB
rendered text.
""".
-type commands() :: tmux_command:t() | [tmux_command:t(), ...].
-doc """
Canonical native command-list text, or a sparse map of indexes to that text.
""".
-type value() :: binary() | #{non_neg_integer() => binary()}.

-doc """
Read a builtin hook array or indexed entry. Options follow
`t:tmux_option:read_options/0`: local-only by default, inherit = true follows
its parent tables. Missing local arrays or entries return none; an empty local
array returns {ok, #{}} and masks inheritance.

Values are tmux's command-list serialization, including its quoting and escape
sequences. They are neither the original input text nor individual decoded
arguments. Reading does not execute them. Use `set/3` for validated command
values and `unset/2` to restore inheritance. Performs I/O and preserves backend
errors; a vanished target is not an absent hook.
""".
-spec get(scope(), tmux_option:key(), tmux_option:read_options()) ->
    {ok, value()} | none | {error, map()}.
get(Scope, Key, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options, [{inherit, flag, <<"-A">>}]),
        {ok, Server, ScopeArgs, Name, Index, Meta} ?=
            tmux_option_scope:prepare(Scope, Key, read, hook),
        {ok, Version} ?= tmux_server:version(Server),
        {ok, Literal} ?= tmux_command:literal_format(Name),
        {ok, #{stdout := Output}} ?= tmux_target:run(Server, <<"show-options">>,
            ScopeArgs ++ Flags ++ [<<"-H">>, <<"--">>, Literal]),
        case tmux_option_codec:decode(Name, Output, Meta, Version) of
            {ok, Entries} when is_map(Entries), Index =/= none ->
                case maps:find(Index, Entries) of
                    {ok, Value} -> {ok, Value};
                    error -> none
                end;
            Result -> Result
        end
    end.

-doc """
Replace one {Name, Index} entry with validated command values. An explicit
index is required; other entries remain. Indexes range from zero to
2147483647. The rendered command text is bounded before dispatch. Native
commands still interpret their arguments and formats when the hook later runs.
Use `append/3` for native vacant-index selection and `clear/2` to mask inherited
hooks with an empty local array.

Performs I/O. tmux parses commands before replacing an existing entry, but a
failed first write can already create an empty local override. Registration
and later execution are separate; this call promises no transaction, rollback
or completion of future effects.
""".
-spec set(scope(), {binary(), non_neg_integer()}, commands()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
set(Scope, Key, Commands) ->
    maybe
        {ok, Text} ?= body(Commands),
        {ok, Server, Flags, Name, Index, _} ?=
            tmux_option_scope:prepare(Scope, Key, write, hook),
        store(Server, Flags, tmux_option_scope:indexed(Name, Index), Text)
    end.

-doc """
Store commands at tmux's first vacant local index for the unindexed name.
A new local array starts independently of inherited entries; this does not
copy the parent's array. The command result does not report the chosen index;
`get/3` observes current entries separately. Performs I/O with the parsing and
unknown-outcome semantics of `set/3`.
""".
-spec append(scope(), binary(), commands()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
append(Scope, Name0, Commands) ->
    maybe
        {ok, Name} ?= name(Name0),
        {ok, Text} ?= body(Commands),
        {ok, Server, Flags, Name, none, _} ?=
            tmux_option_scope:prepare(Scope, Name, append, hook),
        store(Server, Flags ++ [<<"-a">>], Name, Text)
    end.

-doc """
Leave an empty local hook array, masking inherited entries. This differs
from `unset/2`, which restores inheritance. Global clear empties that defaults
table. Performs I/O; existing effects already queued by tmux are not cancelled.
""".
-spec clear(scope(), binary()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
clear(Scope, Name0) ->
    maybe
        {ok, Name} ?= name(Name0),
        {ok, Server, Flags, Name, none, _} ?=
            tmux_option_scope:prepare(Scope, Name, clear, hook),
        store(Server, Flags, Name, <<>>)
    end.

-doc """
Remove one indexed entry or the whole local array. Removing an entry leaves
its local array, possibly empty. Removing the whole array restores inheritance;
unsetting a global builtin resets its native default. Missing local values are
a successful native no-op. Performs I/O; queued hook effects are unaffected.
""".
-spec unset(scope(), tmux_option:key()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
unset(Scope, Key) ->
    maybe
        {ok, Server, Flags, Name, Index, _} ?=
            tmux_option_scope:prepare(Scope, Key, unset, hook),
        {ok, Literal} ?= tmux_command:literal_format(tmux_option_scope:indexed(Name, Index)),
        tmux_target:run(Server, <<"set-hook">>, Flags ++ [<<"-u">>, <<"--">>, Literal])
    end.

-doc """
Request native set-hook -R in the explicit `t:context/0`. tmux resolves the
hook through that context's effective tables; global table flags do not select
a separate execution scope. A session uses its current window and pane. A
window link fixes the observed session/index and expected physical window;
a pane context additionally checks that pane's observed parent.

Performs I/O. The result is the native command outcome, not an acknowledgement
of background work launched by its commands. A missing or empty effective hook
can succeed without effects. Wait on an application completion condition when
effects matter. Existence and membership checks precede dispatch. If the
target disappears after preflight, tmux can still fall back to another
context. This is not atomic compare-and-act. Use fresh links after known
topology changes.
""".
-spec run(context(), binary()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
run(Context, Name0) ->
    maybe
        {ok, Name} ?= name(Name0),
        {ok, Server, Target} ?= context(Context),
        {ok, Version} ?= tmux_server:version(Server),
        {ok, _} ?= tmux_option:describe(Version, Name),
        tmux_target:run(Server, <<"set-hook">>,
            [<<"-R">>, <<"-t">>, Target, <<"--">>, Name])
    end.

store(Server, Flags, Name, Text) ->
    maybe
        {ok, Literal} ?= tmux_command:literal_format(Name),
        tmux_target:run(Server, <<"set-hook">>, Flags ++ [<<"--">>, Literal, Text])
    end.

name(Name) when is_binary(Name) ->
    case tmux_option_scope:key(Name) of
        {ok, Name, none} ->
            case tmux_option_data:variants(Name) of
                [] -> {error, #{code => unknown_tmux_option, name => Name}};
                Variants ->
                    case lists:any(fun({_, Meta}) -> maps:get(hook, Meta) end, Variants) of
                        true -> {ok, Name};
                        false -> {error, #{code => not_a_hook}}
                    end
            end;
        _ -> {error, #{code => invalid_hook_name}}
    end;
name(_) -> {error, #{code => invalid_hook_name}}.

body([]) -> {error, #{code => invalid_hook_commands}};
body([_ | _] = Commands) -> bodies(Commands, 256, 0, []);
body(Command) -> bodies([Command], 1, 0, []).

bodies([], _, _, Acc) -> {ok, iolist_to_binary(lists:join(<<" ; ">>, lists:reverse(Acc)))};
bodies([_ | _], 0, _, _) -> {error, #{code => command_limit}};
bodies([Command | Rest], Remaining, Bytes, Acc) ->
    maybe
        {ok, Text} ?= tmux_command:to_config(Command),
        Size = Bytes + byte_size(Text) + case Acc of [] -> 0; _ -> 3 end,
        case Size =< 32768 of
            true -> bodies(Rest, Remaining - 1, Size, [Text | Acc]);
            false -> {error, #{code => command_limit}}
        end
    end;
bodies(_, _, _, _) -> {error, #{code => invalid_hook_commands}}.

context({pane, Pane, Link}) ->
    maybe
        {ok, Server} ?= tmux_target:same_owner(pane, Pane, window_link, Link),
        {ok, Target} ?= tmux_target:linked_pane(Server, Pane, Link),
        {ok, Server, Target}
    end;
context(Row) ->
    case tmux_model:validate(Row) of
        {ok, Valid} -> context_row(tmux_model:entity(Valid), Valid);
        _ -> {error, #{code => invalid_hook_context}}
    end.

context_row(session, Row) ->
    maybe
        {ok, Server, Target} ?= tmux_target:resolve(session, Row),
        {ok, _} ?= tmux_session:get(Server, tmux_model:get(id, Row)),
        {ok, Server, Target}
    end;
context_row(window_link, Link) ->
    maybe
        {ok, Server} ?= tmux_target:owner(window_link, Link),
        {ok, _, Target} ?= tmux_window_link:check(Server, Link),
        {ok, Server, Target}
    end;
context_row(_, _) -> {error, #{code => invalid_hook_context}}.
