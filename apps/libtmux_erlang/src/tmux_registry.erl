-module(tmux_registry).
-moduledoc false.
-behaviour(gen_server).
-export([start_link/0, register/2, revoke/1, lookup/1, program_pool/0, program_slots/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).
-define(PROGRAM_LIMIT, 8).

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

-spec program_pool() -> {ok, tmux_admission:t()} | {error, map()}.
program_pool() ->
    try ets:lookup(?MODULE, program_pool) of
        [{program_pool, Pool}] -> {ok, Pool};
        [] -> {error, #{code => registry_unavailable}}
    catch error:badarg -> {error, #{code => registry_unavailable}}
    end.

-spec program_slots() -> [pos_integer()].
program_slots() -> lists:seq(1, ?PROGRAM_LIMIT).

request(Request) ->
    try gen_server:call(?MODULE, Request, 900)
    catch exit:_ -> {error, #{code => registry_unavailable}}
    end.

-spec init([]) -> {ok, map()}.
init([]) ->
    _ = ets:new(?MODULE, [named_table, protected, set, {read_concurrency, true}]),
    Generation = make_ref(),
    Pool = tmux_admission:new(Generation, ?PROGRAM_LIMIT, ?PROGRAM_LIMIT),
    true = ets:insert(?MODULE, {program_pool, Pool}),
    {ok, #{owners => #{}, monitors => #{}, program_pool => Pool, program_generation => Generation,
           program_starters => #{}, program_monitors => #{},
           program_sweep => erlang:start_timer(100, self(), sweep_programs)}}.

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
handle_info({tmux_admission, Generation, Lease, Owner, {program, Reply, StartBy, Deadline, Function}},
            #{program_generation := Generation, program_pool := Pool} = State)
  when is_reference(Reply), is_integer(StartBy), is_integer(Deadline), is_function(Function, 1) ->
    case tmux_admission:claim(Pool, Lease, Owner, 1) of
        ok -> {noreply, prepare_program(Lease, Owner, Reply, StartBy, Deadline, Function, State)};
        {error, _} ->
            Reply ! {Reply, {error, #{code => admission_expired, outcome => not_started}}},
            {noreply, State}
    end;
handle_info({program_prepared, Starter, Result}, #{program_starters := Starters} = State) ->
    case maps:take(Starter, Starters) of
        {{Monitor, Lease, Reply}, Rest} ->
            demonitor(Monitor, [flush]),
            {noreply, prepared_program(Lease, Reply, Result, State#{program_starters => Rest})};
        error -> {noreply, State}
    end;
handle_info({timeout, Timer, sweep_programs}, #{program_sweep := Timer, program_pool := Pool} = State) ->
    _ = tmux_admission:expire(Pool),
    {noreply, State#{program_sweep => erlang:start_timer(100, self(), sweep_programs)}};
handle_info({'DOWN', Monitor, process, Pid, _},
            #{program_starters := Starters, program_monitors := Programs, program_pool := Pool} = State) ->
    case maps:take(Monitor, Programs) of
        {Lease, Rest} ->
            ok = tmux_admission:release(Pool, Lease),
            {noreply, State#{program_monitors => Rest}};
        error ->
            case maps:take(Pid, Starters) of
                {{Monitor, Lease, Reply}, Rest} ->
                    Error = {error, #{code => program_owner_unavailable, outcome => not_started}},
                    {noreply, prepared_program(Lease, Reply, Error, State#{program_starters => Rest})};
                _ -> {noreply, endpoint_down(Monitor, State)}
            end
    end;
handle_info(_, State) -> {noreply, State}.

endpoint_down(Monitor, State) ->
    case maps:find(Monitor, maps:get(monitors, State)) of
        {ok, Owner} -> remove(Owner, State);
        error -> State
    end.

%% Endpoint initialization calls this registry from inside the supervisor.
%% A separate starter keeps that registration path open.
prepare_program(Lease, Owner, Reply, StartBy, Deadline, Function,
                #{program_starters := Starters} = State) ->
    Registry = self(),
    {Starter, Monitor} = spawn_monitor(fun() ->
        Result = tmux_program_owner:prepare(Owner, StartBy, Deadline, Function),
        Registry ! {program_prepared, self(), Result}
    end),
    State#{program_starters => Starters#{Starter => {Monitor, Lease, Reply}}}.

prepared_program(Lease, Reply, {ok, Pid, Program}, #{program_monitors := Programs} = State) ->
    Monitor = monitor(process, Pid),
    Reply ! {Reply, {ok, Program}},
    State#{program_monitors => Programs#{Monitor => Lease}};
prepared_program(Lease, Reply, {error, _} = Error, #{program_pool := Pool} = State) ->
    ok = tmux_admission:release(Pool, Lease),
    Reply ! {Reply, Error},
    State.

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
