-module(tmux_json).
-moduledoc """
Decode bounded JSON using OTP's `m:json` parser and binary object keys.

Documents are limited to 256 KiB before parsing and 32 nested containers
during parsing. Duplicate keys are rejected before overwriting values, even
when different escapes spell the same key. Trailing input is rejected. Numbers
stay in the shared exact integer range. Integral decimal tokens are converted
exactly; fractional tokens that round to integers are rejected. Field
validation decides whether a remaining float is permitted. Syntax and resource
errors have a root path; duplicate-key errors retain their complete document
path. Use `tmux_filter:from_wire/2` to validate decoded filter data.
""".
-export([decode/1]).
-define(MAX_BYTES, 262144).
-define(MAX_DEPTH, 32).
-define(MAX_INTEGER, 9007199254740991).

-doc """
Return a decoded value or a structured error without creating payload atoms.

```erlang
1> tmux_json:decode(<<"{\"a\": [1, true, null]}">>).
{ok,#{<<"a">> => [1,true,null]}}
2> tmux_json:decode(<<"{\"a\": {\"x\": 1, \"x\": 2}}">>).
{error,#{code => duplicate_key,path => [<<"a">>,<<"x">>]}}
3> tmux_json:decode(<<"[] []">>).
{error,#{code => trailing_input,path => []}}
```
""".
-spec decode(binary()) -> {ok, json:decode_value()} | {error, map()}.
decode(Binary) when is_binary(Binary), byte_size(Binary) > ?MAX_BYTES ->
    {error, #{code => document_limit, path => [], limit => ?MAX_BYTES}};
decode(Binary) when is_binary(Binary) ->
    Decoders = #{object_start => fun object_start/1, object_push => fun object_push/3,
                 object_finish => fun object_finish/2, array_start => fun array_start/1,
                 array_push => fun array_push/2, array_finish => fun array_finish/2,
                 integer => fun integer/1, float => fun float_value/1},
    try json:decode(Binary, #{depth => 0}, Decoders) of
        {{invalid_json, Detail}, _, _} -> {error, Detail};
        {Value, _, Rest} ->
            case whitespace(Rest) of
                true -> {ok, Value};
                false -> {error, #{code => trailing_input, path => []}}
            end
    catch
        throw:{invalid_json, Detail} -> {error, Detail};
        error:unexpected_end -> syntax(unexpected_end);
        error:{invalid_byte, _} -> syntax(invalid_byte);
        error:{unexpected_sequence, _} -> syntax(unexpected_sequence)
    end;
decode(_) -> {error, #{code => expected_binary, path => []}}.

object_start(Parent) -> start(Parent, #{}).
array_start(Parent) -> start(Parent, []).
start(#{depth := Depth}, Items) when Depth < ?MAX_DEPTH ->
    #{depth => Depth + 1, items => Items, index => 0, error => none};
start(_, _) -> reject(depth_limit).

object_push(Key, Value, #{items := Items, error := none} = Acc) ->
    case maps:is_key(Key, Items) of
        true -> Acc#{error => #{code => duplicate_key, path => [Key]}};
        false ->
            case Value of
                {invalid_json, Detail} -> Acc#{error => prepend(Key, Detail)};
                _ -> Acc#{items => Items#{Key => Value}}
            end
    end;
object_push(_, _, Acc) -> Acc.

array_push(Value, #{items := Items, index := Index, error := none} = Acc) ->
    case Value of
        {invalid_json, Detail} -> Acc#{error => prepend(Index, Detail)};
        _ -> Acc#{items => [Value | Items], index => Index + 1}
    end;
array_push(_, Acc) -> Acc.

object_finish(#{error := none, items := Items}, Parent) -> {Items, Parent};
object_finish(#{error := Detail}, Parent) -> {{invalid_json, Detail}, Parent}.
array_finish(#{error := none, items := Items}, Parent) -> {lists:reverse(Items), Parent};
array_finish(#{error := Detail}, Parent) -> {{invalid_json, Detail}, Parent}.
prepend(Key, #{path := Path} = Detail) -> Detail#{path => [Key | Path]}.

integer(Binary) when byte_size(Binary) =< 17 ->
    integer_value(binary_to_integer(Binary));
integer(_) -> invalid(number_out_of_range).

integer_value(Value) ->
    case is_integer(Value, -?MAX_INTEGER, ?MAX_INTEGER) of
        true -> Value;
        false -> invalid(number_out_of_range)
    end.

float_value(Binary) when byte_size(Binary) =< 128 ->
    case decimal_integer(Binary) of
        {integer, Integer} -> integer_value(Integer);
        out_of_range -> invalid(number_out_of_range);
        fractional ->
            try binary_to_float(Binary) of
                Value when Value < -?MAX_INTEGER; Value > ?MAX_INTEGER -> invalid(number_out_of_range);
                Value ->
                    case Value == trunc(Value) of
                        true -> invalid(nonintegral_number);
                        false -> Value
                    end
            catch error:badarg -> invalid(invalid_number)
            end
    end;
float_value(_) -> invalid(number_limit).

%% JSON supplies a validated token (and inserts .0 for exponent-only forms).
%% Bound the exponent before constructing powers; a large negative exponent
%% cannot make a nonzero coefficient integral.
decimal_integer(Binary) ->
    {Mantissa, Exponent} = case binary:split(Binary, [<<"e">>, <<"E">>]) of
        [M] -> {M, 0};
        [M, E] -> {M, binary_to_integer(E)}
    end,
    [Whole, Fraction] = binary:split(Mantissa, <<".">>),
    Digits = <<Whole/binary, Fraction/binary>>,
    Coefficient = binary_to_integer(Digits),
    Scale = Exponent - byte_size(Fraction),
    case {Coefficient, Scale} of
        {0, _} -> {integer, 0};
        {_, N} when N > 16 -> out_of_range;
        {C, N} when N >= 0 -> {integer, C * power10(N)};
        {_, N} when -N > byte_size(Digits) -> fractional;
        {C, N} ->
            Divisor = power10(-N),
            case C rem Divisor of
                0 -> {integer, C div Divisor};
                _ -> fractional
            end
    end.
power10(0) -> 1;
power10(N) -> 10 * power10(N - 1).

whitespace(<<>>) -> true;
whitespace(<<C, Rest/binary>>) when C =:= 32; C =:= 9; C =:= 10; C =:= 13 -> whitespace(Rest);
whitespace(_) -> false.
syntax(Reason) -> {error, #{code => invalid_json, path => [], reason => Reason}}.
invalid(Code) -> {invalid_json, #{code => Code, path => []}}.
-spec reject(atom()) -> no_return().
reject(Code) -> throw({invalid_json, #{code => Code, path => []}}).
