-module(tmux_workspace_wire).
-moduledoc false.
-include_lib("kernel/include/file.hrl").
-export([encode/1, digest/1, read/1, write/2, fields/3,
         require/3, text/2, fail/2, checked/1]).

-spec encode(term()) -> binary().
encode(Value) -> iolist_to_binary(canonical(Value)).

-spec digest(term()) -> binary().
digest(Value) ->
    binary:encode_hex(crypto:hash(sha256, encode(Value)), lowercase).

canonical(Map) when is_map(Map) ->
    Pairs = lists:sort([{key(K), V} || {K, V} <- maps:to_list(Map)]),
    Keys = [K || {K, _} <- Pairs],
    case length(Keys) =:= length(lists:usort(Keys)) of
        true -> ok;
        false -> fail(duplicate_key, [])
    end,
    [${, lists:join($,, [[json:encode(K), $:, canonical(V)]
        || {K, V} <- Pairs]), $}];
canonical(List) when is_list(List) ->
    [$[, lists:join($,, [canonical(V) || V <- List]), $]];
canonical(Value) when Value =:= true; Value =:= false; Value =:= null;
                      is_binary(Value); is_integer(Value) -> json:encode(Value);
canonical(Value) when is_atom(Value) -> json:encode(atom_to_binary(Value));
canonical(_) -> fail(invalid_value, []).

key(Value) when is_binary(Value) -> Value;
key(Value) when is_atom(Value) -> atom_to_binary(Value);
key(_) -> fail(invalid_key, []).

-spec read(file:filename_all()) -> map().
read(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< 262144 -> ok;
        {ok, #file_info{size = Size}} when Size > 262144 -> fail(document_limit, []);
        {ok, _} -> fail(not_regular_file, []);
        {error, Reason} -> file_error(Reason)
    end,
    File = checked(file:open(Path, [read, raw, binary])),
    tmux_scope:run_or_error(fun() ->
        case checked(file:read_file_info(File)) of
            #file_info{type = regular} -> ok;
            _ -> fail(not_regular_file, [])
        end,
        Data = case file:read(File, 262145) of
            {ok, Bytes} when byte_size(Bytes) =< 262144 -> Bytes;
            {ok, _} -> fail(document_limit, []);
            eof -> <<>>;
            {error, R} -> file_error(R)
        end,
        case tmux_json:decode(Data) of
            {ok, Map} when is_map(Map) -> Map;
            {ok, _} -> fail(expected_object, []);
            {error, Detail} -> throw({workspace_error, Detail})
        end
    end, fun() -> checked(file:close(File)) end).

-spec write(file:filename_all(), map()) -> ok.
write(Path0, Document) ->
    Path = unicode:characters_to_binary(Path0),
    Data = encode(Document),
    case byte_size(Data) < 262144 of
        true -> ok;
        false -> fail(document_limit, [])
    end,
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    Temp = <<Path/binary, ".", Suffix/binary, ".tmp">>,
    File = checked(file:open(Temp, [write, raw, binary, exclusive])),
    tmux_scope:run_or_error(fun() ->
        tmux_scope:run_or_error(fun() ->
            checked(file:change_mode(Temp, 8#600)),
            checked(file:write(File, [Data, $\n]))
        end, fun() -> checked(file:close(File)) end),
        checked(file:rename(Temp, Path))
    end, fun() ->
        case file:delete(Temp) of
            ok -> ok;
            {error, enoent} -> ok;
            {error, Reason} -> file_error(Reason)
        end
    end).

-spec fields(term(), [binary()], [term()]) -> map().
fields(Map, Allowed, Path) when is_map(Map) ->
    case lists:sort(maps:keys(maps:without(Allowed, Map))) of
        [] -> Map;
        [Name | _] -> fail(unknown_field, Path ++ [Name])
    end;
fields(_, _, Path) -> fail(expected_object, Path).

-spec require(binary(), map(), [term()]) -> term().
require(Name, Map, Path) when is_map(Map) ->
    case maps:find(Name, Map) of
        {ok, Value} -> Value;
        error -> fail(missing_field, Path ++ [Name])
    end;
require(_, _, Path) -> fail(expected_object, Path).

-spec text(term(), [term()]) -> binary().
text(Bin, Path) when is_binary(Bin), byte_size(Bin) > 0,
                     byte_size(Bin) =< 4096 ->
    case {unicode:characters_to_binary(Bin), binary:match(Bin, <<0>>)} of
        {Bin, nomatch} -> Bin;
        _ -> fail(invalid_text, Path)
    end;
text(_, Path) -> fail(invalid_text, Path).

-spec checked(ok | {ok, term()} | {error, term()}) -> term().
checked(ok) -> ok;
checked({ok, Value}) -> Value;
checked({error, Reason}) -> file_error(Reason).

-spec fail(atom(), [term()]) -> no_return().
fail(Code, Path) -> throw({workspace_error, #{code => Code, path => Path}}).

-spec file_error(term()) -> no_return().
file_error(Reason) ->
    throw({workspace_error, #{code => file_error, reason => Reason, path => []}}).
