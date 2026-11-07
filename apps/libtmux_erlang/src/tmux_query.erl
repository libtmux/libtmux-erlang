-module(tmux_query).
-moduledoc """
Describe a future tmux observation and execute it explicitly with fetch.

Constructors, where, limit, pushdown and explain perform no tmux I/O. where
validates trusted criteria and conjoins repeated calls. fetch returns an
ordered selection backed by a complete captured graph. Native filtering is a
necessary condition; the full filter always runs locally before the limit.

Captures span commands and are not atomic. Candidate IDs excluded at one
observation cannot be recovered by later local filtering. pushdown(false, Q)
evaluates the complete captured view without an earlier candidate exclusion.
Numeric candidate fields come from the restricted scalar codec and must agree
with the capture's scalar observations. Text and relationships remain local.

```erlang
1> Q0 = tmux_query:panes(unopened), ok.
ok
2> Q = tmux_query:where(#{width => #{gte => 120}}, Q0), ok.
ok
3> maps:get(format, maps:get(candidate, tmux_query:explain(Q))).
<<"#{e|>=|:#{pane_width},120}">>
```
""".
-export([panes/1, windows/1, window_links/1, sessions/1, where/2, limit/2,
         pushdown/2, explain/1, fetch/1, fetch/2]).
-export_type([t/0]).
-record(query, {server :: tmux_server:t(), entity :: tmux_schema:entity(),
                filter = none :: none | tmux_filter:t(),
                limit = infinity :: infinity | non_neg_integer(),
                pushdown = true :: boolean()}).
-export_type([fetch_options/0]).
-doc "Capture bounds plus an explicitly requested single inconsistent-capture retry; default retry is zero.".
-type fetch_options() :: #{deadline_ms => 1..600000, max_rows => 1..65536,
    max_bytes => 1..67108864, consistency => observed | atomic, retry => 0 | 1}.

-doc """
An immutable description of future tmux reads. Only fetch executes it.
""".
-opaque t() :: #query{}.

-doc """
Describe a future server-wide physical pane query. Performs no I/O;
`fetch/1` is the execution boundary.
""".
-spec panes(tmux_server:t()) -> t().
panes(Server) -> #query{server = Server, entity = pane}.
-doc """
Describe a future query over unique physical windows. Performs no I/O.
""".
-spec windows(tmux_server:t()) -> t().
windows(Server) -> #query{server = Server, entity = window}.
-doc """
Describe a future query over session-relative window memberships.
Repeated physical windows retain distinct membership identity. Performs no I/O.
""".
-spec window_links(tmux_server:t()) -> t().
window_links(Server) -> #query{server = Server, entity = window_link}.
-doc """
Describe a future server-wide session query without executing tmux.
""".
-spec sessions(tmux_server:t()) -> t().
sessions(Server) -> #query{server = Server, entity = session}.

-doc """
Validate trusted criteria for this entity and conjoin them with prior
conditions. Returns a new immutable query; malformed criteria raise bad_filter.
This performs no I/O.
""".
-spec where(map() | tmux_filter:t(), t()) -> t().
where(Criteria, #query{entity = Entity, filter = Previous} = Query) ->
    Filter = tmux_filter:new_or_error(Entity, Criteria),
    Combined = case Previous of
        none -> Filter;
        _ ->
            Wire = tmux_filter:to_wire(Filter),
            Prior = tmux_filter:to_wire(Previous),
            case tmux_filter:from_wire(Entity, Wire#{<<"where">> =>
                    #{<<"and">> => [maps:get(<<"where">>, Prior), maps:get(<<"where">>, Wire)]}}) of
                {ok, Result} -> Result;
                {error, Detail} -> error({bad_filter, Detail})
            end
    end,
    Query#query{filter = Combined}.

-doc """
Set a final result limit from 0 through 65536, applied after residual filtering and
identity handling. It is not a candidate-fetch limit. Performs no I/O; invalid
counts raise bad_query_limit.
""".
-spec limit(0..65536, t()) -> t().
limit(Count, Query) when is_integer(Count, 0, 65536) -> Query#query{limit = Count};
limit(Count, _) -> error({bad_query_limit, Count}).

-doc """
Enable or disable native candidate exclusion, returning a new query.
Disabling pushdown evaluates the full captured view locally; neither mode
promises an atomic graph. Performs no I/O.
""".
-spec pushdown(boolean(), t()) -> t().
pushdown(Enabled, Query) when is_boolean(Enabled) -> Query#query{pushdown = Enabled}.

-doc """
Inspect command templates, necessary candidate conditions, full residual,
hydration, required fields, ordering and temporal assumptions. Performs no I/O
and does not contact the endpoint to claim dynamic capabilities.
""".
-spec explain(t()) -> map().
explain(#query{entity = Entity, limit = Limit, pushdown = Enabled} = Query) ->
    Filter = filter(Query),
    Candidate = case Enabled of
        true -> tmux_query_plan:compile(Filter);
        false -> #{format => <<"1">>, exact => false, local_only => [#{reason => disabled}]}
    end,
    #{entity => Entity, candidate => Candidate, residual => tmux_filter:to_wire(Filter),
      required => tmux_filter:requirements(Filter), limit => Limit,
      commands => tmux_observe:plan(Entity, maps:get(format, Candidate)),
      hydration => complete_graph, ordering => case Entity of
          window_link -> session_index_window; _ -> numeric_id end,
      deduplication => case Entity of window_link -> membership; _ -> physical_id end,
      capabilities => #{minimum_tmux => {3, 3}, transport => one_shot},
      consistency => observed, atomic => false,
      candidate_scalars => same_row_checked_against_spine,
      text_and_relations => later_observations,
      temporal_limit => excluded_rows_cannot_be_recovered}.

-doc """
Execute with default capture bounds and no retry. Returns an ordered
selection whose complete graph remains locally readable. See `fetch/2` for
resource limits, requested retries and operational errors.
""".
-spec fetch(t()) -> {ok, tmux_select:t()} | {error, map()}.
fetch(Query) -> fetch(Query, #{}).

-doc """
Execute the planned observation, full local predicate and final limit.

Capture options are those of `tmux_server:snapshot/2`. retry is 0 (default) or
1 and retries only inconsistent_capture, within the original capture deadline.
The retry is a new read-only capture. No mutations are retried. Invalid
capture requests return tagged errors, including unsupported consistency.

```erlang
1> tmux_query:fetch(tmux_query:panes(unopened), #{retry => 2}).
{error,#{code => invalid_query_options}}
```
""".
-spec fetch(t(), fetch_options()) -> {ok, tmux_select:t()} | {error, map()}.
fetch(Query, Options) when is_map(Options) ->
    Retry = maps:get(retry, Options, 0),
    Capture = maps:remove(retry, Options),
    case is_integer(Retry, 0, 1) of
        true -> fetch_attempt(Query, explain(Query), Capture, Retry, 1,
                              erlang:monotonic_time(millisecond));
        false -> {error, #{code => invalid_query_options}}
    end;
fetch(_, _) -> {error, #{code => invalid_query_options}}.

filter(#query{filter = none, entity = Entity}) -> tmux_filter:new_or_error(Entity, #{});
filter(#query{filter = Filter}) -> Filter.

fetch_attempt(#query{server = Server} = Query, Plan, Options, Retry, Attempt, Started) ->
    RunPlan = Plan#{attempt => Attempt, query_started => Started},
    case tmux_observe:query(Server, RunPlan, Options) of
        {ok, Snapshot, Keys} -> select(Query, Snapshot, Keys);
        {error, #{code := inconsistent_capture}} when Retry > 0 ->
            Deadline = maps:get(deadline_ms, Options, 2500),
            Remaining = Deadline - (erlang:monotonic_time(millisecond) - Started),
            case Remaining > 0 of
                true -> fetch_attempt(Query, Plan, Options#{deadline_ms => Remaining},
                                      Retry - 1, Attempt + 1, Started);
                false -> {error, #{code => capture_deadline}}
            end;
        {error, _} = Error -> Error
    end.

select(#query{entity = Entity, limit = Limit} = Query, Snapshot, Keys) ->
    Selection = case Entity of
        pane -> tmux_select:panes(Snapshot);
        window -> tmux_select:windows(Snapshot);
        window_link -> tmux_select:window_links(Snapshot);
        session -> tmux_select:sessions(Snapshot)
    end,
    Set = maps:from_keys(Keys, true),
    Candidates = tmux_select:filter(fun(Row) -> maps:is_key(identity(Row), Set) end, Selection),
    maybe
        {ok, Matched} ?= tmux_select:try_where(filter(Query), Candidates),
        {ok, case Limit of infinity -> Matched; _ -> tmux_select:take(Limit, Matched) end}
    end.

identity(Row) ->
    case tmux_model:entity(Row) of
        window_link -> {tmux_model:get(session_id, Row), tmux_model:get(index, Row),
                        tmux_model:get(window_id, Row)};
        _ -> tmux_model:get(id, Row)
    end.
