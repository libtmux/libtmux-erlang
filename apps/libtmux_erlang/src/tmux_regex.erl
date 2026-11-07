-module(tmux_regex).
-moduledoc false.
-export([validate/1, render/2, compile/1, run/2]).
-export_type([t/0, ast/0]).
-type ast() :: start | finish | {char, byte()} | {class, [byte()]} |
    {seq | alt, [ast()]} | {repeat, ast(), non_neg_integer(), non_neg_integer()}.
-opaque t() :: {portable_v1, re:mp()}.

-spec validate(binary()) -> {ok, ast()} | {error, map()}.
validate(Pattern) when is_binary(Pattern), byte_size(Pattern) =< 1024 ->
    try
        ascii(Pattern, 0),
        {Tree, Rest, Offset} = alternative(Pattern, 0, 0),
        case Rest of <<>> -> ok; _ -> reject(invalid_regex, Offset) end,
        case cost(Tree) =< 8192 of
            true -> ok;
            false -> reject(regex_complexity_limit, 0)
        end,
        case iolist_size(emit(Tree, pcre2)) =< 65536 of
            true -> {ok, Tree};
            false -> reject(regex_complexity_limit, 0)
        end
    catch throw:{invalid_regex, Detail} -> {error, Detail}
    end;
validate(Pattern) when is_binary(Pattern) -> {error, #{code => pattern_limit, offset => 1024}};
validate(_) -> {error, #{code => invalid_regex, offset => 0}}.

-spec render(binary(), pcre2 | javascript | rust) -> {ok, binary()} | {error, map()}.
render(Pattern, Engine) when Engine =:= pcre2; Engine =:= javascript; Engine =:= rust ->
    maybe
        {ok, Tree} ?= validate(Pattern),
        {ok, iolist_to_binary(emit(Tree, Engine))}
    end.

-spec compile(binary()) -> {ok, t()} | {error, map()}.
compile(Pattern) ->
    maybe
        {ok, Rendered} ?= render(Pattern, pcre2),
        case re:compile(Rendered, [no_auto_capture, never_utf]) of
            {ok, Compiled} -> {ok, {portable_v1, Compiled}};
            {error, {Reason, Offset}} ->
                {error, #{code => regex_compile_failed, reason => Reason, offset => Offset}}
        end
    end.

-spec run(t(), binary()) -> {ok, boolean()} | {error, map()}.
run(_, Subject) when is_binary(Subject), byte_size(Subject) > 1048576 ->
    {error, #{code => regex_subject_limit, limit => 1048576}};
run({portable_v1, Compiled}, Subject) when is_binary(Subject) ->
    case ascii_subject(Subject) of
        false -> {error, #{code => unsupported_regex_subject, expected => ascii}};
        true ->
            case re:run(Subject, Compiled, [{capture, none}, report_errors,
                                          {match_limit, 100000}, {match_limit_recursion, 1000}]) of
                match -> {ok, true};
                nomatch -> {ok, false};
                {error, Reason} -> {error, #{code => regex_resource_limit, reason => Reason}}
            end
    end.

alternative(Bytes, Offset, Depth) ->
    {First, Rest, Next} = sequence(Bytes, Offset, Depth, []),
    alternatives(Rest, Next, Depth, [First]).
alternatives(<<$|, Rest/binary>>, Offset, Depth, Acc) ->
    {Next, Tail, End} = sequence(Rest, Offset + 1, Depth, []),
    alternatives(Tail, End, Depth, [Next | Acc]);
alternatives(Rest, Offset, _, [Node]) -> {Node, Rest, Offset};
alternatives(Rest, Offset, _, Acc) -> {{alt, lists:reverse(Acc)}, Rest, Offset}.

sequence(<<>>, Offset, _, Acc) -> {join(lists:reverse(Acc)), <<>>, Offset};
sequence(<<C, _/binary>> = Rest, Offset, _, Acc) when C =:= $|; C =:= $) ->
    {join(lists:reverse(Acc)), Rest, Offset};
sequence(Bytes, Offset, Depth, Acc) ->
    {Node, Rest, Next} = atom(Bytes, Offset, Depth),
    {Repeated, Tail, End} = repetition(Node, Rest, Next),
    sequence(Tail, End, Depth, [Repeated | Acc]).

atom(<<$(, _/binary>>, Offset, Depth) when Depth >= 32 -> reject(regex_depth_limit, Offset);
atom(<<$(, Marker, _/binary>>, Offset, _) when Marker =:= $?; Marker =:= $* ->
    reject(unsupported_regex_syntax, Offset);
atom(<<$(, Rest/binary>>, Offset, Depth) ->
    {Node, Tail, End} = alternative(Rest, Offset + 1, Depth + 1),
    case Tail of
        <<$), More/binary>> -> {Node, More, End + 1};
        _ -> reject(invalid_regex, End)
    end;
atom(<<$[, Rest/binary>>, Offset, _) ->
    {Negative, Start, Next} = case Rest of
        <<$^, AfterCaret/binary>> -> {true, AfterCaret, Offset + 2};
        _ -> {false, Rest, Offset + 1}
    end,
    {Tokens, Tail, End} = class_tokens(Start, Next, []),
    Values = lists:usort(class_values(Tokens)),
    Set = case Negative of true -> lists:seq(0,127) -- Values; false -> Values end,
    {{class, Set}, Tail, End};
atom(<<$\\, Rest/binary>>, Offset, _) ->
    {Byte, Tail, End} = escaped(Rest, Offset + 1),
    {{char, Byte}, Tail, End};
atom(<<$^, Rest/binary>>, Offset, _) -> {start, Rest, Offset + 1};
atom(<<$$, Rest/binary>>, Offset, _) -> {finish, Rest, Offset + 1};
atom(<<$., Rest/binary>>, Offset, _) -> {{class, lists:seq(0,9) ++ lists:seq(11,127)}, Rest, Offset + 1};
atom(<<C, _/binary>>, Offset, _) when C =:= $*; C =:= $+; C =:= $?;
                                             C =:= ${; C =:= $}; C =:= $] ->
    reject(unsupported_regex_syntax, Offset);
atom(<<C, Rest/binary>>, Offset, _) -> {{char, C}, Rest, Offset + 1}.

repetition(Node, <<${, _/binary>>, Offset) when Node =:= start; Node =:= finish ->
    reject(unsupported_regex_syntax, Offset);
repetition(Node, <<${, Rest/binary>>, Offset) ->
    {Minimum, Tail, Next} = number(Rest, Offset + 1, []),
    {Maximum, More, End} = case Tail of
        <<$}, Remaining/binary>> -> {Minimum, Remaining, Next + 1};
        <<$,, Remaining/binary>> ->
            {Max, Close, Position} = number(Remaining, Next + 1, []),
            case Close of <<$}, R/binary>> -> {Max, R, Position + 1}; _ -> reject(invalid_regex, Position) end;
        _ -> reject(invalid_regex, Next)
    end,
    case Minimum =< Maximum of
        true -> {{repeat, Node, Minimum, Maximum}, More, End};
        false -> reject(invalid_repetition_range, Offset)
    end;
repetition(Node, Rest, Offset) -> {Node, Rest, Offset}.

number(<<C, Rest/binary>>, Offset, Acc) when C >= $0, C =< $9, length(Acc) < 2 ->
    number(Rest, Offset + 1, [C | Acc]);
number(_, Offset, []) -> reject(invalid_repetition_range, Offset);
number(Rest, Offset, Acc) ->
    Value = list_to_integer(lists:reverse(Acc)),
    case Value =< 64 andalso not digit_head(Rest) of
        true -> {Value, Rest, Offset};
        false -> reject(repetition_limit, Offset)
    end.
digit_head(<<C, _/binary>>) -> C >= $0 andalso C =< $9;
digit_head(_) -> false.

class_tokens(<<$], Rest/binary>>, Offset, [_ | _] = Acc) -> {lists:reverse(Acc), Rest, Offset + 1};
class_tokens(<<$\\, Rest/binary>>, Offset, Acc) ->
    {Byte, Tail, End} = escaped(Rest, Offset + 1),
    class_tokens(Tail, End, [{Byte, true, Offset} | Acc]);
class_tokens(<<C, _/binary>>, Offset, _) when C =:= $[; C =:= $] ->
    reject(unsupported_regex_syntax, Offset);
class_tokens(<<C, Rest/binary>>, Offset, Acc) ->
    class_tokens(Rest, Offset + 1, [{C, false, Offset} | Acc]);
class_tokens(<<>>, Offset, _) -> reject(invalid_regex, Offset).
class_values([{A, _, _}, {$-, false, Position}, {B, _, _} | Rest]) ->
    case A =< B of
        true -> lists:seq(A, B) ++ class_values(Rest);
        false -> reject(invalid_class_range, Position)
    end;
class_values([{Byte, _, _} | Rest]) -> [Byte | class_values(Rest)];
class_values([]) -> [].

escaped(<<$x, A, B, Rest/binary>>, Offset) ->
    case {hex(A), hex(B)} of
        {N, M} when is_integer(N), is_integer(M), N * 16 + M < 128 -> {N * 16 + M, Rest, Offset + 3};
        _ -> reject(unsupported_regex_syntax, Offset)
    end;
escaped(<<C, Rest/binary>>, Offset) ->
    case lists:keyfind(C, 1, [{$n,10},{$r,13},{$t,9},{$f,12},{$v,11}]) of
        {_, Byte} -> {Byte, Rest, Offset + 1};
        false ->
            case lists:member(C, "\\.^$|*+?()[]{}-") of
                true -> {C, Rest, Offset + 1};
                false -> reject(unsupported_regex_syntax, Offset)
            end
    end;
escaped(<<>>, Offset) -> reject(invalid_regex, Offset).
hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(_) -> invalid.

join([Node]) -> Node;
join(Nodes) -> {seq, Nodes}.
cost({repeat, Node, _, Max}) -> 1 + Max * cost(Node);
cost({Kind, Nodes}) when Kind =:= seq; Kind =:= alt -> 1 + lists:sum([cost(N) || N <- Nodes]);
cost(_) -> 1.

emit(start, javascript) -> <<"^">>;
emit(start, _) -> <<"\\A">>;
emit(finish, javascript) -> <<"$(?![\\s\\S])">>;
emit(finish, _) -> <<"\\z">>;
emit({char, Byte}, _) -> hex_byte(Byte);
emit({class, []}, _) -> <<"[^\\x00-\\x7F]">>;
emit({class, Bytes}, _) -> [$[, [hex_byte(B) || B <- Bytes], $]];
emit({seq, Nodes}, Engine) -> [emit(N, Engine) || N <- Nodes];
emit({alt, Nodes}, Engine) -> [<<"(?:">>, lists:join($|, [emit(N, Engine) || N <- Nodes]), $)];
emit({repeat, Node, Min, Max}, Engine) ->
    [<<"(?:">>, emit(Node, Engine), <<"){">>, integer_to_binary(Min), $,, integer_to_binary(Max), $}].
hex_byte(Byte) -> io_lib:format("\\x~2.16.0B", [Byte]).

ascii(<<>>, _) -> ok;
ascii(<<C, Rest/binary>>, Offset) when C < 128 -> ascii(Rest, Offset + 1);
ascii(_, Offset) -> reject(non_ascii_pattern, Offset).
ascii_subject(<<>>) -> true;
ascii_subject(<<C, Rest/binary>>) when C < 128 -> ascii_subject(Rest);
ascii_subject(_) -> false.
-spec reject(atom(), non_neg_integer()) -> no_return().
reject(Code, Offset) -> throw({invalid_regex, #{code => Code, offset => Offset}}).
