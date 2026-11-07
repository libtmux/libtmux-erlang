-module(tmux_transport_codec).
-moduledoc false.
-export([open/1, decode/1, credit/2, write/2]).
-export_type([event/0]).

-type event() :: {started, pos_integer()}
               | {data, stdout | stderr, binary()}
               | {eof, stdout | stderr}
               | {write_ack, non_neg_integer(), non_neg_integer(), boolean()}
               | stdin_closed
               | {retired, 0..3, non_neg_integer()}
               | {failed, 1..4, non_neg_integer()}.

-spec open(map()) -> {ok, binary()} | {error, map()}.
open(#{executable := <<$/, _/binary>> = Executable, args := Arguments,
       cwd := <<$/, _/binary>> = Cwd, env := Environment,
       stdin_open := InputOpen, timeout_ms := Timeout})
  when is_list(Arguments), is_list(Environment), is_boolean(InputOpen),
       is_integer(Timeout, 0, 600000) ->
    maybe
        {ok, CwdPart, CwdSize} ?= encode_string(Cwd),
        {ok, Argv, Argc, ArgSize} ?= strings([Executable | Arguments], 2048, 0, 0, []),
        ok ?= environment(Environment, 256),
        {ok, Env, Envc, EnvSize} ?= strings(Environment, 256, 0, 0, []),
        case 11 + CwdSize + ArgSize + EnvSize =< 32768 of
            true ->
                Open = case InputOpen of true -> 1; false -> 0 end,
                {ok, iolist_to_binary([
                    <<$O, 3, Open, Timeout:32>>, CwdPart,
                    <<Argc:16>>, Argv, <<Envc:16>>, Env
                ])};
            false -> {error, #{code => command_limit}}
        end
    end;
open(_) ->
    {error, #{code => invalid_argument}}.

-spec credit(stdout | stderr, 1..8192) -> binary().
credit(stdout, Bytes) when is_integer(Bytes, 1, 8192) -> <<$R, 1, Bytes:16>>;
credit(stderr, Bytes) when is_integer(Bytes, 1, 8192) -> <<$R, 2, Bytes:16>>.

-spec write(0..4294967295, binary()) -> binary().
write(Id, Bytes) when is_integer(Id, 0, 4294967295),
                      is_binary(Bytes), byte_size(Bytes) > 0, byte_size(Bytes) =< 8192 ->
    <<$W, Id:32, Bytes/binary>>.

-spec decode(binary()) -> {ok, event()} | {error, map()}.
decode(<<$S, Pid:32>>) when Pid > 0 -> {ok, {started, Pid}};
decode(<<$D, Stream, Bytes/binary>>)
  when (Stream =:= 1 orelse Stream =:= 2),
       byte_size(Bytes) > 0, byte_size(Bytes) =< 8192 ->
    {ok, {data, stream(Stream), Bytes}};
decode(<<$Z, Stream>>) when Stream =:= 1; Stream =:= 2 ->
    {ok, {eof, stream(Stream)}};
decode(<<$A, Id:32, Delivered:16, Failed>>)
  when Delivered =< 8192, (Failed =:= 0 orelse Failed =:= 1) ->
    {ok, {write_ack, Id, Delivered, Failed =:= 1}};
decode(<<$C>>) -> {ok, stdin_closed};
decode(<<$E, Reason, Status:32>>) when Reason =< 3 ->
    {ok, {retired, Reason, Status}};
decode(<<$F, Kind, Errno:32>>) when Kind >= 1, Kind =< 4 ->
    {ok, {failed, Kind, Errno}};
decode(_) -> {error, #{code => invalid_helper_frame}}.

stream(1) -> stdout;
stream(2) -> stderr.

encode_string(Value) when is_binary(Value), byte_size(Value) =< 32768 ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, [<<(byte_size(Value)):16>>, Value], 2 + byte_size(Value)};
        _ -> {error, #{code => invalid_argument}}
    end;
encode_string(Value) when is_binary(Value) ->
    {error, #{code => command_limit}};
encode_string(_) ->
    {error, #{code => invalid_argument}}.

strings([], _Remaining, Count, Size, Parts) ->
    {ok, lists:reverse(Parts), Count, Size};
strings([_ | _], 0, _Count, _Size, _Parts) ->
    {error, #{code => command_limit}};
strings([Value | Rest], Remaining, Count, Size, Parts) ->
    maybe
        {ok, Encoded, Length} ?= encode_string(Value),
        case Size + Length =< 32768 of
            true -> strings(Rest, Remaining - 1, Count + 1, Size + Length,
                            [Encoded | Parts]);
            false -> {error, #{code => command_limit}}
        end
    end;
strings(_, _, _, _, _) ->
    {error, #{code => invalid_argument}}.

environment([], _Remaining) -> ok;
environment([_ | _], 0) -> {error, #{code => command_limit}};
environment([Value | Rest], Remaining) when is_binary(Value) ->
    case binary:match(Value, <<"=">>) of
        {Position, 1} when Position > 0 -> environment(Rest, Remaining - 1);
        _ -> {error, #{code => invalid_argument}}
    end;
environment(_, _) -> {error, #{code => invalid_argument}}.
