-module(tmux_identity).
-moduledoc """
Observe a Linux process incarnation using its PID, boot ID and start ticks.

```erlang
1> Pid = list_to_integer(os:getpid()), ok.
ok
2> {ok, Identity} = tmux_identity:observe(Pid), ok.
ok
3> tmux_identity:check(Identity, Pid).
ok
```

A successful check is an observation. It neither reserves a PID nor pins a
tmux connection, and it never authorizes signalling a process. Endpoint owners
in `m:tmux_server` compare the PID returned by the current connection as well.
A server can still change between this check and a later one-shot command.

Use `fingerprint/1` to compare captured incarnations across endpoint handles
or persist that comparison in a plan. It performs no process observation;
the key grants neither liveness nor permission to act.
""".
-export([observe/1, check/2, fingerprint/1]).
-export_type([t/0, fingerprint/0]).

-doc """
Observed Linux PID, boot identity and process-start token. It does not pin a
connection.
""".
-opaque t() :: {process_identity, pos_integer(), binary(), non_neg_integer()}.

-doc """
Versioned SHA-256 comparison key for a captured Linux process incarnation.
The linux-v1 prefix identifies the canonical encoding, independent of Erlang
term serialization. Keys compare identity observations, not endpoint ownership
or current liveness. They are identifiers, not authentication tokens.
""".
-type fingerprint() :: binary().

-doc """
Derive a portable `t:fingerprint/0` from a captured identity without I/O.

The key includes PID, boot ID and process-start ticks. Reconnecting to the same
process preserves it; changing any component changes it. The encoding is
versioned for persisted plans. Use `check/2` for a fresh process observation.
Malformed identity terms return invalid_identity before hashing.

```erlang
1> {ok, I} = tmux_identity:observe(list_to_integer(os:getpid())), ok.
ok
2> {ok, Key} = tmux_identity:fingerprint(I), ok.
ok
3> byte_size(Key).
73
```
""".
-spec fingerprint(t()) ->
    {ok, fingerprint()} | {error, #{code := invalid_identity}}.
fingerprint({process_identity, Pid, Boot, Started})
  when is_integer(Pid, 1, 2147483647), is_binary(Boot),
       is_integer(Started, 0, 18446744073709551615) ->
    case valid_boot_id(Boot) of
        true ->
            Digest = crypto:hash(sha256,
                [<<"libtmux-erlang-incarnation", 0, "1", 0>>,
                 integer_to_binary(Pid), <<0>>, Boot, <<0>>,
                 integer_to_binary(Started)]),
            {ok, <<"linux-v1:",
                (binary:encode_hex(Digest, lowercase))/binary>>};
        false -> {error, #{code => invalid_identity}}
    end;
fingerprint(_) -> {error, #{code => invalid_identity}}.

-doc """
Observe a Linux PID incarnation without signalling it. Returns a tagged error
if the process cannot be identified; this performs local operating-system I/O.
""".
-spec observe(pos_integer()) -> {ok, t()} | {error, map()}.
observe(Pid) when is_integer(Pid, 1, 2147483647) ->
    case os:type() of
        {unix, linux} -> observe_linux(Pid);
        _ -> {error, #{code => unsupported_platform}}
    end;
observe(_) -> {error, #{code => invalid_pid}}.

-doc """
Re-observe the PID and compare its incarnation token. A successful result is a
momentary observation, not ownership, permission to signal, or a
same-connection guarantee.
""".
-spec check(t(), pos_integer()) -> ok | {error, map()}.
check({process_identity, Pid, Boot, Started} = Identity, ObservedPid)
  when is_integer(Pid, 1, 2147483647), is_integer(ObservedPid, 1, 2147483647),
       is_binary(Boot), is_integer(Started, 0, 18446744073709551615) ->
    case valid_boot_id(Boot) of
        false -> {error, #{code => invalid_identity}};
        true when Pid =/= ObservedPid -> {error, #{code => stale_server}};
        true ->
            case observe(Pid) of
                {ok, Identity} -> ok;
                {ok, _} -> {error, #{code => stale_server}};
                {error, #{code := target_gone}} -> {error, #{code => stale_server}};
                Error -> Error
            end
    end;
check(_, _) -> {error, #{code => invalid_identity}}.

observe_linux(Pid) ->
    maybe
        {ok, Stat} ?= read_bounded("/proc/" ++ integer_to_list(Pid) ++ "/stat", 4096),
        {ok, Started} ?= start_ticks(Pid, Stat),
        {ok, RawBoot} ?= boot_file(),
        Boot = string:trim(RawBoot),
        case valid_boot_id(Boot) of
            true -> {ok, {process_identity, Pid, Boot, Started}};
            false -> {error, #{code => identity_unavailable, reason => malformed_boot_id}}
        end
    end.

boot_file() ->
    case read_bounded("/proc/sys/kernel/random/boot_id", 64) of
        {ok, Bytes} -> {ok, Bytes};
        {error, Detail} -> {error, Detail#{code => identity_unavailable, resource => boot_id}}
    end.

read_bounded(Path, Limit) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, File} ->
            try
                case file:read(File, Limit + 1) of
                    {ok, Data} when byte_size(Data) =< Limit -> {ok, Data};
                    {ok, _} -> {error, #{code => identity_unavailable, reason => oversized_proc_file}};
                    eof -> {error, #{code => target_gone}};
                    {error, Reason} -> file_error(Reason)
                end
            after ok = file:close(File)
            end;
        {error, Reason} -> file_error(Reason)
    end.

file_error(enoent) -> {error, #{code => target_gone}};
file_error(esrch) -> {error, #{code => target_gone}};
file_error(Reason) -> {error, #{code => identity_unavailable, reason => Reason}}.

start_ticks(Pid, Stat) ->
    Prefix = <<(integer_to_binary(Pid))/binary, " (">>,
    Size = byte_size(Prefix),
    case Stat of
        <<Prefix:Size/binary, Rest/binary>> -> parse_stat_tail(Rest);
        _ -> {error, #{code => identity_unavailable, reason => malformed_proc_stat}}
    end.

parse_stat_tail(Rest) ->
    case binary:matches(Rest, <<") ">>) of
        [] -> {error, #{code => identity_unavailable, reason => malformed_proc_stat}};
        Matches ->
            %% comm may itself contain spaces, newlines and closing parentheses.
            {Position, 2} = lists:last(Matches),
            Tail = binary:part(Rest, Position + 2, byte_size(Rest) - Position - 2),
            Fields = binary:split(Tail, <<" ">>, [global]),
            parse_fields(Fields)
    end.

parse_fields([State | _]) when State =:= <<"Z">>; State =:= <<"X">>; State =:= <<"x">> ->
    {error, #{code => target_gone}};
parse_fields(Fields) when length(Fields) >= 20 ->
    Start = lists:nth(20, Fields),
    case decimal(Start) of
        true ->
            Ticks = binary_to_integer(Start),
            case Ticks =< 18446744073709551615 of
                true -> {ok, Ticks};
                false -> {error, #{code => identity_unavailable, reason => malformed_proc_stat}}
            end;
        false -> {error, #{code => identity_unavailable, reason => malformed_proc_stat}}
    end;
parse_fields(_) -> {error, #{code => identity_unavailable, reason => malformed_proc_stat}}.

decimal(<<>>) -> false;
decimal(Bytes) -> decimal_tail(Bytes).
decimal_tail(<<>>) -> true;
decimal_tail(<<C, Rest/binary>>) when C >= $0, C =< $9 -> decimal_tail(Rest);
decimal_tail(_) -> false.

valid_boot_id(<<A:8/binary, $-, B:4/binary, $-, C:4/binary, $-, D:4/binary, $-, E:12/binary>>) ->
    hex(<<A/binary, B/binary, C/binary, D/binary, E/binary>>);
valid_boot_id(_) -> false.

hex(<<>>) -> true;
hex(<<C, Rest/binary>>) when (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) ->
    hex(Rest);
hex(_) -> false.
