-module(docs_util).
-moduledoc """
Path, URL, HTML and JSON helpers shared by `check_docs` and `build_docs`.

Paths and text are UTF-8 binaries. A JSON object whose key order matters is
`{object, [{Key, Value}]}`. `json_text/1` writes it with two-space indentation
and ASCII-only strings, so receipts stay diffable against earlier ones.
""".
-export([wildcard/2, resolve/1, is_within/2, relative_to/2, relative_path/2, urlsplit/1,
         unquote/1, quote/2, escape/1, unescape/1, splitlines/1, replace/4,
         json_text/1, read_ordered_json/1, write_file/2]).
-export_type([json/0, url/0]).

-type json() :: null | boolean() | integer() | float() | binary() | [json()]
              | {object, [{binary(), json()}]}.
-type url() :: #{scheme := binary(), netloc := binary(), path := binary(),
                 query := binary(), fragment := binary()}.

-define(MAX_LINKS, 40).

-doc "Paths below `Root` that match `Pattern`, relative to `Root` and ordered by component.".
-spec wildcard(file:filename_all(), string()) -> [binary()].
wildcard(Root, Pattern) ->
    Found = [unicode:characters_to_binary(Path)
             || Path <- filelib:wildcard(Pattern, unicode:characters_to_list(Root))],
    lists:sort(fun(A, B) -> filename:split(A) =< filename:split(B) end, Found).

-doc """
Absolute path with `.`, `..` and symbolic links resolved. Components that do
not exist stay as written.
""".
-spec resolve(file:filename_all()) -> binary().
resolve(Path) ->
    Absolute = unicode:characters_to_binary(filename:absname(Path)),
    [Top | Parts] = filename:split(Absolute),
    resolve_parts(Parts, [Top], 0).

resolve_parts(_, _, Links) when Links > ?MAX_LINKS -> error(symlink_loop);
resolve_parts([], Stack, _) -> filename:join(lists:reverse(Stack));
resolve_parts([<<".">> | Rest], Stack, Links) -> resolve_parts(Rest, Stack, Links);
resolve_parts([<<"..">> | Rest], [_] = Stack, Links) -> resolve_parts(Rest, Stack, Links);
resolve_parts([<<"..">> | Rest], [_ | Up], Links) -> resolve_parts(Rest, Up, Links);
resolve_parts([Part | Rest], Stack, Links) ->
    Candidate = filename:join(lists:reverse([Part | Stack])),
    case file:read_link_all(Candidate) of
        {ok, Target} ->
            [First | More] = filename:split(unicode:characters_to_binary(Target)),
            case filename:pathtype(First) of
                absolute -> resolve_parts(More ++ Rest, [First], Links + 1);
                _ -> resolve_parts([First | More] ++ Rest, Stack, Links + 1)
            end;
        {error, _} -> resolve_parts(Rest, [Part | Stack], Links)
    end.

-doc "Whether the resolved `Path` is `Root` or lies below it.".
-spec is_within(binary(), binary()) -> boolean().
is_within(Root, Path) ->
    lists:prefix(filename:split(Root), filename:split(Path)).

-doc "The POSIX path of `Path` below `Root`, `.` for `Root` itself.".
-spec relative_to(binary(), binary()) -> binary().
relative_to(Path, Root) ->
    case lists:nthtail(length(filename:split(Root)), filename:split(Path)) of
        [] -> <<".">>;
        Parts -> filename:join(Parts)
    end.

-doc "Path from directory `Start` to `Target`; both are absolute and normalized.".
-spec relative_path(binary(), binary()) -> binary().
relative_path(Target, Start) ->
    {From, To} = drop_common(filename:split(Start), filename:split(Target)),
    case [<<"..">> || _ <- From] ++ To of
        [] -> <<".">>;
        Parts -> filename:join(Parts)
    end.

drop_common([Part | From], [Part | To]) -> drop_common(From, To);
drop_common(From, To) -> {From, To}.

-doc """
Split a URL into scheme, network location, path, query and fragment. Leading
controls and spaces, and every tab and newline, are removed first, and the
scheme is lower-cased. A part the URL lacks is an empty binary.
""".
-spec urlsplit(binary()) -> url().
urlsplit(Url) ->
    Cleaned = binary:replace(string:trim(Url, leading, lists:seq(0, 32)),
                             [<<"\t">>, <<"\r">>, <<"\n">>], <<>>, [global]),
    {Scheme, Rest} = case re:run(Cleaned, "^([A-Za-z][A-Za-z0-9+.\\-]*):",
                                 [{capture, all, binary}]) of
        {match, [Prefix, Name]} ->
            {string:lowercase(Name), binary:part(Cleaned, byte_size(Prefix),
                                                 byte_size(Cleaned) - byte_size(Prefix))};
        nomatch -> {<<>>, Cleaned}
    end,
    {Netloc, Remainder} = case Rest of
        <<"//", After/binary>> -> split_first(After, <<"/?#">>);
        _ -> {<<>>, Rest}
    end,
    {WithoutFragment, Fragment} = split_at(Remainder, <<"#">>),
    {Path, Query} = split_at(WithoutFragment, <<"?">>),
    #{scheme => Scheme, netloc => Netloc, path => Path, query => Query,
      fragment => Fragment}.

split_at(Binary, Separator) ->
    case binary:split(Binary, Separator) of
        [Head, Tail] -> {Head, Tail};
        [Head] -> {Head, <<>>}
    end.

split_first(Binary, Delimiters) ->
    case binary:match(Binary, [<<C>> || <<C>> <= Delimiters]) of
        {Position, _} -> {binary:part(Binary, 0, Position),
                          binary:part(Binary, Position, byte_size(Binary) - Position)};
        nomatch -> {Binary, <<>>}
    end.

-doc "Decode `%XX` escapes as UTF-8; invalid sequences become U+FFFD.".
-spec unquote(binary()) -> binary().
unquote(Binary) -> utf8(unquote_bytes(Binary)).

unquote_bytes(<<$%, High, Low, Rest/binary>>) ->
    case {hex(High), hex(Low)} of
        {H, L} when is_integer(H), is_integer(L) ->
            <<(H * 16 + L), (unquote_bytes(Rest))/binary>>;
        _ -> <<$%, (unquote_bytes(<<High, Low, Rest/binary>>))/binary>>
    end;
unquote_bytes(<<Byte, Rest/binary>>) -> <<Byte, (unquote_bytes(Rest))/binary>>;
unquote_bytes(<<>>) -> <<>>.

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(_) -> error.

utf8(Bytes) ->
    case unicode:characters_to_binary(Bytes) of
        Valid when is_binary(Valid) -> Valid;
        {error, Valid, <<_, Rest/binary>>} -> <<Valid/binary, 16#FFFD/utf8, (utf8(Rest))/binary>>;
        {incomplete, Valid, _} -> <<Valid/binary, 16#FFFD/utf8>>
    end.

-doc """
Percent-encode the UTF-8 bytes of `Binary`, keeping letters, digits, `_.-~`
and the bytes of `Safe`.
""".
-spec quote(binary(), binary()) -> binary().
quote(Binary, Safe) ->
    << <<(quote_byte(Byte, Safe))/binary>> || <<Byte>> <= Binary >>.

quote_byte(Byte, _) when Byte >= $a, Byte =< $z; Byte >= $A, Byte =< $Z;
                         Byte >= $0, Byte =< $9; Byte =:= $_; Byte =:= $.;
                         Byte =:= $-; Byte =:= $~ -> <<Byte>>;
quote_byte(Byte, Safe) ->
    case binary:match(Safe, <<Byte>>) of
        nomatch -> <<$%, (binary:encode_hex(<<Byte>>))/binary>>;
        _ -> <<Byte>>
    end.

-doc "Escape `& < > \"` and `'`, writing the apostrophe as `&#x27;`.".
-spec escape(binary()) -> binary().
escape(Binary) ->
    << <<(escape_byte(Byte))/binary>> || <<Byte>> <= Binary >>.

escape_byte($&) -> <<"&amp;">>;
escape_byte($<) -> <<"&lt;">>;
escape_byte($>) -> <<"&gt;">>;
escape_byte($") -> <<"&quot;">>;
escape_byte($') -> <<"&#x27;">>;
escape_byte(Byte) -> <<Byte>>.

-doc """
Decode numeric character references and the named references `amp`, `lt`,
`gt`, `quot`, `apos` and `nbsp`. Other named references stay as written.
""".
-spec unescape(binary()) -> binary().
unescape(Binary) ->
    case binary:match(Binary, <<"&">>) of
        nomatch -> Binary;
        _ ->
            {Text, ok} = replace("&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);", Binary,
                fun([Whole, Name], ok) -> {reference(Name, Whole), ok} end, ok),
            Text
    end.

reference(<<"#", Digits/binary>>, Whole) ->
    Code = case Digits of
        <<X, Hex/binary>> when X =:= $x; X =:= $X -> binary_to_integer(Hex, 16);
        _ -> binary_to_integer(Digits)
    end,
    case Code of
        0 -> <<16#FFFD/utf8>>;
        _ when Code > 16#10FFFF; Code >= 16#D800, Code =< 16#DFFF -> <<16#FFFD/utf8>>;
        _ -> try <<Code/utf8>> catch error:_ -> Whole end
    end;
reference(<<"amp">>, _) -> <<"&">>;
reference(<<"lt">>, _) -> <<"<">>;
reference(<<"gt">>, _) -> <<">">>;
reference(<<"quot">>, _) -> <<"\"">>;
reference(<<"apos">>, _) -> <<"'">>;
reference(<<"nbsp">>, _) -> <<16#A0/utf8>>;
reference(_, Whole) -> Whole.

-doc """
Split text into lines at `\r\n` and at a lone `\n` or `\r`, vertical tab, form
feed, U+001C to U+001E, U+0085, U+2028 and U+2029, with no final empty line.
""".
-spec splitlines(binary()) -> [binary()].
splitlines(Binary) ->
    Parts = re:split(Binary, "\r\n|[\n\r\v\f\x1c-\x1e\x{85}\x{2028}\x{2029}]",
                     [unicode, {return, binary}]),
    case lists:reverse(Parts) of
        [<<>> | Lines] -> lists:reverse(Lines);
        _ -> Parts
    end.

-doc """
Replace every match of `Pattern` in `Subject`. `Fun` receives the whole match
and each capture group and returns the replacement and the new accumulator.
""".
-spec replace(iodata(), binary(), fun(([binary()], Acc) -> {iodata(), Acc}), Acc) ->
    {binary(), Acc}.
replace(Pattern, Subject, Fun, Acc) ->
    {ok, Compiled} = re:compile(Pattern, [unicode]),
    case re:run(Subject, Compiled, [global, {capture, all, index}]) of
        nomatch -> {Subject, Acc};
        {match, Matches} -> splice(Matches, Subject, 0, Fun, Acc, [])
    end.

splice([], Subject, Position, _, Acc, Out) ->
    Tail = binary:part(Subject, Position, byte_size(Subject) - Position),
    {iolist_to_binary(lists:reverse([Tail | Out])), Acc};
splice([[{Start, Length} | Groups] | More], Subject, Position, Fun, Acc, Out) ->
    Texts = [binary:part(Subject, S, L) || {S, L} <- [{Start, Length} | Groups]],
    {Replacement, Next} = Fun(Texts, Acc),
    Before = binary:part(Subject, Position, Start - Position),
    splice(More, Subject, Start + Length, Fun, Next, [Replacement, Before | Out]).

-doc """
JSON text of `Value` with two-space indentation and ASCII-only strings. Writes
no trailing newline.
""".
-spec json_text(json()) -> binary().
json_text(Value) -> iolist_to_binary(encode(Value, 0)).

encode({object, []}, _) -> <<"{}">>;
encode({object, Pairs}, Depth) ->
    Members = [[indent(Depth + 1), string(Key), <<": ">>, encode(Value, Depth + 1)]
               || {Key, Value} <- Pairs],
    [<<"{\n">>, lists:join(<<",\n">>, Members), $\n, indent(Depth), $}];
encode([], _) -> <<"[]">>;
encode(List, Depth) when is_list(List) ->
    Items = [[indent(Depth + 1), encode(Item, Depth + 1)] || Item <- List],
    [<<"[\n">>, lists:join(<<",\n">>, Items), $\n, indent(Depth), $]];
encode(Text, _) when is_binary(Text) -> string(Text);
encode(Number, _) when is_integer(Number) -> integer_to_binary(Number);
encode(Number, _) when is_float(Number) -> float_to_binary(Number, [short]);
encode(Atom, _) when Atom =:= true; Atom =:= false; Atom =:= null -> atom_to_binary(Atom).

indent(Depth) -> binary:copy(<<"  ">>, Depth).

string(Text) -> [$", [escape_character(C) || <<C/utf8>> <= Text], $"].

escape_character($") -> <<"\\\"">>;
escape_character($\\) -> <<"\\\\">>;
escape_character($\n) -> <<"\\n">>;
escape_character($\r) -> <<"\\r">>;
escape_character($\t) -> <<"\\t">>;
escape_character($\b) -> <<"\\b">>;
escape_character($\f) -> <<"\\f">>;
escape_character(C) when C >= 32, C =< 126 -> C;
escape_character(C) when C < 16#10000 -> unicode_escape(C);
escape_character(C) ->
    Offset = C - 16#10000,
    [unicode_escape(16#D800 + (Offset bsr 10)), unicode_escape(16#DC00 + (Offset band 16#3FF))].

unicode_escape(C) -> string:lowercase(iolist_to_binary(io_lib:format("\\u~4.16.0B", [C]))).

-doc "Decode a JSON file; objects become `{object, Pairs}` in file order.".
-spec read_ordered_json(file:filename_all()) -> json().
read_ordered_json(Path) ->
    {ok, Binary} = file:read_file(Path),
    Decoders = #{object_start => fun(Parent) -> {Parent, []} end,
                 object_push => fun(Key, Value, {Parent, Pairs}) ->
                     {Parent, [{Key, Value} | Pairs]}
                 end,
                 object_finish => fun({Parent, Pairs}, _) ->
                     {{object, lists:reverse(Pairs)}, Parent}
                 end},
    {Value, ok, <<>>} = json:decode(Binary, ok, Decoders),
    Value.

-doc "Write a file, creating missing parent directories.".
-spec write_file(file:filename_all(), iodata()) -> ok.
write_file(Path, Data) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Data).
