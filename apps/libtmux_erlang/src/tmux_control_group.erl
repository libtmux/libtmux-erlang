-module(tmux_control_group).
-moduledoc false.
-export([prepare/1, start/1, reply/3]).

-define(MAX_COMMANDS, 16).
-define(MAX_BYTES, 65536).

-spec prepare(tmux_command:t() | [tmux_command:t()]) -> {ok, map()} | {error, map()}.
prepare(Commands) when is_list(Commands) -> prepare(Commands, [], []);
prepare(Command) -> prepare([Command], [], []).

prepare([], [], _) -> {error, #{code => empty_control_group}};
prepare([], Commands, Shapes) ->
    case tmux_command:to_config(lists:reverse(Commands)) of
        {ok, Text} -> {ok, #{text => Text, shapes => lists:reverse(Shapes)}};
        Error -> Error
    end;
prepare([_ | _], Commands, _) when length(Commands) =:= ?MAX_COMMANDS ->
    {error, #{code => control_group_limit}};
prepare([Command | Rest], Commands, Shapes) ->
    maybe
        {ok, Valid} ?= tmux_command:validate(Command),
        {ok, Shape} ?= shape(tmux_command:argv(Valid)),
        prepare(Rest, [Valid | Commands], [Shape | Shapes])
    end;
prepare(_, _, _) -> {error, #{code => unsupported_control_command}}.

shape([<<"list-sessions">>, <<"-F">>, <<"#{session_id}">>]) ->
    {ok, {$$, none}};
shape([<<"list-windows">>, <<"-t">>, Target, <<"-F">>, <<"#{window_id}">>]) ->
    session_target($@, Target);
shape([<<"list-panes">>, <<"-t">>, Target, <<"-F">>, <<"#{pane_id}">>]) ->
    session_target($%, Target);
shape(_) -> {error, #{code => unsupported_control_command}}.

session_target(Prefix, Target) ->
    case valid_id($$, Target) of
        true -> {ok, {Prefix, Target}};
        false -> {error, #{code => invalid_control_target}}
    end.

valid_id(Prefix, <<Prefix, Decimal/binary>>) when byte_size(Decimal) =< 10 ->
    try binary_to_integer(Decimal) of
        N -> N >= 0 andalso N =< 4294967295 andalso integer_to_binary(N) =:= Decimal
    catch error:badarg -> false
    end;
valid_id(_, _) -> false.

-spec start(map()) -> {binary(), map()}.
start(#{text := Text, shapes := Shapes}) ->
    Nonce = <<"ltm-read-", (binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))/binary>>,
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

accept(ok, Bytes, {Prefix, _}, Rest, #{replies := Replies} = Group) ->
    case ids(Bytes, Prefix) of
        true -> {continue, Group#{remaining => Rest, replies => [Bytes | Replies]}};
        false -> {error, unqualified_control_reply}
    end;
accept(error, Bytes, {_, Target}, _, #{replies := Replies} = Group) when is_binary(Target) ->
    Expected = <<"can't find session: ", Target/binary, 10>>,
    case Bytes of
        Expected -> {continue, Group#{remaining => [], failure => {length(Replies) + 1, Bytes}}};
        _ -> {error, unqualified_control_reply}
    end;
accept(error, _, _, _, _) -> {error, unqualified_control_reply}.

ids(<<>>, _) -> true;
ids(Text, Prefix) ->
    case binary:split(Text, <<10>>) of
        [Line, Rest] -> valid_id(Prefix, Line) andalso ids(Rest, Prefix);
        _ -> false
    end.
