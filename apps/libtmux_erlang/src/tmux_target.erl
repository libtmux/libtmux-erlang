-module(tmux_target).
-moduledoc false.
-export([owner/2, same_owner/4, resolve/2, selector/2, run/3, run/4, act/4]).

-spec resolve(atom() | [atom()], term()) ->
    {ok, tmux_server:t(), binary()} | {error, map()}.
resolve(Expected, Row) when is_atom(Expected) -> resolve([Expected], Row);
resolve(Expected, Row) ->
    maybe
        {ok, Server} ?= owner(Expected, Row),
        {ok, Target} ?= selector(tmux_model:entity(Row), tmux_model:get(id, Row)),
        {ok, Server, Target}
    end.

-spec owner(atom() | [atom()], term()) -> {ok, tmux_server:t()} | {error, map()}.
owner(Expected, Row) when is_atom(Expected) -> owner([Expected], Row);
owner(Expected, Row) ->
    maybe
        {ok, Validated} ?= tmux_model:validate(Row),
        Entity = tmux_model:entity(Validated),
        ok ?= case lists:member(Entity, Expected) of
            true -> ok;
            false -> {error, #{code => wrong_target_kind, expected => Expected, actual => Entity}}
        end,
        {ok, Origin} ?= case tmux_model:origin(Validated) of
            none -> {error, #{code => detached_reference}};
            Ref -> {ok, Ref}
        end,
        tmux_server:from_origin(Origin)
    end.

-spec same_owner(atom(), tmux_model:row(), atom(), tmux_model:row()) ->
    {ok, tmux_server:t()} | {error, map()}.
same_owner(SourceKind, Source, DestinationKind, Destination) ->
    maybe
        {ok, Server} ?= owner(SourceKind, Source),
        {ok, Other} ?= owner(DestinationKind, Destination),
        case Server =:= Other of
            true -> {ok, Server};
            false -> {error, #{code => different_owner}}
        end
    end.

-spec selector(atom(), binary()) -> {ok, binary()} | {error, map()}.
selector(Entity, Id) when Entity =:= session; Entity =:= window; Entity =:= pane ->
    maybe
        {ok, _} ?= tmux_model:new(Entity, #{id => Id}),
        {ok, case Entity of session -> <<Id/binary, $:>>; _ -> Id end}
    end;
selector(_, _) -> {error, #{code => unsupported_target_kind}}.

-spec run(tmux_server:t(), binary(), [binary()]) -> {ok, map()} | {error, map()}.
run(Server, Name, Args) ->
    run(Server, Name, Args, #{}).

-spec run(tmux_server:t(), binary(), [binary()], map()) -> {ok, map()} | {error, map()}.
run(Server, Name, Args, Options) ->
    maybe
        {ok, Command} ?= tmux_command:raw(Name, Args),
        classify(tmux_server:command(Server, Command, Options))
    end.

-spec act(atom(), tmux_model:row(), binary(), [binary()]) -> {ok, map()} | {error, map()}.
act(Entity, Row, Name, Args) ->
    maybe
        {ok, Server, Target} ?= resolve(Entity, Row),
        run(Server, Name, [<<"-t">>, Target, <<"--">> | Args])
    end.

classify({error, #{code := command_error, stderr := Stderr} = Detail}) ->
    Missing = case Stderr of
        <<"can't find session: ", _/binary>> -> true;
        <<"can't find window: ", _/binary>> -> true;
        <<"can't find pane: ", _/binary>> -> true;
        <<"no such session: ", _/binary>> -> true;
        <<"no such window: ", _/binary>> -> true;
        <<"no such pane: ", _/binary>> -> true;
        <<"no current target\n">> -> true;
        _ -> false
    end,
    {error, case Missing of true -> Detail#{code => target_gone}; false -> Detail end};
classify(Result) -> Result.
