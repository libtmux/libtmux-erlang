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
    {Mode, Normalized} = tmux_text_codec:print_layer(Output, Version),
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

value(Bytes) ->
    case tmux_text_codec:argument(Bytes) of
        {error, _} -> invalid();
        Decoded -> Decoded
    end.

invalid() -> {error, #{code => invalid_observation, entity => option}}.
