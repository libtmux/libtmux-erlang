-module(tmux_text_codec).
-moduledoc false.
-export([argument/1, format/2, print_layer/2, field_format/1, columns/4]).

%% Expand a field once, then escape the three framing bytes. A separate
%% length expansion could observe a different process cwd or command.
-spec field_format(binary()) -> binary().
field_format(Field) ->
    <<"#{s|\\\\|\\\\\\\\|;s|\t|\\\\t|;s|\n|\\\\n|:", Field/binary, "}">>.

-spec columns(binary(), tmux_version:t(), pos_integer(), pos_integer()) ->
    {ok, [[binary()]]} | {error, map()}.
columns(<<>>, _, _, _) -> {ok, []};
columns(Bytes, Version, Count, Limit) ->
    {Mode, Output} = print_layer(Bytes, Version),
    Kind = case Mode of raw -> columns_raw; _ -> format_vis end,
    Size = byte_size(Output) - 1,
    case Output of
        <<Body:Size/binary, $\n>> ->
            Lines = binary:split(Body, <<"\n">>, [global]),
            case length(Lines) =< Limit of
                true -> column_lines(Lines, Kind, Count, []);
                false -> {error, #{code => capture_limit, limit => max_rows}}
            end;
        _ -> invalid()
    end.

column_lines([], _, _, Acc) -> {ok, lists:reverse(Acc)};
column_lines([Line | Rest], Kind, Count, Acc) ->
    Parts = binary:split(Line, <<"\t">>, [global]),
    case length(Parts) =:= Count of
        true ->
            maybe
                {ok, Values} ?= column_values(Parts, Kind, []),
                column_lines(Rest, Kind, Count, [Values | Acc])
            end;
        false -> invalid()
    end.

column_values([], _, Acc) -> {ok, lists:reverse(Acc)};
column_values([Part | Rest], Kind, Acc) ->
    maybe
        {ok, Value} ?= unescape(Part, Kind, []),
        column_values(Rest, Kind, [Value | Acc])
    end.

%% These modes describe cmdq_print on the pinned tmux releases, not a
%% general stdout codec. Callers must request reversible quoting first.
-spec print_layer(binary(), tmux_version:t()) ->
    {raw | vis | dollars, binary()}.
print_layer(Bytes, Version) ->
    Mode = print_mode(Version),
    Output = case Mode of dollars -> undo_dollars(Bytes, []); _ -> Bytes end,
    {Mode, Output}.

%% q: doubles literal backslashes before the legacy VIS_NOSLASH print
%% layer, preserving the distinction between control bytes and text escapes.
-spec format(binary(), tmux_version:t()) -> {ok, binary()} | {error, map()}.
format(Bytes, Version) ->
    {Mode, Output} = print_layer(Bytes, Version),
    Kind = case Mode of raw -> format_raw; _ -> format_vis end,
    unescape(Output, Kind, []).

print_mode(#{major := 3, minor := 4}) -> dollars;
print_mode(#{major := 3, minor := 5}) -> vis;
print_mode(_) -> raw.

undo_dollars(<<>>, Acc) -> list_to_binary(lists:reverse(Acc));
undo_dollars(<<$\\, $$, Next, Rest/binary>>, Acc)
  when Next >= $a, Next =< $z; Next >= $A, Next =< $Z; Next =:= $_; Next =:= ${ ->
    undo_dollars(<<Next, Rest/binary>>, [$$ | Acc]);
undo_dollars(<<C, Rest/binary>>, Acc) -> undo_dollars(Rest, [C | Acc]).

%% Invert args_escape/utf8_stravis as bytes. Never pass output to a parser,
%% shell, format expander or environment interpolator.
-spec argument(binary()) -> {ok, binary()} | {error, map()}.
argument(<<Quote, Rest/binary>>) when Quote =:= $'; Quote =:= $" ->
    case byte_size(Rest) > 0 andalso binary:last(Rest) =:= Quote of
        true -> unescape(binary:part(Rest, 0, byte_size(Rest) - 1), argument, []);
        false -> invalid()
    end;
argument(<<>>) -> invalid();
argument(Bytes) -> unescape(Bytes, argument, []).

unescape(<<>>, _, Acc) -> {ok, list_to_binary(lists:reverse(Acc))};
unescape(<<$\\, A, B, C, Rest/binary>>, Kind, Acc)
  when Kind =/= format_raw, Kind =/= columns_raw,
       A >= $0, A =< $3, B >= $0, B =< $7, C >= $0, C =< $7 ->
    Byte = (A - $0) * 64 + (B - $0) * 8 + C - $0,
    case Byte of 0 -> invalid(); _ -> unescape(Rest, Kind, [Byte | Acc]) end;
unescape(<<$\\, C, Rest/binary>>, Kind, Acc) ->
    case escaped(C, Kind) of
        invalid -> invalid();
        Byte -> unescape(Rest, Kind, [Byte | Acc])
    end;
unescape(<<$\\>>, _, _) -> invalid();
unescape(<<0, _/binary>>, _, _) -> invalid();
unescape(<<C, Rest/binary>>, Kind, Acc) -> unescape(Rest, Kind, [C | Acc]).

argument_escape($a) -> 7;
argument_escape($b) -> 8;
argument_escape($f) -> 12;
argument_escape($n) -> 10;
argument_escape($r) -> 13;
argument_escape($s) -> 32;
argument_escape($t) -> 9;
argument_escape($v) -> 11;
argument_escape(C) when C =:= $\\; C =:= $"; C =:= $'; C =:= $~; C =:= $\s;
                C =:= $#; C =:= $;; C =:= $$; C =:= ${; C =:= $}; C =:= $% -> C;
argument_escape(_) -> invalid.

escaped(C, argument) -> argument_escape(C);
escaped($n, columns_raw) -> $\n;
escaped($t, columns_raw) -> $\t;
escaped($\\, columns_raw) -> $\\;
escaped(_, columns_raw) -> invalid;
escaped(C, format_raw) -> format_escape(C);
escaped(C, format_vis) ->
    case format_escape(C) of
        invalid -> argument_escape(C);
        Byte -> Byte
    end.

format_escape(C) when C =:= $|; C =:= $&; C =:= $;; C =:= $<; C =:= $>;
    C =:= $(; C =:= $); C =:= ${; C =:= $}; C =:= $$; C =:= $`;
    C =:= $\\; C =:= $"; C =:= $'; C =:= $*; C =:= $?; C =:= $[;
    C =:= $#; C =:= $\s; C =:= $=; C =:= $%; C =:= $\n; C =:= $\t -> C;
format_escape(_) -> invalid.

invalid() -> {error, #{code => invalid_observation, entity => text}}.
