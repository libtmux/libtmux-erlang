-module(generate_json).
-moduledoc """
JSON that keeps object key order, written the way Python's
`json.dumps(value, indent=2)` writes it.

An object is a non-empty list of `{Key, Value}` pairs with binary keys; an
empty object is `#{}` and an empty array is `[]`. Strings are binaries, `null`,
`true` and `false` are atoms. A map with entries has no stable order, so
`encode/1` rejects it.
""".
-export([decode/1, encode/1, encode_string/1]).
-export_type([json/0]).

-type json() :: null | boolean() | integer() | binary() | #{} | [json()]
              | [{binary(), json()}].

-doc "Parse JSON text. Raises on invalid text or trailing data.".
-spec decode(binary()) -> json().
decode(Text) ->
    Finish = fun(Members, Outer) -> {object(lists:reverse(Members)), Outer} end,
    {Value, ok, Rest} = json:decode(Text, ok, #{object_finish => Finish}),
    case string:trim(Rest, both, " \t\r\n") of
        <<>> -> Value;
        _ -> error({trailing_data, Rest})
    end.

-doc """
Render `Value` with two-space indentation and no trailing newline. Raises on a
float, an atom other than `null`, `true` or `false`, or a non-empty map.
""".
-spec encode(json()) -> iodata().
encode(Value) -> encode(Value, 0).

-doc "Render a binary as a quoted JSON string with every non-ASCII character escaped.".
-spec encode_string(binary()) -> iodata().
encode_string(Text) ->
    [$", escape(Text), $"].

object([]) -> #{};
object(Members) -> Members.

encode(null, _) -> <<"null">>;
encode(true, _) -> <<"true">>;
encode(false, _) -> <<"false">>;
encode(Number, _) when is_integer(Number) -> integer_to_binary(Number);
encode(Text, _) when is_binary(Text) -> encode_string(Text);
encode([], _) -> <<"[]">>;
encode(Empty, _) when is_map(Empty), map_size(Empty) =:= 0 -> <<"{}">>;
encode([{_, _} | _] = Members, Depth) ->
    Inner = indent(Depth + 1),
    Items = [[encode_string(Key), ": ", encode(Value, Depth + 1)] || {Key, Value} <- Members],
    ["{\n", Inner, lists:join([",\n", Inner], Items), "\n", indent(Depth), "}"];
encode(Elements, Depth) when is_list(Elements) ->
    Inner = indent(Depth + 1),
    Items = [encode(Element, Depth + 1) || Element <- Elements],
    ["[\n", Inner, lists:join([",\n", Inner], Items), "\n", indent(Depth), "]"].

indent(Depth) -> binary:copy(<<"  ">>, Depth).

escape(<<>>) -> [];
escape(<<$", Rest/binary>>) -> [<<"\\\"">> | escape(Rest)];
escape(<<$\\, Rest/binary>>) -> [<<"\\\\">> | escape(Rest)];
escape(<<$\b, Rest/binary>>) -> [<<"\\b">> | escape(Rest)];
escape(<<$\f, Rest/binary>>) -> [<<"\\f">> | escape(Rest)];
escape(<<$\n, Rest/binary>>) -> [<<"\\n">> | escape(Rest)];
escape(<<$\r, Rest/binary>>) -> [<<"\\r">> | escape(Rest)];
escape(<<$\t, Rest/binary>>) -> [<<"\\t">> | escape(Rest)];
escape(<<Char/utf8, Rest/binary>>) when Char >= 16#20, Char =< 16#7e ->
    [Char | escape(Rest)];
escape(<<Char/utf8, Rest/binary>>) when Char < 16#10000 ->
    [unicode_escape(Char) | escape(Rest)];
escape(<<Char/utf8, Rest/binary>>) ->
    Offset = Char - 16#10000,
    High = 16#d800 bor (Offset bsr 10),
    Low = 16#dc00 bor (Offset band 16#3ff),
    [unicode_escape(High), unicode_escape(Low) | escape(Rest)];
escape(Invalid) -> error({invalid_utf8, Invalid}).

unicode_escape(Code) ->
    io_lib:format("\\u~4.16.0b", [Code]).
