-module(tmux_control_group).
-moduledoc false.
-export([prepare/1, start/1, reply/3, progress/1]).

-define(MAX_COMMANDS, 16).
-define(MAX_BYTES, 65536).

-spec prepare(tmux_command:t() | [tmux_command:t()]) -> {ok, map()} | {error, map()}.
prepare({tmux_sequence, Commands}) -> prepare(Commands, [], []);
prepare(Commands) when is_list(Commands) -> prepare(Commands, [], []);
prepare(Command) -> prepare([Command], [], []).

prepare([], [], _) -> {error, #{code => empty_control_group}};
prepare([], Commands, Shapes) ->
    maybe
        {ok, Sequence} ?= tmux_command:sequence(lists:reverse(Commands)),
        {ok, Text} ?= tmux_command:to_config(Sequence),
        Origin = case tmux_command:provenance(Sequence) of
            #{origin := Bound} -> Bound;
            none -> none
        end,
        {ok, #{origin => Origin, text => Text, shapes => lists:reverse(Shapes)}}
    end;
prepare([_ | _], Commands, _) when length(Commands) =:= ?MAX_COMMANDS ->
    {error, #{code => control_group_limit}};
prepare([Command | Rest], Commands, Shapes) ->
    maybe
        {ok, Valid} ?= tmux_command:validate(Command),
        {ok, Shape} ?= shape(Valid),
        prepare(Rest, [Valid | Commands], [Shape | Shapes])
    end;
prepare(_, _, _) -> {error, #{code => unsupported_control_command}}.

shape(Command) ->
    Args = tmux_command:argv(Command),
    case tmux_command:provenance(Command) of
        none -> read_shape(Args);
        #{kind := Kind} -> mutation_shape(Kind, Args)
    end.

read_shape([<<"list-sessions">>, <<"-F">>, <<"#{session_id}">>]) ->
    {ok, {{ids, $$}, none}};
read_shape([<<"list-windows">>, <<"-t">>, Target, <<"-F">>, <<"#{window_id}">>]) ->
    target_shape({ids, $@}, $$, Target, <<"session">>);
read_shape([<<"list-panes">>, <<"-t">>, Target, <<"-F">>, <<"#{pane_id}">>]) ->
    target_shape({ids, $%}, $$, Target, <<"session">>);
read_shape(_) -> unsupported().

mutation_shape(session_rename, [<<"rename-session">>, <<"-t">>, Target, <<"--">>, _]) ->
    case binary:split(Target, <<":">>) of
        [Id, <<>>] -> target_shape(empty, $$, Id, <<"session">>);
        _ -> {error, #{code => invalid_control_target}}
    end;
mutation_shape(window_resize, [<<"resize-window">> | Args]) ->
    resize_shape(Args, $@, <<"window">>, 10000);
mutation_shape(pane_resize, [<<"resize-pane">> | Args]) ->
    resize_shape(Args, $%, <<"pane">>, 65535);
mutation_shape(_, _) -> unsupported().

resize_shape(Args, Prefix, Entity, Maximum) ->
    case dimensions(Args) of
        {Values, [<<"-t">>, Target]} ->
            case lists:all(fun(Value) -> decimal(Value, 1, Maximum) end, Values) of
                true -> target_shape(empty, Prefix, Target, Entity);
                false -> unsupported()
            end;
        _ -> unsupported()
    end.

dimensions([<<"-x">>, Width, <<"-y">>, Height | Rest]) -> {[Width, Height], Rest};
dimensions([Flag, Size | Rest]) when Flag =:= <<"-x">>; Flag =:= <<"-y">> ->
    {[Size], Rest};
dimensions(_) -> none.

target_shape(Reply, Prefix, Id, Entity) ->
    case valid_id(Prefix, Id) of
        true -> {ok, {Reply, <<"can't find ", Entity/binary, ": ", Id/binary, 10>>}};
        false -> {error, #{code => invalid_control_target}}
    end.

unsupported() -> {error, #{code => unsupported_control_command}}.

valid_id(Prefix, <<Prefix, Decimal/binary>>) -> decimal(Decimal, 0, 4294967295);
valid_id(_, _) -> false.

decimal(Text, Minimum, Maximum) when byte_size(Text) =< 10 ->
    try binary_to_integer(Text) of
        N -> is_integer(N, Minimum, Maximum) andalso integer_to_binary(N) =:= Text
    catch error:badarg -> false
    end;
decimal(_, _, _) -> false.

-spec start(map()) -> {binary(), map()}.
start(#{text := Text, shapes := Shapes}) ->
    Nonce = <<"ltm-group-", (binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))/binary>>,
    Bytes = <<Text/binary, "\ndisplay-message -p -- ", Nonce/binary, "\n">>,
    {Bytes, #{remaining => Shapes, marker => <<Nonce/binary, 10>>,
              replies => [], failure => none, bytes => 0}}.

-spec reply(ok | error, binary(), map()) ->
    {continue, map()} | {done, {ok, map()} | {error, map()}} | {error, atom()}.
reply(ok, Marker, #{marker := Marker, remaining := [], replies := Replies, failure := Failure}) ->
    Ordered = lists:reverse(Replies),
    case Failure of
        none -> {done, {ok, #{replies => Ordered}}};
        {Index, Message} ->
            {done, {error, #{code => command_error, index => Index,
                             replies => Ordered, message => Message}}}
    end;
reply(_, _, #{remaining := []}) -> {error, unexpected_control_reply};
reply(Outcome, Bytes, #{bytes := Used, remaining := [Shape | Rest]} = Group) ->
    case Used + byte_size(Bytes) =< ?MAX_BYTES of
        true -> accept(Outcome, Bytes, Shape, Rest, Group#{bytes => Used + byte_size(Bytes)});
        false -> {error, control_reply_limit}
    end.

accept(ok, Bytes, {Reply, _}, Rest, #{replies := Replies} = Group) ->
    case valid_reply(Reply, Bytes) of
        true -> {continue, Group#{remaining => Rest, replies => [Bytes | Replies]}};
        false -> {error, unqualified_control_reply}
    end;
accept(error, Bytes, {_, Bytes}, _, #{replies := Replies} = Group) ->
    {continue, Group#{remaining => [], failure => {length(Replies) + 1, Bytes}}};
accept(error, _, _, _, _) -> {error, unqualified_control_reply}.

valid_reply(empty, Bytes) -> Bytes =:= <<>>;
valid_reply({ids, Prefix}, Bytes) -> ids(Bytes, Prefix).

-spec progress(map() | none) -> [binary()].
progress(none) -> [];
progress(#{replies := Replies}) -> lists:reverse(Replies).

ids(<<>>, _) -> true;
ids(Text, Prefix) ->
    case binary:split(Text, <<10>>) of
        [Line, Rest] -> valid_id(Prefix, Line) andalso ids(Rest, Prefix);
        _ -> false
    end.
