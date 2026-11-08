-module(tmux_control_codec).
-moduledoc false.
-export([new/1, feed/2, finish/1]).
-export_type([t/0, guard/0, event/0]).

-type guard() :: #{generation := reference(), time := non_neg_integer(),
                   number := non_neg_integer(), flags := non_neg_integer()}.
-type event() :: {block_begin, guard()}
               | {block_data, guard(), binary()}
               | {block_end, guard(), ok | error}
               | {notification, reference(), binary()}
               | {exit, reference(), binary()}.
-opaque t() :: #{generation := reference(), partial := binary(),
                 block := none | {guard(), binary()}, bytes := non_neg_integer(),
                 exited := boolean()}.
-define(LINE_BYTES, 65536).
-define(OUTPUT_BYTES, 1048576).

%% Pure framing only: callers must qualify reply/event shapes, account for
%% aggregate connection bytes and retire on error. EOF is no execution proof.
-spec new(reference()) -> t().
new(Generation) when is_reference(Generation) ->
    #{generation => Generation, partial => <<>>, block => none, bytes => 0, exited => false}.

-spec feed(t(), binary()) -> {ok, [event()], t()} | {error, map(), [event()]}.
feed(State, Bytes) when is_binary(Bytes), byte_size(Bytes) =< 8192 ->
    lines(State, Bytes, []);
feed(State, _) -> failure(State, control_chunk_limit, []).

-spec finish(t()) -> ok | {error, map()}.
finish(#{partial := <<>>, block := none}) -> ok;
finish(#{partial := <<>>} = State) ->
    {error, reason(State, unfinished_control_block)};
finish(State) -> {error, reason(State, unfinished_control_line)}.

lines(State, <<>>, Events) -> {ok, lists:reverse(Events), State};
lines(#{exited := true} = State, _, Events) ->
    failure(State, control_data_after_exit, Events);
lines(#{partial := Partial} = State, Bytes, Events) ->
    case binary:match(Bytes, <<"\n">>) of
        nomatch when byte_size(Partial) + byte_size(Bytes) =< ?LINE_BYTES ->
            case partial_fits(State, Bytes) of
                true ->
                    {ok, lists:reverse(Events), State#{partial := <<Partial/binary, Bytes/binary>>}};
                false -> failure(State, control_output_limit, Events)
            end;
        nomatch -> failure(State, control_line_limit, Events);
        {Size, 1} when byte_size(Partial) + Size =< ?LINE_BYTES ->
            <<Head:Size/binary, 10, Rest/binary>> = Bytes,
            case line(State#{partial := <<>>}, <<Partial/binary, Head/binary>>) of
                {ok, Event, Next} -> lines(Next, Rest, [Event | Events]);
                {error, Code} -> failure(State, Code, Events)
            end;
        _ -> failure(State, control_line_limit, Events)
    end.

%% A fragmented exact terminator consumes guard overhead, not payload bytes.
%% Every other partial line must already fit the remaining block budget.
partial_fits(#{block := none}, _) -> true;
partial_fits(#{block := {_, Tail}, partial := Partial, bytes := Used}, Bytes) ->
    Used + byte_size(Partial) + byte_size(Bytes) =< ?OUTPUT_BYTES orelse
        guard_prefix(Partial, Bytes, <<"%end ", Tail/binary>>) orelse
        guard_prefix(Partial, Bytes, <<"%error ", Tail/binary>>).

guard_prefix(Partial, Bytes, Expected) ->
    Size = byte_size(Partial) + byte_size(Bytes),
    Size =< byte_size(Expected) andalso
        binary:part(Expected, 0, Size) =:= <<Partial/binary, Bytes/binary>>.

%% Only this exact terminator closes a block. A nested-looking guard,
%% notification, CR or arbitrary byte inside output remains payload.
line(#{block := {Guard, Tail}} = State, Line) ->
    case Line of
        <<"%end ", Tail/binary>> ->
            {ok, {block_end, Guard, ok}, State#{block := none, bytes := 0}};
        <<"%error ", Tail/binary>> ->
            {ok, {block_end, Guard, error}, State#{block := none, bytes := 0}};
        _ ->
            Size = maps:get(bytes, State) + byte_size(Line) + 1,
            case Size =< ?OUTPUT_BYTES of
                true -> {ok, {block_data, Guard, <<Line/binary, 10>>}, State#{bytes := Size}};
                false -> {error, control_output_limit}
            end
    end;
line(#{generation := Generation} = State, <<"%begin ", Fields/binary>>)
  when byte_size(Fields) =< 64 ->
    case guard_fields(Fields) of
        {ok, Time, Number, Flags} ->
            Guard = #{generation => Generation, time => Time, number => Number, flags => Flags},
            {ok, {block_begin, Guard}, State#{block := {Guard, binary:copy(Fields)}, bytes := 0}};
        error -> {error, invalid_control_line}
    end;
line(#{generation := Generation} = State, <<"%exit">>) ->
    {ok, {exit, Generation, <<>>}, State#{exited := true}};
line(#{generation := Generation} = State, <<"%exit ", Reason/binary>>) ->
    {ok, {exit, Generation, Reason}, State#{exited := true}};
line(#{generation := Generation} = State, <<$%, _/binary>> = Line) ->
    [Name | _] = binary:split(Line, <<" ">>),
    case Name of
        <<"%begin">> -> {error, invalid_control_line};
        <<"%end">> -> {error, invalid_control_line};
        <<"%error">> -> {error, invalid_control_line};
        <<$%, First, Rest/binary>> when First >= $a, First =< $z ->
            case notification_name(Rest) of
                true -> {ok, {notification, Generation, Line}, State};
                false -> {error, invalid_control_line}
            end;
        _ -> {error, invalid_control_line}
    end;
line(_, _) -> {error, invalid_control_line}.

guard_fields(Fields) ->
    case binary:split(Fields, <<" ">>, [global]) of
        [T, N, F] ->
            case {decimal(T, 9223372036854775807), decimal(N, 4294967295), decimal(F, 2147483647)} of
                {{ok, Time}, {ok, Number}, {ok, Flags}} -> {ok, Time, Number, Flags};
                _ -> error
            end;
        _ -> error
    end.

decimal(Text, Maximum) when byte_size(Text) =< 20 ->
    try binary_to_integer(Text) of
        Number when Number >= 0, Number =< Maximum ->
            case integer_to_binary(Number) =:= Text of true -> {ok, Number}; false -> error end;
        _ -> error
    catch error:badarg -> error
    end;
decimal(_, _) -> error.

notification_name(<<>>) -> true;
notification_name(<<C, Rest/binary>>)
  when (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $- ->
    notification_name(Rest);
notification_name(_) -> false.

failure(State, Code, Events) -> {error, reason(State, Code), lists:reverse(Events)}.

reason(#{generation := Generation, block := Block}, Code) ->
    Guard = case Block of none -> none; {Value, _} -> Value end,
    #{code => Code, generation => Generation, guard => Guard}.
