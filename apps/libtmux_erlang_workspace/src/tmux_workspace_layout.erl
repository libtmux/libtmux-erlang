-module(tmux_workspace_layout).
-moduledoc false.
-export([cells/1, split/1]).
-export_type([cell/0]).
-type cell() :: {pos_integer(), pos_integer()} | floating.

%% window_layout retains the unzoomed tree. JSON v2 marks floating leaves
%% with z, including zero; legacy layouts contain only tiled leaves.
-spec cells(binary()) -> #{binary() => cell()}.
cells(Binary) when is_binary(Binary), byte_size(Binary) =< 262144 ->
    case Binary of
        <<${, _/binary>> ->
            case tmux_json:decode(Binary) of
                {ok, #{<<"V">> := 2, <<"L">> := Root}} ->
                    {Cells, _} = json_cell(Root, 0, {#{}, 0}), Cells;
                _ -> invalid()
            end;
        <<Checksum:4/binary, $,, Tree/binary>> ->
            Expected = iolist_to_binary(io_lib:format("~4.16.0b", [checksum(Tree)])),
            case Checksum =:= Expected of true -> ok; false -> invalid() end,
            {<<>>, {Cells, _}} = legacy_end(Tree), Cells;
        _ -> invalid()
    end;
cells(_) -> invalid().

legacy_end(Tree) ->
    case legacy_cell(Tree, 0, {#{}, 0}) of
        {<<>>, _} = Result -> Result;
        _ -> invalid()
    end.

json_cell(#{<<"t">> := Type, <<"w">> := W, <<"h">> := H} = M, Depth, Acc) ->
    Next = bound(W, H, Depth, Acc),
    case Type of
        <<"p">> ->
            Id = maps:get(<<"I">>, M, none),
            tmux_workspace_state:id(<<"pane">>, Id),
            Cell = case maps:is_key(<<"z">>, M) of
                true -> floating;
                false -> {W, H}
            end,
            put_cell(Id, Cell, Next);
        T when T =:= <<"h">>; T =:= <<"v">> ->
            case maps:get(<<"c">>, M, none) of
                [_ | _] = Children ->
                    lists:foldl(fun(C, A) -> json_cell(C, Depth + 1, A) end,
                        Next, Children);
                _ -> invalid()
            end;
        _ -> invalid()
    end;
json_cell(_, _, _) -> invalid().

legacy_cell(Binary, Depth, Acc) ->
    {W, R0} = number(Binary),
    R1 = separator($x, R0), {H, R2} = number(R1),
    R3 = separator($,, R2), {_, R4} = number(R3),
    R5 = separator($,, R4), {_, Rest} = number(R5),
    Next = bound(W, H, Depth, Acc),
    case Rest of
        <<$,, R6/binary>> ->
            {N, R7} = number(R6),
            {R7, put_cell(<<$%, (integer_to_binary(N))/binary>>, {W, H}, Next)};
        <<${, R6/binary>> -> legacy_children(R6, $}, Depth + 1, Next);
        <<$[, R6/binary>> -> legacy_children(R6, $], Depth + 1, Next);
        _ -> invalid()
    end.

legacy_children(Binary, End, Depth, Acc) ->
    case legacy_cell(Binary, Depth, Acc) of
        {<<End, Rest/binary>>, Next} -> {Rest, Next};
        {<<$,, Rest/binary>>, Next} -> legacy_children(Rest, End, Depth, Next);
        _ -> invalid()
    end.

separator(Char, <<Char, Rest/binary>>) -> Rest;
separator(_, _) -> invalid().
number(Binary) -> number(Binary, 0, 0).
number(<<C, Rest/binary>>, N, Digits) when C >= $0, C =< $9, Digits < 20 ->
    number(Rest, N * 10 + C - $0, Digits + 1);
number(Rest, N, Digits) when Digits > 0, N =< 18446744073709551615 -> {N, Rest};
number(_, _, _) -> invalid().

bound(W, H, Depth, {Cells, Count})
        when is_integer(W, 1, 4294967295), is_integer(H, 1, 4294967295),
             Depth < 128, Count < 4096 -> {Cells, Count + 1};
bound(_, _, _, _) -> invalid().

put_cell(Id, Cell, {Cells, Count}) ->
    case maps:is_key(Id, Cells) of
        false -> {Cells#{Id => Cell}, Count};
        true -> invalid()
    end.

checksum(Binary) ->
    lists:foldl(fun(C, Sum) ->
        (((Sum bsr 1) bor ((Sum band 1) bsl 15)) + C) band 65535
    end, 0, binary_to_list(Binary)).

%% Four cell rows cover both pane-border-status minima. Horizontal scrollbar
%% reservations still belong to tmux: a geometric schedule can be rejected.
-spec split(cell()) -> {horizontal | vertical, cell(), cell()} | none.
split({W, H}) when W >= 3, (W >= H orelse H < 4) ->
    {horizontal, {W div 2, H}, {(W - 1) div 2, H}};
split({W, H}) when H >= 4 ->
    {vertical, {W, H div 2}, {W, (H - 1) div 2}};
split(_) -> none.

-spec invalid() -> no_return().
invalid() -> tmux_workspace_wire:fail(unsupported_layout, [<<"layout">>]).
