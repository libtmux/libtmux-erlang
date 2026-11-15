%% Generate the deterministic regex fixture test/fixtures/regex-v1.json.
%% Usage: escript scripts/regex/generate_fixture.erl [--check]
%%
%% Explicit edge cases come first, then 100 generated expressions whose
%% expected results come from a position-set matching oracle. The generator
%% draws from a Mersenne Twister seeded as Python's random module seeds it,
%% so the committed fixture stays byte for byte stable.
-module(generate_fixture).
-mode(compile).
-export([main/1, fixture/0, render/1, rng_new/1, rng_bits/2, rng_below/2,
         oracle/2, spelling/1]).
-export_type([rng/0, tree/0]).

-define(SEED, 2912).
-define(N, 624).
-define(M, 397).
-define(TARGET, "test/fixtures/regex-v1.json").

-opaque rng() :: {array:array(non_neg_integer()), non_neg_integer()}.
-type tree() :: {lit, 0..255} | {set, [0..255]} | dot | start | 'end'
              | {seq, [tree()]} | {alt, [tree()]} | {rep, tree(), 0..3, 0..3}.
-type expected() :: boolean() | atom().
-type pattern() :: {string(), [{string(), expected()}]}.

-spec main([string()]) -> no_return().
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    Check = case Arguments of
        [] -> false;
        ["--check"] -> true;
        _ ->
            io:format(standard_error, "usage: generate_fixture.erl [--check]~n", []),
            halt(2)
    end,
    Target = filename:join(Root, ?TARGET),
    Rendered = render(fixture()),
    case Check of
        true ->
            case file:read_file(Target) of
                {ok, Rendered} -> ok;
                _ ->
                    io:format(standard_error,
                        "Regex fixture drift: run scripts/regex/generate_fixture.erl~n", []),
                    halt(1)
            end;
        false -> ok = file:write_file(Target, Rendered)
    end,
    io:format("PASS: ~B reproducible regex patterns~n", [length(patterns())]),
    halt(0).

%% Fixture data

-spec fixture() -> term().
fixture() ->
    {obj, [{version, 1}, {dialect, <<"portable_v1">>},
           {semantics, {obj, [{subjects, <<"ASCII bytes">>},
                              {anchors, <<"absolute start/end">>},
                              {dot, <<"all ASCII bytes except LF">>},
                              {repetition_max, 64}]}},
           {patterns, [pattern(P) || P <- patterns()]}]}.

pattern({Pattern, Cases}) ->
    {obj, [{pattern, text(Pattern)},
           {cases, [{obj, [{subject, text(Subject)}, {expected, Expected}]}
                    || {Subject, Expected} <- Cases]}]}.

-spec patterns() -> [pattern()].
patterns() -> explicit() ++ generated().

explicit() ->
    [{"", [{"", true}, {"a", true}]},
     {"^a$", [{"a", true}, {"a\n", false}, {"ba", false}, {"", false}]},
     {"^.$", [{"\r", true}, {"\n", false}, {"\0", true}, {"\x7f", true}, {"ab", false}]},
     {"a$", [{"ba", true}, {"a\n", false}, {"a\r", false}]},
     {"^a|b$", [{"az", true}, {"zb", true}, {"zabz", false}]},
     {"^[a-z0-9_-]{1,4}$", [{"a-2", true}, {"_", true}, {"", false},
                            {"abcdz", false}, {"A", false}]},
     {"^[^a-z]{1,2}$", [{"1\n", true}, {"\r", true}, {"a", false}, {"1a", false}]},
     {"^a{0,2}$", [{"", true}, {"a", true}, {"aa", true}, {"aaa", false}]},
     {"^a{64}$", [{lists:duplicate(64, $a), true}, {lists:duplicate(63, $a), false},
                  {lists:duplicate(65, $a), false}]},
     {"^(ab|c){1,2}$", [{"ab", true}, {"cc", true}, {"abc", true}, {"abab", true},
                        {"", false}, {"abcc", false}]},
     {"^(|a)b$", [{"b", true}, {"ab", true}, {"aab", false}]},
     {"^(){2}$", [{"", true}, {"a", false}]},
     {"^[\\x00-\\x7f]$", [{"\0", true}, {"\n", true}, {"\x7f", true}, {"", false}]},
     {"^[^\\x00-\\x7f]$", [{"", false}, {"a", false}]},
     {"^\\.\\[\\]\\{\\}\\(\\)\\|\\^\\$\\\\$", [{".[]{}()|^$\\", true}, {".", false}]},
     {"^[\\]\\-\\^]{1,3}$", [{"]-^", true}, {"a", false}]},
     {"^[-a]{1,2}$", [{"-", true}, {"a-", true}, {"b", false}]},
     {"^[a-]{1,2}$", [{"-", true}, {"-a", true}, {"b", false}]},
     {"^\\n\\r\\t\\f\\v$", [{"\n\r\t\f\v", true}, {"\n\r\t\f", false}]},
     {"^\\*\\+\\?$", [{"*+?", true}, {"*+", false}]},
     {".", [{[16#e9], unsupported_regex_subject}]}].

generated() ->
    Subjects = ["", "a", "b", "ab", "aa", "ba", "a\n", "\n", "\r", "\0", "\x7f", "ab\r"],
    {Patterns, _} = lists:mapfoldl(fun(_, Rng0) ->
        {Tree0, Rng1} = generate(3, Rng0),
        {Wrap, Rng2} = choice([true, false], Rng1),
        Tree = case Wrap of
            true -> {seq, [start, Tree0, 'end']};
            false -> Tree0
        end,
        {{spelling(Tree), [{S, oracle(Tree, S)} || S <- Subjects]}, Rng2}
    end, rng_new(?SEED), lists:seq(1, 100)),
    Patterns.

%% Random trees. Draws happen in the order the reference generator makes them.

-spec generate(non_neg_integer(), rng()) -> {tree(), rng()}.
generate(0, Rng0) ->
    {Literal, Rng1} = choice([0, 9, 10, 13, 97, 98, 127], Rng0),
    choice([{lit, Literal}, {set, [97, 98]}, dot, {seq, []}], Rng1);
generate(Depth, Rng0) ->
    case choice([seq, alt, rep, atom], Rng0) of
        {atom, Rng1} -> generate(0, Rng1);
        {rep, Rng1} ->
            {Low, Rng2} = range(0, 3, Rng1),
            {High, Rng3} = range(Low, 4, Rng2),
            {Child, Rng4} = generate(Depth - 1, Rng3),
            {{rep, Child, Low, High}, Rng4};
        {Kind, Rng1} ->
            {Count, Rng2} = range(1, 4, Rng1),
            {Children, Rng3} = lists:mapfoldl(fun(_, R) -> generate(Depth - 1, R) end,
                                              Rng2, lists:seq(1, Count)),
            {{Kind, Children}, Rng3}
    end.

-spec spelling(tree()) -> string().
spelling({lit, Byte}) -> lists:flatten(io_lib:format("\\x~2.16.0b", [Byte]));
spelling({set, Bytes}) -> "[" ++ lists:append([spelling({lit, B}) || B <- Bytes]) ++ "]";
spelling(dot) -> ".";
spelling(start) -> "^";
spelling('end') -> "$";
spelling({seq, Nodes}) -> "(" ++ lists:append([spelling(N) || N <- Nodes]) ++ ")";
spelling({alt, Nodes}) ->
    "(" ++ lists:append(lists:join("|", [spelling(N) || N <- Nodes])) ++ ")";
spelling({rep, Node, Low, High}) ->
    "(" ++ spelling(Node) ++ "){" ++ integer_to_list(Low) ++ "," ++ integer_to_list(High) ++ "}".

%% Matching oracle: the set of positions where each node can end.

-spec oracle(tree(), string()) -> boolean().
oracle(Tree, Subject) ->
    Bytes = list_to_tuple(Subject),
    Length = tuple_size(Bytes),
    lists:any(fun(Position) -> ends(Tree, Position, Bytes, Length) =/= [] end,
              lists:seq(0, Length)).

ends(start, 0, _, _) -> [0];
ends(start, _, _, _) -> [];
ends('end', Length, _, Length) -> [Length];
ends('end', _, _, _) -> [];
ends({lit, Byte}, Position, Bytes, Length) when Position < Length ->
    case element(Position + 1, Bytes) of Byte -> [Position + 1]; _ -> [] end;
ends({lit, _}, _, _, _) -> [];
ends({set, Set}, Position, Bytes, Length) when Position < Length ->
    case lists:member(element(Position + 1, Bytes), Set) of
        true -> [Position + 1];
        false -> []
    end;
ends({set, _}, _, _, _) -> [];
ends(dot, Position, Bytes, Length) when Position < Length ->
    case element(Position + 1, Bytes) of $\n -> []; _ -> [Position + 1] end;
ends(dot, _, _, _) -> [];
ends({alt, Nodes}, Position, Bytes, Length) ->
    lists:usort(lists:append([ends(N, Position, Bytes, Length) || N <- Nodes]));
ends({seq, Nodes}, Position, Bytes, Length) ->
    lists:foldl(fun(Node, Current) ->
        lists:usort(lists:append([ends(Node, P, Bytes, Length) || P <- Current]))
    end, [Position], Nodes);
ends({rep, Node, Low, High}, Position, Bytes, Length) ->
    Start = case Low of 0 -> [Position]; _ -> [] end,
    {_, Result} = lists:foldl(fun(Iteration, {Current, Acc}) ->
        Next = lists:usort(lists:append([ends(Node, P, Bytes, Length) || P <- Current])),
        {Next, case Iteration >= Low of true -> lists:umerge(Acc, Next); false -> Acc end}
    end, {[Position], Start}, lists:seq(1, High)),
    Result.

%% Python-compatible Mersenne Twister (MT19937 seeded with init_by_array).

-spec rng_new(non_neg_integer()) -> rng().
rng_new(Seed) ->
    Key = key(Seed),
    Initial = lists:foldl(fun(I, {Array, Previous}) ->
        Value = (1812433253 * (Previous bxor (Previous bsr 30)) + I) band 16#ffffffff,
        {array:set(I, Value, Array), Value}
    end, {array:set(0, 19650218, array:new(?N, {default, 0})), 19650218}, lists:seq(1, ?N - 1)),
    {Array0, _} = Initial,
    KeyLength = length(Key),
    {Array1, I1, _} = mix(max(?N, KeyLength), Array0, 1, 0, list_to_tuple(Key), KeyLength),
    {Array2, _} = spread(?N - 1, Array1, I1),
    {array:set(0, 16#80000000, Array2), ?N}.

key(Seed) when Seed < 16#100000000 -> [Seed];
key(Seed) -> [Seed band 16#ffffffff | key(Seed bsr 32)].

mix(0, Array, I, J, _, _) -> {Array, I, J};
mix(K, Array, I, J, Key, KeyLength) ->
    Previous = array:get(I - 1, Array),
    Value = ((array:get(I, Array) bxor ((Previous bxor (Previous bsr 30)) * 1664525))
             + element(J + 1, Key) + J) band 16#ffffffff,
    {Array1, I1} = wrap(array:set(I, Value, Array), I + 1),
    J1 = case J + 1 >= KeyLength of true -> 0; false -> J + 1 end,
    mix(K - 1, Array1, I1, J1, Key, KeyLength).

spread(0, Array, I) -> {Array, I};
spread(K, Array, I) ->
    Previous = array:get(I - 1, Array),
    Value = ((array:get(I, Array) bxor ((Previous bxor (Previous bsr 30)) * 1566083941))
             - I) band 16#ffffffff,
    {Array1, I1} = wrap(array:set(I, Value, Array), I + 1),
    spread(K - 1, Array1, I1).

wrap(Array, I) when I >= ?N -> {array:set(0, array:get(?N - 1, Array), Array), 1};
wrap(Array, I) -> {Array, I}.

-spec rng_bits(1..32, rng()) -> {non_neg_integer(), rng()}.
rng_bits(K, Rng) ->
    {Word, Next} = word(Rng),
    {Word bsr (32 - K), Next}.

-spec rng_below(pos_integer(), rng()) -> {non_neg_integer(), rng()}.
rng_below(N, Rng) -> below(N, bit_length(N), Rng).

below(N, K, Rng0) ->
    {R, Rng1} = rng_bits(K, Rng0),
    case R >= N of true -> below(N, K, Rng1); false -> {R, Rng1} end.

bit_length(N) -> bit_length(N, 0).
bit_length(0, Acc) -> Acc;
bit_length(N, Acc) -> bit_length(N bsr 1, Acc + 1).

choice(List, Rng0) ->
    {Index, Rng1} = rng_below(length(List), Rng0),
    {lists:nth(Index + 1, List), Rng1}.

range(Start, Stop, Rng0) ->
    {Offset, Rng1} = rng_below(Stop - Start, Rng0),
    {Start + Offset, Rng1}.

word({Array, Index}) when Index >= ?N -> word({twist(Array), 0});
word({Array, Index}) ->
    Y0 = array:get(Index, Array),
    Y1 = Y0 bxor (Y0 bsr 11),
    Y2 = Y1 bxor ((Y1 bsl 7) band 16#9d2c5680),
    Y3 = Y2 bxor ((Y2 bsl 15) band 16#efc60000),
    {Y3 bxor (Y3 bsr 18), {Array, Index + 1}}.

twist(Array0) ->
    Array1 = lists:foldl(fun(K, Array) ->
        Y = (array:get(K, Array) band 16#80000000)
            bor (array:get((K + 1) rem ?N, Array) band 16#7fffffff),
        Other = array:get((K + ?M) rem ?N, Array),
        array:set(K, Other bxor (Y bsr 1) bxor ((Y band 1) * 16#9908b0df), Array)
    end, Array0, lists:seq(0, ?N - 1)),
    Array1.

%% JSON, laid out as Python's json.dumps(indent=2, ensure_ascii=False).

-spec render(term()) -> binary().
render(Value) -> iolist_to_binary([encode(Value, 0), $\n]).

encode({obj, Pairs}, Depth) ->
    Inner = indent(Depth + 1),
    ["{\n", lists:join(",\n", [[Inner, string(atom_to_binary(K)), ": ", encode(V, Depth + 1)]
                               || {K, V} <- Pairs]), "\n", indent(Depth), "}"];
encode(List, Depth) when is_list(List) ->
    Inner = indent(Depth + 1),
    ["[\n", lists:join(",\n", [[Inner, encode(V, Depth + 1)] || V <- List]), "\n",
     indent(Depth), "]"];
encode(true, _) -> "true";
encode(false, _) -> "false";
encode(Atom, _) when is_atom(Atom) -> string(atom_to_binary(Atom));
encode(Integer, _) when is_integer(Integer) -> integer_to_list(Integer);
encode(Binary, _) when is_binary(Binary) -> string(Binary).

indent(Depth) -> lists:duplicate(Depth * 2, $\s).

text(Codepoints) -> unicode:characters_to_binary(Codepoints).

string(Binary) -> [$", escape(Binary), $"].

escape(<<>>) -> [];
escape(<<$", Rest/binary>>) -> [$\\, $" | escape(Rest)];
escape(<<$\\, Rest/binary>>) -> [$\\, $\\ | escape(Rest)];
escape(<<$\n, Rest/binary>>) -> [$\\, $n | escape(Rest)];
escape(<<$\r, Rest/binary>>) -> [$\\, $r | escape(Rest)];
escape(<<$\t, Rest/binary>>) -> [$\\, $t | escape(Rest)];
escape(<<$\b, Rest/binary>>) -> [$\\, $b | escape(Rest)];
escape(<<$\f, Rest/binary>>) -> [$\\, $f | escape(Rest)];
escape(<<Byte, Rest/binary>>) when Byte < 32 ->
    io_lib:format("\\u~4.16.0b", [Byte]) ++ escape(Rest);
escape(<<Byte, Rest/binary>>) -> [Byte | escape(Rest)].
