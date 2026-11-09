-module(tmux_option_batch).
-moduledoc false.
-export([prepare/3, decode/4]).

-spec prepare(term(), term(), [binary()]) ->
    {ok, tmux_server:t(), tmux_command:t(), [map()]} | {error, map()}.
prepare(Scopes, Name, Flags) ->
    maybe
        ok ?= scopes(Scopes, 7),
        ok ?= name(Name),
        ok ?= scalar(Name),
        {ok, Server, Rows, Commands} ?= rows(Scopes, Name, Flags, none, 1, [], []),
        {ok, Sequence} ?= tmux_command:sequence(Commands),
        {ok, Server, Sequence, Rows}
    end.

scopes([], 7) -> unsupported(empty_batch);
scopes([], _) -> ok;
scopes([_ | _], 0) -> unsupported(batch_limit);
scopes([_ | Rest], Left) -> scopes(Rest, Left - 1);
scopes(_, _) -> unsupported(invalid_scopes).

name(Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 1024 ->
    Tail = case Name of <<$@, Rest/binary>> -> Rest; _ -> Name end,
    case byte_size(Tail) > 0 andalso lists:all(fun(C) ->
        (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $- orelse C =:= $.
    end, binary_to_list(Tail)) of
        true -> ok;
        false -> unsupported(noncanonical_key)
    end;
name(_) -> unsupported(noncanonical_key).

scalar(<<$@, _/binary>>) -> ok;
scalar(Name) ->
    case tmux_option_data:variants(Name) of
        [] -> {error, #{code => unknown_tmux_option, name => Name}};
        Variants ->
            case lists:all(fun({_, M}) -> scalar_metadata(M) end, Variants) of
                true -> ok;
                false -> unsupported(nonscalar_option)
            end
    end.

scalar_metadata(#{array := false, hook := false, type := Type}) -> Type =/= command;
scalar_metadata(_) -> false.

rows([], _, _, Server, _, Rows, Commands) ->
    {ok, Server, lists:reverse(Rows), lists:append(lists:reverse(Commands))};
rows([{_, _} | _], _, _, _, _, _, _) -> unsupported(nonlocal_scope);
rows([Row | Rest], Name, Flags, Owner, Index, Rows, Commands) ->
    maybe
        {ok, Valid} ?= tmux_model:validate(Row),
        Kind = tmux_model:entity(Valid),
        ok ?= case lists:member(Kind, [session, window, pane]) of
            true -> ok;
            false -> unsupported(nonlocal_scope)
        end,
        {ok, Server, ScopeArgs, Name, none, Meta} ?=
            tmux_option_scope:prepare(Valid, Name, read, option),
        ok ?= case Owner =:= none orelse Owner =:= Server of
            true -> ok;
            false -> {error, #{code => different_owner}}
        end,
        Id = tmux_model:get(id, Valid),
        {ok, Target} ?= tmux_target:selector(Kind, Id),
        Begin = guard_format(begin_read, Kind, Index),
        End = guard_format(end_read, Kind, Index),
        {ok, First} ?= tmux_command:raw(<<"display-message">>,
            [<<"-p">>, <<"-t">>, Target, Begin]),
        {ok, Read} ?= tmux_command:raw(<<"show-options">>,
            [<<"-q">> | ScopeArgs] ++ Flags ++ [<<"--">>, Name]),
        {ok, Last} ?= tmux_command:raw(<<"display-message">>,
            [<<"-p">>, <<"-t">>, Target, End]),
        rows(Rest, Name, Flags, Server, Index + 1,
            [#{id => Id, entity => Kind, metadata => Meta} | Rows],
            [[First, Read, Last] | Commands])
    end.

guard_format(Stage, Kind, Index) ->
    Prefix = prefix(Stage, Index),
    Field = atom_to_binary(Kind),
    <<Prefix/binary, "#{", Field/binary, "_id}">>.

prefix(begin_read, Index) -> <<"__ltm_option_begin_", (integer_to_binary(Index))/binary, $:>>;
prefix(end_read, Index) -> <<"__ltm_option_end_", (integer_to_binary(Index))/binary, $:>>.

-spec decode(binary(), binary(), [map()], tmux_version:t()) ->
    {ok, [binary() | none]} | {error, map()}.
decode(Name, Output, Rows, Version) ->
    %% Split the wire before decoding quoted values: an escaped newline is
    %% value data, never a framing delimiter. Guard normalization is separate
    %% from the option codec's single application of the legacy print layer.
    maybe
        {ok, Lines} ?= wire_lines(Output, 3 * length(Rows), []),
        decode_rows(Rows, Lines, Name, Version, 1, [])
    end.

wire_lines(<<>>, _, Acc) -> {ok, lists:reverse([<<>> | Acc])};
wire_lines(_, 0, _) -> invalid(1);
wire_lines(Bytes, Left, Acc) ->
    case binary:split(Bytes, <<"\n">>) of
        [Line, Rest] -> wire_lines(Rest, Left - 1, [Line | Acc]);
        _ -> invalid(1)
    end.

decode_rows([], [<<>>], _, _, _, Values) -> {ok, lists:reverse(Values)};
decode_rows([Row | Rest], [Begin | Lines], Name, Version, Index, Values) ->
    maybe
        ok ?= guard(Begin, begin_read, Row, Version, Index),
        {ok, Value, Tail} ?= value(Lines, Name, Row, Version, Index),
        decode_rows(Rest, Tail, Name, Version, Index + 1, [Value | Values])
    end;
decode_rows(_, _, _, _, Index, _) -> invalid(Index).

value([Line | Rest], Name, Row, Version, Index) ->
    case guard(Line, end_read, Row, Version, Index) of
        ok -> {ok, none, Rest};
        {error, #{code := target_gone}} = Error -> Error;
        _ ->
            case Rest of
                [End | Tail] ->
                    maybe
                        ok ?= guard(End, end_read, Row, Version, Index),
                        {ok, Bytes} ?= tmux_option_codec:decode(Name,
                            <<Line/binary, $\n>>, maps:get(metadata, Row), Version),
                        {ok, Bytes, Tail}
                    else
                        {error, #{code := target_gone}} = Error -> Error;
                        _ -> invalid(Index)
                    end;
                _ -> invalid(Index)
            end
    end;
value(_, _, _, _, Index) -> invalid(Index).

guard(Line, Stage, #{id := Id}, Version, Index) ->
    {_, Normalized} = tmux_text_codec:print_layer(Line, Version),
    Prefix = prefix(Stage, Index),
    Size = byte_size(Prefix),
    case Normalized of
        <<Prefix:Size/binary, Id/binary>> -> ok;
        <<Prefix:Size/binary, _/binary>> ->
            {error, #{code => target_gone, entity => option_batch, index => Index}};
        _ -> invalid(Index)
    end.

unsupported(Reason) ->
    {error, #{code => unsupported_capability, capability => option_batch, reason => Reason}}.
invalid(Index) -> {error, #{code => invalid_observation, entity => option_batch, index => Index}}.
