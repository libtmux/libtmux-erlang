-module(tmux_observe).
-moduledoc false.
-export([get/3, created/3, snapshot/2, query/3, plan/2]).

%% Each arbitrary text field has its own output, prefixed by a checked ID.
%% Only the generated final newline is removed. Reads are not an atomic capture.
-spec get(tmux_server:t(), atom(), binary()) -> {ok, tmux_model:row()} | {error, map()}.
get(Server, Entity, Id) ->
    maybe
        {ok, Target} ?= tmux_target:selector(Entity, Id),
        {ok, Origin} ?= tmux_server:origin(Server),
        {ok, State} ?= read_state(Server, #{}),
        {ok, Row, _} ?= read_row(Entity, Id, Target, State),
        {ok, Server} ?= tmux_server:from_origin(Origin),
        {ok, tmux_model:bind(Row, Origin, make_ref())}
    end.

-spec snapshot(tmux_server:t(), map()) -> {ok, tmux_snapshot:t()} | {error, map()}.
snapshot(Server, Options) ->
    maybe
        {ok, Snapshot, _} ?= capture(Server, Options, none),
        {ok, Snapshot}
    end.

-spec query(tmux_server:t(), map(), map()) ->
    {ok, tmux_snapshot:t(), [term()]} | {error, map()}.
query(Server, Plan, Options) -> capture(Server, Options, Plan).

capture(Server, Options, Query) ->
    maybe
        {ok, State0} ?= read_state(Server, Options),
        {ok, Context} ?= tmux_server:observation_context(Server),
        Metadata = Context#{id => make_ref(), graph => complete,
                            capture_started => maps:get(started, State0)},
        {ok, First, State1} ?= spine(State0),
        {ok, Base} ?= tmux_snapshot:build(maps:get(rows, First), Metadata),
        ok ?= membership_occurrences(First, Base),
        {ok, Keys, StateQ} ?= candidates(Query, Base, State1),
        {ok, Observed, State2} ?= hydrate([session, window, pane], Base,
            #{window_link => tmux_snapshot:window_links(Base)}, StateQ),
        {ok, Last, State3} ?= spine(State2),
        ok ?= case First =:= Last of
            true -> ok;
            false -> {error, #{code => inconsistent_capture, reason => topology_changed}}
        end,
        {ok, Server} ?= tmux_server:from_origin(maps:get(origin, Context)),
        QueryMetadata = case Query of
            none -> #{};
            #{candidate := #{format := Format}, attempt := Attempt} ->
                #{query => #{candidate_count => length(Keys), pushed_down => Format =/= <<"1">>,
                             attempt => Attempt, consistency => observed}}
        end,
        {ok, Snapshot} ?= tmux_snapshot:build(Observed, maps:merge(QueryMetadata,
            Metadata#{capture_finished => now_us(),
            time_unit => microsecond, source_calls => lists:reverse(maps:get(calls, State3)),
            observed_bytes => maps:get(bytes, State3), consistency => observed,
            capabilities => #{field_schema => 1, identity => observed, capture => observed}})),
        {ok, Snapshot, Keys}
    end.

%% This codec contains only canonical IDs, integers and booleans. Text uses
%% isolated ID-prefixed frames and never enters the tab-separated scan.
-spec plan(tmux_schema:entity(), binary()) -> map().
plan(Entity, Candidate) ->
    Scans = [scan_spec(Kind) || Kind <- [session, window, pane]],
    Hydration = [#{entity => E, field => Field, command => <<"display-message">>,
        target => observed_id, format => <<"#{", Id/binary, "}\n#{", F/binary, "}">>,
        transport => one_shot, codec => id_prefixed_single_field}
        || E <- [session, window, pane],
           #{format := Id} <- [maps:get(id, tmux_schema_data:fields(E))],
           {Field, #{format := F, type := Type}} <- lists:sort(maps:to_list(tmux_schema_data:fields(E))),
           Type =:= text orelse Type =:= bytes],
    Native = case Candidate of
        <<"1">> -> [];
        _ -> [(scan_spec(Entity))#{filter => Candidate}]
    end,
    #{initial_spine => Scans, candidate => Native, hydration => Hydration,
      final_spine => Scans, empty_server => skip_window_and_pane_scans}.

scan_spec(session) -> #{entity => session, kind => session, command => <<"list-sessions">>,
    args => [], format => <<"#{session_id}\t#{session_attached}\t#{session_created}">>,
    transport => one_shot, codec => scalar_spine};
scan_spec(window) -> #{entity => window, kind => window, command => <<"list-windows">>,
    args => [<<"-a">>], format => <<"#{session_id}\t#{window_id}\t#{window_index}\t#{window_active}\t"
        "#{window_width}\t#{window_height}\t#{window_panes}">>,
    transport => one_shot, codec => scalar_spine};
scan_spec(window_link) -> (scan_spec(window))#{entity => window_link};
scan_spec(pane) -> #{entity => pane, kind => pane, command => <<"list-panes">>,
    args => [<<"-a">>], format => <<"#{session_id}\t#{window_id}\t#{window_index}\t#{pane_id}\t#{pane_index}\t#{pane_active}\t"
        "#{pane_dead}\t#{pane_dead_status}\t#{pane_height}\t#{pane_pid}\t#{pane_width}">>,
    transport => one_shot, codec => scalar_spine}.

scan(Entity, Candidate, State) ->
    #{kind := Kind, command := Name, args := Args, format := Format} = scan_spec(Entity),
    FilterArgs = case Candidate of none -> []; _ -> [<<"-f">>, Candidate] end,
    maybe
        {ok, Bytes, Next} ?= command(Name, Args ++ FilterArgs ++ [<<"-F">>, Format], State),
        {ok, Rows} ?= scan_rows(Kind, Bytes, Next),
        {ok, Rows, Next}
    end.

candidates(none, _, State) -> {ok, [], State};
candidates(#{entity := Entity, candidate := #{format := Format}}, Base, State) ->
    All = tmux_snapshot:rows(Entity, Base),
    case Format =:= <<"1">> orelse All =:= [] of
        true -> {ok, [identity(Row) || Row <- All], State};
        false ->
            maybe
                {ok, Source, Next} ?= scan(Entity, Format, State),
                Rows = case Entity of
                    window -> [W || {_, W} <- Source];
                    window_link -> [L || {L, _} <- Source];
                    pane -> [P || {_, P} <- Source];
                    session -> Source
                end,
                ok ?= check_candidates(Rows, Entity, Base),
                {ok, lists:usort([identity(Row) || Row <- Rows]), Next}
            end
    end.

check_candidates([], _, _) -> ok;
check_candidates([Row | Rest], Entity, Base) ->
    case tmux_snapshot:get(Entity, identity(Row), Base) of
        {ok, Previous} ->
            case tmux_model:to_map(Row) =:= tmux_model:to_map(Previous) of
                true -> check_candidates(Rest, Entity, Base);
                false -> {error, #{code => inconsistent_capture, reason => candidate_values_changed}}
            end;
        _ -> {error, #{code => inconsistent_capture, reason => candidate_identity_changed}}
    end.

identity(Row) ->
    case tmux_model:entity(Row) of
        window_link -> {tmux_model:get(session_id, Row), tmux_model:get(index, Row),
                        tmux_model:get(window_id, Row)};
        _ -> tmux_model:get(id, Row)
    end.

-spec created(tmux_server:t(), atom(), map()) -> {ok, tmux_model:row()} | {error, map()}.
created(Server, Entity, #{stdout := Output} = CommandResult) ->
    Result = maybe
        {ok, Id} ?= final_newline(Output),
        {ok, _} ?= tmux_target:selector(Entity, Id),
        case get(Server, Entity, Id) of
            {ok, _} = Created -> Created;
            {error, Cause} -> {error, #{code => post_action_read_failed,
                created_id => Id, entity => Entity, cause => Cause}}
        end
    end,
    case Result of
        {error, Detail} -> {error, Detail#{mutation => completed, command_result => CommandResult}};
        Success -> Success
    end.

read_row(Entity, Id, Target, State) ->
    read_row(Entity, Id, Target, #{id => Id}, State).

read_row(Entity, Id, Target, Observed, State) ->
    {ok, Schema} = tmux_schema:fields(Entity),
    #{format := IdFormat} = maps:get(id, Schema),
    Missing = [{K, M} || {K, M = #{format := _}} <- lists:sort(maps:to_list(Schema)),
                         not is_map_key(K, Observed)],
    {Scalars, Text} = lists:partition(fun({_, #{type := Type}}) ->
        lists:member(Type, [boolean, uint, integer, pane_id, window_id, session_id])
    end, Missing),
    maybe
        {ok, Numeric, State1} ?= scalar_fields(Scalars, Target, Id, IdFormat, Observed, State),
        {ok, Fields, Next} ?= fields(Text, Target, Id, IdFormat, Numeric, State1),
        {ok, Row} ?= tmux_model:new(Entity, Fields),
        {ok, Row, Next}
    end.

%% Only canonical IDs, numbers, booleans and nullable numeric blanks enter
%% this tab-separated codec. Text and terminal bytes keep individual frames.
scalar_fields([], _, _, _, Acc, State) -> {ok, Acc, State};
scalar_fields(Fields, Target, Id, IdFormat, Acc, State) ->
    Formats = [<<"#{", F/binary, "}">> || {_, #{format := F}} <- Fields],
    Format = iolist_to_binary(lists:join(<<"\t">>, Formats)),
    maybe
        {ok, Bytes, Next} ?= field_bytes(Format, Target, Id, IdFormat, State),
        {ok, Values} ?= scalar_values(Fields, binary:split(Bytes, <<"\t">>, [global]), Acc),
        {ok, Values, Next}
    end.

scalar_values([], [], Acc) -> {ok, Acc};
scalar_values([{Key, Metadata} | Rest], [Bytes | Tail], Acc) ->
    maybe
        {ok, Value} ?= decode_field(Key, Metadata, Bytes),
        scalar_values(Rest, Tail, Acc#{Key => Value})
    end;
scalar_values(_, _, _) -> {error, #{code => invalid_scalar_observation}}.

fields([], _, _, _, Acc, State) -> {ok, Acc, State};
fields([{Key, #{format := Format} = Metadata} | Rest], Target, Id, IdFormat, Acc, State) ->
    maybe
        {ok, Bytes, Next} ?= field_bytes(<<"#{", Format/binary, "}">>, Target, Id, IdFormat, State),
        {ok, Value} ?= decode_field(Key, Metadata, Bytes),
        fields(Rest, Target, Id, IdFormat, Acc#{Key => Value}, Next)
    end.

field_bytes(Format, Target, Id, IdFormat, State) ->
    Expression = <<"#{", IdFormat/binary, "}\n", Format/binary>>,
    maybe
        {ok, Raw, Next} ?= command(<<"display-message">>,
            [<<"-p">>, <<"-t">>, Target, <<"-F">>, Expression], State),
        {ok, Output} ?= final_newline(Raw),
        case binary:split(Output, <<"\n">>) of
            [Id, FieldBytes] -> {ok, FieldBytes, Next};
            _ -> {error, #{code => target_gone}}
        end
    end.

decode_field(Key, Metadata, Bytes) ->
    case decode(Metadata, Bytes) of
        {error, Detail} -> {error, Detail#{path => [Key]}};
        Decoded -> Decoded
    end.

read_state(Server, Options) when is_map(Options) ->
    Defaults = #{consistency => observed, deadline_ms => 2500,
                 max_rows => 4096, max_bytes => 8388608},
    #{consistency := Consistency, deadline_ms := Deadline, max_rows := Rows,
      max_bytes := Bytes} = maps:merge(Defaults, Options),
    Valid = maps:without(maps:keys(Defaults), Options) =:= #{} andalso
        is_integer(Deadline, 1, 600000) andalso is_integer(Rows, 1, 65536) andalso
        is_integer(Bytes, 1, 67108864),
    case {Consistency, Valid} of
        {observed, true} ->
            Started = now_us(),
            {ok, #{server => Server, started => Started, deadline => Started + Deadline * 1000,
                   max_rows => Rows, max_bytes => Bytes, bytes => 0, calls => []}};
        {observed, false} -> {error, #{code => invalid_capture_options}};
        _ -> {error, #{code => unsupported_consistency}}
    end;
read_state(_, _) -> {error, #{code => invalid_capture_options}}.

command(Name, Args, #{server := Server, deadline := Deadline,
                      bytes := Bytes, max_bytes := Limit, calls := Calls} = State) ->
    Started = now_us(),
    Remaining = (Deadline - Started) div 1000,
    case {Remaining > 0, Bytes < Limit} of
        {false, _} -> {error, #{code => capture_deadline}};
        {_, false} -> {error, #{code => capture_limit, limit => max_bytes}};
        {true, true} ->
            maybe
                {ok, #{stdout := Output}} ?= tmux_target:run(Server, Name, Args,
                    #{deadline_ms => Remaining, max_stdout => min(1048576, Limit - Bytes)}),
                Call = #{command => Name, args => Args, started => Started,
                         finished => now_us(), stdout_bytes => byte_size(Output)},
                {ok, Output, State#{bytes => Bytes + byte_size(Output), calls => [Call | Calls]}}
            end
    end.

spine(State) ->
    maybe
        {ok, Sessions, State1} ?= scan(session, none, State),
        spine_windows(Sessions, State1)
    end.

spine_windows([], State) ->
    {ok, #{rows => #{session => [], window => [], window_link => [], pane => []},
           occurrences => []}, State};
spine_windows(Sessions, State) ->
    maybe
        {ok, Windows, State1} ?= scan(window, none, State),
        {ok, Panes, State2} ?= scan(pane, none, State1),
        ok ?= row_limit(length(Sessions) + length(Windows) + length(Panes), State2),
        {ok, #{rows => #{session => Sessions, window => [W || {_, W} <- Windows],
                         window_link => [L || {L, _} <- Windows], pane => [P || {_, P} <- Panes]},
               occurrences => Panes}, State2}
    end.

scan_rows(_Kind, <<>>, _State) -> {ok, []};
scan_rows(Kind, Bytes, State) ->
    maybe
        {ok, Body} ?= final_newline(Bytes),
        Lines = binary:split(Body, <<"\n">>, [global]),
        ok ?= row_limit(length(Lines), State),
        scan_lines(Kind, Lines, [])
    end.

scan_lines(_, [], Acc) -> {ok, lists:sort(Acc)};
scan_lines(Kind, [Line | Rest], Acc) ->
    maybe
        {ok, Row} ?= scan_line(Kind, binary:split(Line, <<"\t">>, [global])),
        scan_lines(Kind, Rest, [Row | Acc])
    end.

scan_line(session, [Id, Attached, Created]) ->
    scan_model(session, [{id, Id}, {attached_count, Attached}, {created, Created}]);
scan_line(window, [Session, Window, Index, Active, Width, Height, Count]) ->
    maybe
        {ok, Link} ?= scan_model(window_link,
            [{session_id, Session}, {window_id, Window}, {index, Index}, {active, Active}]),
        {ok, Row} ?= scan_model(window,
            [{id, Window}, {width, Width}, {height, Height}, {pane_count, Count}]),
        {ok, {Link, Row}}
    end;
scan_line(pane, [Session, Window, WindowIndex, Pane, Index, Active, Dead, Status, Height, Pid, Width]) ->
    maybe
        {ok, Link} ?= scan_model(window_link,
            [{session_id, Session}, {window_id, Window}, {index, WindowIndex}]),
        {ok, Row} ?= scan_model(pane,
            [{id, Pane}, {window_id, Window}, {index, Index}, {active, Active},
             {dead, Dead}, {exit_status, Status}, {height, Height}, {pid, Pid}, {width, Width}]),
        {ok, {{tmux_model:get(session_id, Link), tmux_model:get(index, Link),
                tmux_model:get(window_id, Link)}, Row}}
    end;
scan_line(_, _) -> {error, #{code => invalid_identity_scan}}.

scan_model(Entity, Pairs) ->
    maybe
        {ok, Fields} ?= scan_fields(Entity, Pairs, #{}),
        tmux_model:new(Entity, Fields)
    end.
scan_fields(_, [], Acc) -> {ok, Acc};
scan_fields(Entity, [{Field, Bytes} | Rest], Acc) ->
    {ok, Metadata} = tmux_schema:field(Entity, Field),
    maybe
        {ok, Value} ?= decode(Metadata, Bytes),
        scan_fields(Entity, Rest, Acc#{Field => Value})
    end.

row_limit(Count, #{max_rows := Limit}) when Count =< Limit -> ok;
row_limit(_, _) -> {error, #{code => capture_limit, limit => max_rows}}.

membership_occurrences(#{occurrences := Occurrences}, Base) ->
    Observed = lists:foldl(fun({Link, Pane}, Acc) ->
        Acc#{Link => [tmux_model:get(id, Pane) | maps:get(Link, Acc, [])]}
    end, #{}, Occurrences),
    Expected = maps:from_list([begin
        {ok, Window} = tmux_snapshot:related(window, Link, Base),
        {ok, Panes} = tmux_snapshot:related(panes, Window, Base),
        {{tmux_model:get(session_id, Link), tmux_model:get(index, Link),
          tmux_model:get(window_id, Link)}, lists:sort([tmux_model:get(id, P) || P <- Panes])}
    end || Link <- tmux_snapshot:window_links(Base)]),
    case maps:map(fun(_, Ids) -> lists:sort(Ids) end, Observed) =:= Expected of
        true -> ok;
        false -> {error, #{code => inconsistent_capture, reason => pane_memberships}}
    end.

hydrate([], _, Acc, State) -> {ok, Acc, State};
hydrate([Entity | Rest], Base, Acc, State) ->
    maybe
        {ok, Rows, Next} ?= hydrate_rows(tmux_snapshot:rows(Entity, Base), [], State),
        hydrate(Rest, Base, Acc#{Entity => Rows}, Next)
    end.
hydrate_rows([], Acc, State) -> {ok, lists:reverse(Acc), State};
hydrate_rows([Base | Rest], Acc, State) ->
    Entity = tmux_model:entity(Base),
    Id = tmux_model:get(id, Base),
    {ok, Target} = tmux_target:selector(Entity, Id),
    Observed = maps:filter(fun(_, Value) -> Value =/= not_loaded end, tmux_model:to_map(Base)),
    maybe
        {ok, Row, Next} ?= read_row(Entity, Id, Target, Observed, State),
        hydrate_rows(Rest, [Row | Acc], Next)
    end.

now_us() -> erlang:monotonic_time(microsecond).

decode(#{nullable := true}, <<>>) -> {ok, none};
decode(#{format := <<"pane_pid">>}, <<"0">>) -> {ok, none};
decode(#{type := boolean}, <<"0">>) -> {ok, false};
decode(#{type := boolean}, <<"1">>) -> {ok, true};
decode(#{type := Type} = Metadata, Bytes) when Type =:= uint; Type =:= integer ->
    try binary_to_integer(Bytes) of
        Value -> tmux_schema:value(Metadata, Value)
    catch error:badarg -> {error, #{code => invalid_observation, expected => Type}}
    end;
decode(Metadata, Bytes) -> tmux_schema:value(Metadata, Bytes).

final_newline(Bytes) when is_binary(Bytes), byte_size(Bytes) > 0 ->
    Size = byte_size(Bytes) - 1,
    case Bytes of
        <<Value:Size/binary, $\n>> -> {ok, Value};
        _ -> {error, #{code => invalid_command_output}}
    end;
final_newline(_) -> {error, #{code => invalid_command_output}}.
