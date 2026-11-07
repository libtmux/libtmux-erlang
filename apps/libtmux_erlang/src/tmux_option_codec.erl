-module(tmux_option_codec).
-moduledoc false.
-export([array/2, decode/4]).

-spec decode(binary(), binary(), map(), tmux_version:t()) ->
    {ok, binary() | map()} | none | {error, map()}.
decode(_, <<>>, _, _) -> none;
decode(Name, Output, #{array := Array, type := Type}, Version) ->
    %% tmux 3.4/3.5 print -v values through a lossy VIS_NOSLASH layer.
    %% Request named/quoted values instead. Its printable payload survives
    %% that layer; 3.4 additionally inserts a slash before dollar variables.
    Mode = print_mode(Version),
    Normalized = case Mode of dollars -> undo_dollars(Output, []); _ -> Output end,
    case Array of
        true -> array(Name, Normalized);
        false ->
            maybe
                {ok, Line} ?= scalar(Normalized),
                {ok, Tail} ?= strip_name(Name, Line, Mode),
                case Tail of
                    <<$\s, Value/binary>> -> scalar_value(Type, Value);
                    <<$*, $\s, Value/binary>> -> scalar_value(Type, Value);
                    _ -> invalid()
                end
            end
    end.

scalar_value(string, Value) -> value(Value);
scalar_value(_, Value) -> {ok, binary:copy(Value)}.

print_mode(#{major := 3, minor := 4}) -> dollars;
print_mode(#{major := 3, minor := 5}) -> vis;
print_mode(_) -> raw.

undo_dollars(<<>>, Acc) -> list_to_binary(lists:reverse(Acc));
undo_dollars(<<$\\, $$, Next, Rest/binary>>, Acc)
  when Next >= $a, Next =< $z; Next >= $A, Next =< $Z; Next =:= $_; Next =:= ${ ->
    undo_dollars(<<Next, Rest/binary>>, [$$ | Acc]);
undo_dollars(<<C, Rest/binary>>, Acc) -> undo_dollars(Rest, [C | Acc]).

%% Match only the requested name's bytes. Legacy tmux builds can differ in
%% which UTF-8 sequences they copy; accept raw or VIS bytes without inventing
%% another Unicode policy. The following table delimiter must still match.
strip_name(<<>>, Output, _) -> {ok, Output};
strip_name(<<C, Name/binary>>, <<C, Output/binary>>, Mode) ->
    strip_name(Name, Output, Mode);
strip_name(<<C, Name/binary>>, Output, Mode) when Mode =/= raw ->
    Encoded = iolist_to_binary([printed_byte(C)]),
    Size = byte_size(Encoded),
    case Output of
        <<Encoded:Size/binary, Rest/binary>> -> strip_name(Name, Rest, Mode);
        _ -> invalid()
    end;
strip_name(_, _, _) -> invalid().

printed_byte(C) when C >= 32, C =< 126; C =:= $\t; C =:= $\n -> C;
printed_byte(7) -> <<"\\a">>;
printed_byte(8) -> <<"\\b">>;
printed_byte(11) -> <<"\\v">>;
printed_byte(12) -> <<"\\f">>;
printed_byte(13) -> <<"\\r">>;
printed_byte(C) ->
    <<$\\, ($0 + (C bsr 6)), ($0 + ((C bsr 3) band 7)), ($0 + (C band 7))>>.

-spec scalar(binary()) -> {ok, binary()} | none | {error, map()}.
scalar(<<>>) -> none;
scalar(Output) ->
    case binary:last(Output) of
        $\n -> {ok, binary:copy(binary:part(Output, 0, byte_size(Output) - 1))};
        _ -> invalid()
    end.

-spec array(binary(), binary()) -> {ok, #{non_neg_integer() => binary()}} |
    none | {error, map()}.
array(_, <<>>) -> none;
array(Name, Output) ->
    case binary:last(Output) of
        $\n -> lines(Name, binary:split(Output, <<"\n">>, [global]), #{});
        _ -> invalid()
    end.

lines(_, [<<>>], Entries) -> {ok, Entries};
lines(Name, [Name, <<>>], Entries) when map_size(Entries) =:= 0 -> {ok, #{}};
lines(Name, [Line | Rest], Entries) ->
    PrefixSize = byte_size(Name),
    case Line of
        <<Name:PrefixSize/binary, $[, Tail/binary>> ->
            maybe
                {ok, Index, Escaped} ?= entry(Tail),
                false ?= maps:is_key(Index, Entries),
                {ok, Value} ?= value(Escaped),
                lines(Name, Rest, Entries#{Index => Value})
            else
                _ -> invalid()
            end;
        _ -> invalid()
    end;
lines(_, _, _) -> invalid().

entry(Tail) ->
    case binary:split(Tail, <<"]">>) of
        [Digits, <<$*, $\s, Value/binary>>] -> index(Digits, Value);
        [Digits, <<$\s, Value/binary>>] -> index(Digits, Value);
        _ -> invalid()
    end.

index(Digits, Value) when byte_size(Digits) > 0, byte_size(Digits) =< 10 ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)) of
        true ->
            Index = binary_to_integer(Digits),
            case Index =< 2147483647 of
                true -> {ok, Index, Value};
                false -> invalid()
            end;
        false -> invalid()
    end;
index(_, _) -> invalid().

%% Invert args_escape/utf8_stravis as bytes. Never pass output to a parser,
%% shell, format expander or environment interpolator.
value(<<Quote, Rest/binary>>) when Quote =:= $'; Quote =:= $" ->
    case byte_size(Rest) > 0 andalso binary:last(Rest) =:= Quote of
        true -> unescape(binary:part(Rest, 0, byte_size(Rest) - 1), []);
        false -> invalid()
    end;
value(<<>>) -> invalid();
value(Bytes) -> unescape(Bytes, []).

unescape(<<>>, Acc) -> {ok, list_to_binary(lists:reverse(Acc))};
unescape(<<$\\, A, B, C, Rest/binary>>, Acc)
  when A >= $0, A =< $3, B >= $0, B =< $7, C >= $0, C =< $7 ->
    Byte = (A - $0) * 64 + (B - $0) * 8 + C - $0,
    case Byte of 0 -> invalid(); _ -> unescape(Rest, [Byte | Acc]) end;
unescape(<<$\\, C, Rest/binary>>, Acc) ->
    case escaped(C) of
        invalid -> invalid();
        Byte -> unescape(Rest, [Byte | Acc])
    end;
unescape(<<$\\>>, _) -> invalid();
unescape(<<0, _/binary>>, _) -> invalid();
unescape(<<C, Rest/binary>>, Acc) -> unescape(Rest, [C | Acc]).

escaped($a) -> 7;
escaped($b) -> 8;
escaped($f) -> 12;
escaped($n) -> 10;
escaped($r) -> 13;
escaped($s) -> 32;
escaped($t) -> 9;
escaped($v) -> 11;
escaped(C) when C =:= $\\; C =:= $"; C =:= $'; C =:= $~; C =:= $\s;
                C =:= $#; C =:= $;; C =:= $$; C =:= ${; C =:= $}; C =:= $% -> C;
escaped(_) -> invalid.

invalid() -> {error, #{code => invalid_observation, entity => option}}.
