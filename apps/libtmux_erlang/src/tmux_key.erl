-module(tmux_key).
-moduledoc """
Register and remove bindings in explicit server key tables.

`bind/3` uses the native prefix table; `bind/4` chooses a table, repeat flag
and note. Command values use `tmux_command:to_config/1` for the stored parser
boundary. Replacing a binding resets its commands, repeat flag and note.
Registration does not prove that a client later executed the binding.

Tables belong to the server. A session's key-table option selects its default
table through `m:tmux_option`; tmux's prefix and client table-switching rules
still apply. Registering a custom table does not select it for any client.
`clear_table/2` requires an explicit name and can affect attached clients.

`listing/2` returns native presentation bytes. Field padding, quoting, note
coverage and formatting vary by daemon release. It does not decode bindings
or promise reusable configuration. Retain the original command values when
an application needs to install the same binding again.

Key names use tmux's own binary spellings, such as C-b, Enter and MouseDown1Pane.
The daemon validates actual names and modifiers. Library validation bounds
bytes and rejects NUL before dispatch. Calls use registered endpoint identity,
perform explicit I/O and never retry uncertain mutations. They do not attach
a client or refresh captured rows.

The [key-table guide](keys.md) installs and removes an application-owned table.
""".
-export([bind/3, bind/4, unbind/2, unbind/3, clear_table/2, listing/1, listing/2]).
-export_type([key/0, bind_options/0, listing_options/0]).

-doc "A nonempty NUL-free native key spelling, at most 128 bytes; tmux validates its meaning.".
-type key() :: binary().
-doc """
Default table is prefix and repeat is false. Tables contain 1..1024 NUL-free
bytes. note is at most 32 KiB of NUL-free bytes; omitting it removes an old
note when commands are replaced. Command-level aggregate bounds still apply.
""".
-type bind_options() :: #{table => binary(), repeat => boolean(), note => binary()}.
-doc """
No table filter lists all native tables. table restricts the listing to one
nonempty NUL-free name of at most 1024 bytes; key restricts it to a native key
spelling. Missing tables and unmatched key filters retain native errors.
""".
-type listing_options() :: #{table => binary(), key => key()}.

-doc """
Register commands in the native prefix table with default options. Performs
I/O; see `bind/4` for replacement, command parsing and future execution.
""".
-spec bind(tmux_server:t(), key(), tmux_command:t() | [tmux_command:t(), ...]) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
bind(Server, Key, Commands) -> bind(Server, Key, Commands, #{}).

-doc """
Register or replace one binding with validated command values. Commands can
be one value or a flat nonempty list; `tmux_command:to_config/1` applies the
aggregate count and byte bounds. Options follow `t:bind_options/0`. Arguments,
table names and notes are literal bytes at registration; stored commands still
interpret their values and formats when a client executes them.

Performs I/O. tmux parses the commands before replacing an existing binding.
The result confirms registration, while effects of future key presses need
their own acknowledgement. Replacement resets the old repeat flag and note
using the supplied options. Errors preserve backend diagnostics and unknown
outcomes; there is no rollback or automatic retry.
""".
-spec bind(tmux_server:t(), key(), tmux_command:t() | [tmux_command:t(), ...],
    bind_options()) -> {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
bind(Server, Key0, Commands, Options) ->
    maybe
        {ok, Key} ?= key(Key0),
        {ok, Text} ?= tmux_command:to_config(Commands),
        {ok, Flags} ?= tmux_args:options(Options,
            [{table, key_table, <<"-T">>}, {repeat, flag, <<"-r">>},
             {note, bytes, <<"-N">>}], #{table => <<"prefix">>}),
        tmux_target:run(Server, <<"bind-key">>, Flags ++ [<<"--">>, Key, Text])
    end.

-doc "Remove a binding from the native prefix table. Performs I/O; see `unbind/3`.".
-spec unbind(tmux_server:t(), key()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
unbind(Server, Key) -> unbind(Server, Key, #{}).

-doc """
Remove one key from the explicit table, defaulting to prefix. Only table is
accepted in the options map. A missing key in an existing table is a native
no-op; a missing explicit table remains an error. Removing the final custom
binding can remove its table, so a repeated call can then report that missing
table. Invalid native key names are never quietly suppressed.

Performs I/O. Effects already queued by a client are unaffected. Use
`clear_table/2` to remove an entire explicitly named table.
""".
-spec unbind(tmux_server:t(), key(), #{table => binary()}) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
unbind(Server, Key0, Options) ->
    maybe
        {ok, Key} ?= key(Key0),
        {ok, Flags} ?= tmux_args:options(Options,
            [{table, key_table, <<"-T">>}], #{table => <<"prefix">>}),
        tmux_target:run(Server, <<"unbind-key">>, Flags ++ [<<"--">>, Key])
    end.

-doc """
Remove the entire explicitly named table through native unbind-key -a -T.
Names use the bounds in `t:bind_options/0`. This can remove default bindings
and affect attached clients. Missing tables remain native errors; this call
does not restore factory defaults or cancel commands already queued.
Performs I/O after endpoint and argument validation.
""".
-spec clear_table(tmux_server:t(), binary()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
clear_table(Server, Table) ->
    maybe
        {ok, Flags} ?= tmux_args:options(#{table => Table}, [{table, key_table, <<"-T">>}]),
        tmux_target:run(Server, <<"unbind-key">>, [<<"-a">> | Flags] ++ [<<"--">>])
    end.

-doc "Read all tables as native listing bytes. Performs I/O; see `listing/2`.".
-spec listing(tmux_server:t()) -> {ok, binary()} | {error, map()}.
listing(Server) -> listing(Server, #{}).

-doc """
Read native list-keys presentation output, optionally filtering by table and
key through `t:listing_options/0`. Returns the command's stdout unchanged;
spacing, quoting and included metadata follow that daemon. This is a text
view, with no decoded-row, exact-note or configuration-round-trip guarantee.

The baseline command has no custom format option on tmux 3.3. Deliberate
newer-server formatting is available through `tmux_command:raw/2`. Performs
I/O; missing tables, unknown keys and other backend errors remain errors.
""".
-spec listing(tmux_server:t(), listing_options()) -> {ok, binary()} | {error, map()}.
listing(Server, Options) when is_map(Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(maps:remove(key, Options),
            [{table, key_table, <<"-T">>}]),
        {ok, Keys} ?= case maps:find(key, Options) of
            error -> {ok, []};
            {ok, Key0} -> maybe {ok, Key} ?= key(Key0), {ok, [Key]} end
        end,
        {ok, #{stdout := Output}} ?= tmux_target:run(Server, <<"list-keys">>,
            Flags ++ [<<"--">> | Keys]),
        {ok, Output}
    end;
listing(_, _) -> {error, #{code => invalid_options, path => []}}.

key(Key) when is_binary(Key), byte_size(Key) > 0, byte_size(Key) =< 128 ->
    case binary:match(Key, <<0>>) of
        nomatch -> {ok, Key};
        _ -> {error, #{code => invalid_key}}
    end;
key(_) -> {error, #{code => invalid_key}}.
