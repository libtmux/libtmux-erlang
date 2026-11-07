-module(tmux_option_scope).
-moduledoc false.
-export([prepare/4, key/1, indexed/2]).

-spec prepare(term(), term(), atom(), option | hook) ->
    {ok, tmux_server:t(), [binary()], binary(), none | non_neg_integer(), map()}
    | {error, map()}.
prepare(Scope, Key, Action, Family) ->
    maybe
        {ok, Name, Index} ?= key(Key),
        {ok, Kind, Target} ?= scope(Scope),
        {ok, Variants} ?= known(Name),
        ok ?= precheck(Family, Kind, Index, Action, Variants),
        {ok, Server, ScopeArgs} ?= owner(Kind, Target),
        {ok, Meta} ?= case Name of
            <<$@, _/binary>> -> {ok, user_metadata()};
            _ ->
                maybe
                    {ok, Version} ?= tmux_server:version(Server),
                    {ok, Specific} ?= tmux_option:describe(Version, Name),
                    ok ?= allowed(Family, Kind, Index, Action, Specific),
                    {ok, Specific}
                end
        end,
        {ok, Server, ScopeArgs, Name, Index, Meta}
    end.

scope({Kind, Server}) when Kind =:= server; Kind =:= session_defaults; Kind =:= window_defaults ->
    {ok, Kind, Server};
scope(Row) ->
    maybe
        {ok, Valid} ?= tmux_model:validate(Row),
        case tmux_model:entity(Valid) of
            Kind when Kind =:= session; Kind =:= window; Kind =:= pane -> {ok, Kind, Valid};
            _ -> {error, #{code => wrong_target_kind}}
        end
    end.

owner(server, Server) -> {ok, Server, [<<"-s">>]};
owner(session_defaults, Server) -> {ok, Server, [<<"-g">>]};
owner(window_defaults, Server) -> {ok, Server, [<<"-g">>, <<"-w">>]};
owner(Kind, Row) ->
    maybe
        {ok, Server, Target} ?= tmux_target:resolve(Kind, Row),
        Flags = case Kind of session -> []; window -> [<<"-w">>]; pane -> [<<"-p">>] end,
        {ok, Server, Flags ++ [<<"-t">>, Target]}
    end.

known(<<$@, _/binary>>) -> {ok, [{[], user_metadata()}]};
known(Name) ->
    case tmux_option_data:variants(Name) of
        [] -> {error, #{code => unknown_tmux_option, name => Name}};
        Variants -> {ok, Variants}
    end.

user_metadata() -> #{scopes => [server, session, window, pane], type => string,
                     array => false, hook => false}.

precheck(Family, Kind, Index, Action, Variants) ->
    Checks = [allowed(Family, Kind, Index, Action, M) || {_, M} <- Variants],
    case lists:member(ok, Checks) of true -> ok; false -> hd(Checks) end.

allowed(option, _, _, _, #{hook := true}) -> {error, #{code => hook_requires_api}};
allowed(hook, _, _, _, #{hook := false}) -> {error, #{code => not_a_hook}};
allowed(_, Kind, Index, Action, #{scopes := Scopes, array := Array}) ->
    Actual = case Kind of session_defaults -> session; window_defaults -> window; _ -> Kind end,
    case {lists:member(Actual, Scopes), Array, Index, Action} of
        {false, _, _, _} -> {error, #{code => wrong_option_scope, actual => Actual, allowed => Scopes}};
        {true, false, N, _} when N =/= none -> {error, #{code => not_an_array}};
        {true, true, none, write} -> {error, #{code => array_index_required}};
        _ -> ok
    end.

-spec key(term()) -> {ok, binary(), none | non_neg_integer()} | {error, map()}.
key({Name, Index}) when is_binary(Name), is_integer(Index, 0, 2147483647) ->
    maybe {ok, Name, none} ?= key(Name), {ok, Name, Index} end;
key(Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 1024 ->
    case binary:match(Name, [<<0>>, <<"[">>, <<"]">>]) of
        nomatch ->
            case Name of
                <<$@>> -> {error, #{code => invalid_option_key}};
                _ -> {ok, Name, none}
            end;
        _ -> {error, #{code => invalid_option_key}}
    end;
key(_) -> {error, #{code => invalid_option_key}}.


-spec indexed(binary(), none | non_neg_integer()) -> binary().
indexed(Name, none) -> Name;
indexed(Name, Index) -> <<Name/binary, $[, (integer_to_binary(Index))/binary, $]>>.
