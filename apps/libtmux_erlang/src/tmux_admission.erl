-module(tmux_admission).
-moduledoc false.
-export([new/1, reserve/4, deliver/4, claim/4, release/2, expire/1,
         close/1, stats/1, lookup/2]).
-export_type([t/0]).

-opaque t() :: {admission, ets:tid(), reference()}.

-spec new(reference()) -> t().
new(Generation) when is_reference(Generation) ->
    Table = ets:new(?MODULE, [public, set, {read_concurrency, true}, {write_concurrency, true}]),
    Free = [erlang:alias() || _ <- lists:seq(1, 64)],
    true = ets:insert(Table, {state, 0, #{generation => Generation, open => true,
                                       bytes => 0, leases => #{}, free => Free}}),
    {admission, Table, Generation}.

-spec reserve(t(), pid(), non_neg_integer(), integer()) -> {ok, reference()} | {error, map()}.
reserve(Admission, Owner, Bytes, Deadline)
  when is_pid(Owner), node(Owner) =:= node(), is_integer(Bytes, 0, 262144), is_integer(Deadline) ->
    Lease = make_ref(),
    edit(Admission, fun(State) ->
        #{open := Open, bytes := Used, leases := Leases, free := Free} = State,
        Now = now_ms(),
        case {Open, Deadline > Now andalso is_process_alive(Owner), Free =/= [] andalso Used + Bytes =< 262144} of
            {false, _, _} -> {{error, #{code => server_closed}}, State};
            {_, false, _} -> {{error, #{code => admission_expired}}, State};
            {_, _, false} -> {{error, #{code => busy}}, State};
            {true, true, true} ->
                [Alias | Rest] = Free,
                Entry = #{owner => Owner, bytes => Bytes, expires => min(Deadline, Now + 900),
                          phase => reserved, alias => Alias},
                {{ok, Lease}, State#{free => Rest, bytes => Used + Bytes,
                                    leases => Leases#{Lease => Entry}}}
        end
    end);
reserve(_, _, _, _) -> {error, #{code => invalid_admission}}.

-spec deliver(t(), reference(), non_neg_integer(), term()) -> ok | {error, map()}.
deliver({admission, _, Generation} = Admission, Lease, Bytes, Payload) ->
    Result = edit(Admission, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:find(Lease, Leases) of
            {ok, #{owner := Owner, bytes := Reserved, expires := Expires,
                   phase := reserved, alias := Alias} = Entry}
              when Owner =:= self(), is_integer(Bytes, 0, Reserved) ->
                case maps:get(open, State) andalso now_ms() < Expires of
                    true -> {{ok, Alias}, State#{leases => Leases#{Lease => Entry#{phase => sent}}}};
                    false -> {{error, #{code => admission_expired}}, State}
                end;
            _ -> {{error, #{code => invalid_lease}}, State}
        end
    end),
    case Result of
        {ok, Alias} -> Alias ! {tmux_admission, Generation, Lease, self(), Payload}, ok;
        Error -> Error
    end.

-spec claim(t(), reference(), pid(), non_neg_integer()) -> ok | {error, map()}.
claim(Admission, Lease, Owner, Bytes) ->
    owner(Admission),
    Result = edit(Admission, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:find(Lease, Leases) of
            {ok, #{owner := Owner, bytes := Reserved, expires := Expires,
                   phase := sent, alias := Alias} = Entry} when is_integer(Bytes, 0, Reserved) ->
                case maps:get(open, State) andalso now_ms() < Expires andalso is_process_alive(Owner) of
                    true -> {{ok, Alias}, State#{leases => Leases#{Lease => Entry#{phase => accepted}}}};
                    false -> {{error, #{code => invalid_lease}}, State}
                end;
            _ -> {{error, #{code => invalid_lease}}, State}
        end
    end),
    case Result of
        {ok, Alias} -> _ = erlang:unalias(Alias), ok;
        Error -> Error
    end.

-spec release(t(), reference()) -> ok.
release({admission, _, Generation} = Admission, Lease) ->
    owner(Admission),
    case lookup(Admission, Lease) of
        {ok, #{alias := Alias}} ->
            _ = erlang:unalias(Alias),
            flush(Generation, Lease),
            NewAlias = case stats(Admission) of
                {ok, #{open := true}} -> [erlang:alias()];
                _ -> []
            end,
            ok = edit(Admission, fun(State) ->
                case maps:take(Lease, maps:get(leases, State)) of
                    {#{bytes := Bytes}, Rest} ->
                        {ok, State#{leases => Rest, bytes => maps:get(bytes, State) - Bytes,
                                    free => NewAlias ++ maps:get(free, State)}};
                    error -> {ok, State}
                end
            end);
        {error, _} -> ok
    end.

-spec expire(t()) -> [{reference(), map()}].
expire(Admission) ->
    owner(Admission),
    {ok, State} = read(Admission),
    Now = now_ms(),
    Expired = [{Lease, Entry} || {Lease, #{phase := Phase, expires := At, owner := Owner} = Entry}
                                   <- maps:to_list(maps:get(leases, State)),
                               Phase =/= accepted,
                               (not maps:get(open, State)) orelse At =< Now orelse not is_process_alive(Owner)],
    lists:foreach(fun({Lease, _}) -> ok = release(Admission, Lease) end, Expired),
    Expired.

-spec close(t()) -> ok.
close(Admission) ->
    owner(Admission),
    {ok, Free} = edit(Admission, fun(State) ->
        {{ok, maps:get(free, State)}, State#{open => false, free => []}}
    end),
    lists:foreach(fun(Alias) -> _ = erlang:unalias(Alias) end, Free),
    ok.

-spec stats(t()) -> {ok, map()} | {error, map()}.
stats(Admission) ->
    case read(Admission) of
        {ok, State} -> {ok, #{open => maps:get(open, State), bytes => maps:get(bytes, State),
                             operations => map_size(maps:get(leases, State))}};
        Error -> Error
    end.

-spec lookup(t(), reference()) -> {ok, map()} | {error, map()}.
lookup(Admission, Lease) ->
    case read(Admission) of
        {ok, #{leases := Leases}} ->
            case maps:find(Lease, Leases) of
                {ok, Entry} -> {ok, Entry};
                error -> {error, #{code => invalid_lease}}
            end;
        Error -> Error
    end.

owner({admission, Table, _}) ->
    case ets:info(Table, owner) of
        Pid when Pid =:= self() -> ok;
        _ -> error(not_admission_owner)
    end.

read({admission, Table, Generation}) ->
    try ets:lookup(Table, state) of
        [{state, _, #{generation := Generation} = State}] -> {ok, State};
        _ -> {error, #{code => server_closed}}
    catch error:badarg -> {error, #{code => server_closed}}
    end.

%% Each of the 64 slots permits at most one reserve and one deliver mutation
%% while the owner is releasing a slot. Leave a final retry after those writes.
edit(Admission, Fun) -> edit(Admission, Fun, 256).
edit(_, _, 0) -> {error, #{code => busy}};
edit({admission, Table, Generation} = Admission, Fun, Tries) ->
    try ets:lookup(Table, state) of
        [{state, Version, #{generation := Generation} = State}] ->
            {Reply, Next} = Fun(State),
            case Next =:= State of
                true -> Reply;
                false ->
                    Match = [{{state, Version, '_'}, [], [{const, {state, Version + 1, Next}}]}],
                    case ets:select_replace(Table, Match) of
                        1 -> Reply;
                        0 -> edit(Admission, Fun, Tries - 1)
                    end
            end;
        _ -> {error, #{code => server_closed}}
    catch error:badarg -> {error, #{code => server_closed}}
    end.

flush(Generation, Lease) ->
    receive {tmux_admission, Generation, Lease, _, _} -> flush(Generation, Lease)
    after 0 -> ok
    end.

now_ms() -> erlang:monotonic_time(millisecond).
