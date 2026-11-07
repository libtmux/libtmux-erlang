-module(tmux_registry).
-moduledoc false.
-behaviour(gen_server).
-export([start_link/0, register/2, revoke/1, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(reference(), tmux_admission:t()) ->
    {ok, reference(), pid()} | {error, map()}.
register(Generation, Admission) -> request({register, Generation, Admission}).

-spec revoke(reference()) -> ok | {error, map()}.
revoke(Origin) -> request({revoke, Origin}).

-spec lookup(reference()) -> {ok, {pid(), reference(), tmux_admission:t()}} | {error, map()}.
lookup(Origin) when is_reference(Origin) ->
    try ets:lookup(?MODULE, Origin) of
        [{Origin, Owner, Generation, Admission}] ->
            case is_process_alive(Owner) of
                true -> {ok, {Owner, Generation, Admission}};
                false -> stale()
            end;
        [] -> stale()
    catch error:badarg -> stale()
    end;
lookup(_) -> stale().

request(Request) ->
    try gen_server:call(?MODULE, Request, 900)
    catch exit:_ -> {error, #{code => registry_unavailable}}
    end.

-spec init([]) -> {ok, map()}.
init([]) ->
    _ = ets:new(?MODULE, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #{owners => #{}, monitors => #{}}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({register, Generation, Admission}, {Owner, _}, State) when is_reference(Generation) ->
    Owners = maps:get(owners, State),
    case maps:is_key(Owner, Owners) of
        true -> {reply, {error, #{code => already_registered}}, State};
        false ->
            Origin = make_ref(),
            Monitor = monitor(process, Owner),
            true = ets:insert(?MODULE, {Origin, Owner, Generation, Admission}),
            {reply, {ok, Origin, self()}, State#{owners => Owners#{Owner => {Origin, Monitor}},
                monitors => (maps:get(monitors, State))#{Monitor => Owner}}}
    end;
handle_call({revoke, Origin}, {Owner, _}, State) ->
    case ets:lookup(?MODULE, Origin) of
        [{Origin, Owner, _, _}] -> {reply, ok, remove(Owner, State)};
        [] -> {reply, ok, State};
        _ -> {reply, {error, #{code => wrong_owner}}, State}
    end;
handle_call(_, _, State) -> {reply, {error, #{code => invalid_registration}}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_, State) -> {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({'DOWN', Monitor, process, _, _}, State) ->
    case maps:find(Monitor, maps:get(monitors, State)) of
        {ok, Owner} -> {noreply, remove(Owner, State)};
        error -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun
        (state, State) -> #{registered_owners => map_size(maps:get(owners, State))};
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (_, Value) -> Value
    end, maps:without([log], Status)).

remove(Owner, State) ->
    {{Origin, Monitor}, Owners} = maps:take(Owner, maps:get(owners, State)),
    true = ets:delete(?MODULE, Origin),
    demonitor(Monitor, [flush]),
    State#{owners => Owners, monitors => maps:remove(Monitor, maps:get(monitors, State))}.

stale() -> {error, #{code => stale_reference}}.
