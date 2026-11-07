-module(tmux_buffer).
-moduledoc """
Load, inspect and paste tmux byte buffers through an explicit endpoint.

Use `load/3` for binary payloads, including NUL bytes, and `show/2` to read
them back without terminal escaping or an added newline. `list/1` returns
captured metadata in tmux's newest-first order; it never loads payloads.
`paste/3` sends a named buffer to a registered pane. Direct input is available
through `tmux_pane:send_text/2`.

Names are NUL-free binaries, distinct from payload bytes. New names retain
tmux's storage rules: 3.7+ cleans names and can reject control bytes or escape
backslashes. Use observed names from `list/1` for subsequent calls. Empty load
input is tmux's no-op; it neither creates nor clears a buffer. `delete/2`
removes a buffer explicitly. Names have no persistent object identity, and
concurrent commands can replace a buffer between calls.

All operations except `capabilities/1` perform explicit I/O. They use the
one-shot transport and preserve operational errors and ownership checks.
The [buffer guide](buffers.md) shows a complete byte round trip.
""".
-export([load/3, show/2, show/3, list/1, delete/2, rename/3, paste/3, capabilities/1]).
-export_type([target/0, info/0, read_options/0, paste_options/0, capabilities/0]).

-doc "A stored buffer name, or latest to let tmux select its newest buffer.".
-type target() :: binary() | latest.
-doc "Captured name, payload byte count and Unix creation time; not a live handle.".
-type info() :: #{name := binary(), size := non_neg_integer(), created := non_neg_integer()}.
-doc "Read bounds: max_bytes defaults to 1 MiB; deadline_ms defaults to 2500.".
-type read_options() :: #{max_bytes => 0..1048576, deadline_ms => 1..600000}.
-doc """
Paste controls. separator defaults to LF; delete and bracketed default to
false. sanitize defaults to false, preserving bytes. Explicit sanitization
requires tmux 3.7+. Bracketing occurs only when the pane enables bracketed paste.
""".
-type paste_options() :: #{separator => binary(), delete => boolean(),
    bracketed => boolean(), sanitize => boolean()}.
-doc "Source-defined buffer behavior for a parsed daemon version.".
-type capabilities() :: #{paste_sanitize := boolean(), cleaned_names := boolean(),
    rename_replaces := boolean(), strict_named_target := boolean()}.

-doc """
Describe version differences without I/O. This does not qualify an untested
release. `paste/3` uses paste_sanitize to gate sanitization and render raw paste.

```erlang
1> {ok, V} = tmux_version:parse(<<"tmux 3.3">>), ok.
ok
2> tmux_buffer:capabilities(V).
#{paste_sanitize => false,cleaned_names => false,
  rename_replaces => false,strict_named_target => false}
```
""".
-spec capabilities(tmux_version:t()) -> capabilities().
capabilities(Version) ->
    #{paste_sanitize => tmux_version:at_least(Version, {3, 7}),
      cleaned_names => tmux_version:at_least(Version, {3, 7}),
      rename_replaces => tmux_version:at_least(Version, {3, 4}),
      strict_named_target => tmux_version:at_least(Version, {3, 4})}.

-doc """
Load binary bytes under a name, or create an automatic buffer. Input may
contain NUL. Empty input succeeds without changing the buffer store, including
an existing name. The command payload, including argv and stdin, must fit the
endpoint's 256 KiB admission limit. See `tmux_server:command/3`.

Returns the completed command result, not a persistent buffer handle. No
clipboard write is requested. Native stored-name rules still apply.
""".
-spec load(tmux_server:t(), binary() | automatic, binary()) ->
    {ok, tmux_operation:completed()} | {error, map()}.
load(Server, Name, Bytes) ->
    maybe
        ok ?= payload(Bytes),
        {ok, Args} ?= case Name of automatic -> {ok, []}; _ -> named(Name) end,
        run(Server, <<"load-buffer">>, Args ++ [<<"--">>, <<"-">>], #{stdin => Bytes})
    end.

-doc "Read exact payload bytes with default bounds. See `show/3` for limits.".
-spec show(tmux_server:t(), target()) -> {ok, binary()} | {error, map()}.
show(Server, Buffer) -> show(Server, Buffer, #{}).

-doc """
Read exact payload bytes from an unattached one-shot client. No print decoding
or newline removal applies. max_bytes is 0 through 1 MiB; exceeding it returns
output_limit with partial command evidence, never a successful truncated value.
deadline_ms is 1 through 600000. Missing buffers return buffer_not_found.
""".
-spec show(tmux_server:t(), target(), read_options()) -> {ok, binary()} | {error, map()}.
show(Server, Buffer, Options) ->
    maybe
        {ok, ReadOptions} ?= read_options(Options),
        {ok, Args} ?= target(Buffer),
        {ok, #{stdout := Bytes}} ?= run(Server, <<"show-buffer">>, Args, ReadOptions),
        {ok, Bytes}
    end.

-doc """
Capture metadata in tmux's newest-first insertion order. Renaming preserves
position; replacing data through `load/3` inserts a new buffer. Length frames
preserve names containing delimiters, newlines or invalid UTF-8 on releases
that permit them. Returns an ordinary list, bounded to 4096 rows and 1 MiB of
encoded output. No payloads, hidden refresh or atomic snapshot is provided.
""".
-spec list(tmux_server:t()) -> {ok, [info()]} | {error, map()}.
list(Server) ->
    maybe
        {ok, Version} ?= tmux_server:version(Server),
        {ok, #{stdout := Bytes}} ?= run(Server, <<"list-buffers">>, [<<"-F">>,
            <<"#{n:buffer_name}:#{buffer_size}:#{buffer_created}:#{q:buffer_name}">>], #{}),
        tmux_buffer_codec:list(Bytes, Version)
    end.

-doc """
Delete a named buffer or latest. Missing buffers return buffer_not_found.
This performs I/O and affects the server-wide buffer store.

On 3.3/3.3a, named deletion first checks existence with a zero-output `show/3`
read because native deletion falls back to the newest buffer when a name is
absent. This check does not collect a payload or depend on the list bounds.
It is not atomic: concurrent removal after the check can trigger that fallback.
Use external serialization or tmux 3.4+ when that race is unacceptable.
""".
-spec delete(tmux_server:t(), target()) ->
    {ok, tmux_operation:completed()} | {error, map()}.
delete(Server, Buffer) ->
    maybe
        {ok, Args} ?= target(Buffer),
        ok ?= preflight(Server, Buffer),
        run(Server, <<"delete-buffer">>, Args, #{})
    end.

-doc """
Rename one explicit name. tmux 3.3 refuses an occupied destination; 3.4+ replaces
it. This is native collision behavior, not an atomic absence check. Identical
input names return same_buffer_name before I/O, avoiding unsafe legacy tmux
paths. New names retain native cleaning rules; see `list/1` for stored names.
The same observed 3.3/3.3a missing-name preflight and race as `delete/2` apply.
""".
-spec rename(tmux_server:t(), binary(), binary()) ->
    {ok, tmux_operation:completed()} | {error, map()}.
rename(Server, Old, New) ->
    maybe
        {ok, Args} ?= named(Old),
        {ok, _} ?= named(New),
        ok ?= case Old =:= New of
            true -> {error, #{code => same_buffer_name}};
            false -> ok
        end,
        ok ?= preflight(Server, Old),
        run(Server, <<"set-buffer">>, Args ++ [<<"-n">>, New], #{})
    end.

-doc """
Send a named buffer or latest to a registered pane. Defaults preserve payload
bytes: LF separators and unsanitized input. On tmux 3.7+, raw paste uses -S;
sanitize=true selects its safe print encoding. Earlier releases reject that
request with unsupported_capability before dispatch.

separator is NUL-free; delete removes the buffer after the native paste call.
bracketed adds markers only if the target has enabled that terminal mode.
Native input-off/dead-pane behavior still applies. Completion establishes the
tmux command result, not consumption by the child. No automatic retry occurs.
""".
-spec paste(tmux_model:pane(), target(), paste_options()) ->
    {ok, tmux_operation:completed()} | {error, map()}.
paste(Pane, Buffer, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{separator, bytes, <<"-s">>}, {delete, flag, <<"-d">>},
             {bracketed, flag, <<"-p">>}, {sanitize, boolean, <<>>}]),
        {ok, BufferArgs} ?= target(Buffer),
        {ok, Server, PaneTarget} ?= tmux_target:resolve(pane, Pane),
        {ok, Version} ?= tmux_server:version(Server),
        {ok, Safety} ?= safety(maps:get(sanitize, Options, false), capabilities(Version)),
        Separator = case maps:is_key(separator, Options) of
            true -> [];
            false -> [<<"-s">>, <<"\n">>]
        end,
        run(Server, <<"paste-buffer">>, BufferArgs ++ [<<"-t">>, PaneTarget] ++
            Safety ++ Separator ++ Flags, #{})
    end.

safety(true, #{paste_sanitize := false}) ->
    {error, #{code => unsupported_capability, capability => paste_sanitize}};
safety(false, #{paste_sanitize := true}) -> {ok, [<<"-S">>]};
safety(_, _) -> {ok, []}.

preflight(_, latest) -> ok;
preflight(Server, Name) ->
    maybe
        {ok, Version} ?= tmux_server:version(Server),
        case capabilities(Version) of
            #{strict_named_target := true} -> ok;
            _ ->
                %% Strict native show has no missing-name fallback. A zero
                %% allowance admits one detection byte and retires the client
                %% before returning overflow. Both outcomes prove existence.
                case show(Server, Name, #{max_bytes => 0}) of
                    {ok, <<>>} -> ok;
                    {error, #{code := output_limit, stream := stdout,
                              stdout := <<>>, cleanup := complete}} -> ok;
                    Error -> Error
                end
        end
    end.

target(latest) -> {ok, []};
target(Name) -> named(Name).

named(Name) when is_binary(Name), byte_size(Name) > 0 ->
    case binary:match(Name, <<0>>) of
        nomatch -> {ok, [<<"-b">>, Name]};
        _ -> {error, #{code => invalid_buffer_name}}
    end;
named(_) -> {error, #{code => invalid_buffer_name}}.

payload(Bytes) when is_binary(Bytes), byte_size(Bytes) =< 262144 -> ok;
payload(Bytes) when is_binary(Bytes) -> {error, #{code => command_limit}};
payload(_) -> {error, #{code => invalid_buffer_data}}.

read_options(Options) when is_map(Options) ->
    Unknown = lists:sort(maps:keys(maps:without([max_bytes, deadline_ms], Options))),
    case Unknown of
        [Key | _] -> {error, #{code => unknown_option, path => [Key]}};
        [] ->
            Bytes = maps:get(max_bytes, Options, 1048576),
            Deadline = maps:get(deadline_ms, Options, 2500),
            if
                not is_integer(Bytes, 0, 1048576) ->
                    {error, #{code => invalid_option, path => [max_bytes]}};
                not is_integer(Deadline, 1, 600000) ->
                    {error, #{code => invalid_option, path => [deadline_ms]}};
                true -> {ok, #{max_stdout => Bytes, deadline_ms => Deadline}}
            end
    end;
read_options(_) -> {error, #{code => invalid_options, path => []}}.

run(Server, Name, Args, Options) ->
    case tmux_target:run(Server, Name, Args, Options) of
        {error, #{code := command_error, stderr := Stderr} = Detail} ->
            Missing = case Stderr of
                <<"no buffer", _/binary>> -> true;
                <<"unknown buffer: ", _/binary>> -> true;
                _ -> false
            end,
            {error, case Missing of true -> Detail#{code => buffer_not_found}; false -> Detail end};
        Result -> Result
    end.
