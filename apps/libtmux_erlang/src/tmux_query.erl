-module(tmux_query).
-moduledoc """
Build and execute explicit queries over the tmux graph.

Use `fetch/1` to execute a query. Constructors,
`where/2`, `limit/2`, `pushdown/2` and
`explain/1` perform no tmux I/O. Criteria are validated when added,
and repeated conditions conjoin. Fetching returns an ordered `m:tmux_select`
selection backed by a complete `m:tmux_snapshot` graph. By default the full
captured view is filtered locally. Enable native candidate exclusion with
`pushdown/2`: it can add a scan without reducing complete-graph hydration. The
candidate is a necessary condition; the full filter still runs before the limit.

Captures span commands and are not atomic. Candidate IDs excluded at one
observation cannot be recovered by later local filtering. Disabling
`pushdown/2` evaluates the complete captured view without an
earlier candidate exclusion. Numeric candidate fields come from the restricted
scalar codec and must agree with the capture's scalar observations. Text and
relationships remain local.

```erlang
1> Q0 = tmux_query:panes(unopened), ok.
ok
2> Q = tmux_query:where(#{width => #{gte => 120}}, Q0), ok.
ok
3> maps:get(format, maps:get(candidate, tmux_query:explain(Q))).
<<"1">>
4> Pushed = tmux_query:pushdown(true, Q), ok.
ok
5> maps:get(format, maps:get(candidate, tmux_query:explain(Pushed))).
<<"#{e|>=|:#{pane_width},120}">>
```
""".
-export([panes/1, windows/1, window_links/1, sessions/1, where/2, limit/2,
         pushdown/2, explain/1, fetch/1, fetch/2]).
-export_type([t/0]).
-record(query, {server :: tmux_server:t(), entity :: tmux_schema:entity(),
                filter = none :: none | tmux_filter:t(),
                limit = infinity :: infinity | 0..65536,
                pushdown = false :: boolean()}).
-export_type([fetch_options/0, plan/0, candidate/0, local_reason/0,
              source_command/0, command_plan/0]).
-doc "Capture bounds plus an explicitly requested single inconsistent-capture retry; default retry is zero.".
-type fetch_options() :: #{deadline_ms => 1..600000, max_rows => 1..65536,
    max_bytes => 1..67108864, consistency => observed | atomic, retry => 0 | 1}.
-doc """
Why part of a predicate stays local. field and relation contain stable schema
IDs, not Erlang names or tmux formats. An unsupported leaf may broaden the
native condition; it never removes the full local predicate.
""".
-type local_reason() :: #{reason := disabled | format_limit | inexact_negation |
        unqualified_scalar_codec | complete_relationship_required,
    field => binary(), relation => binary(), operator => tmux_schema:operator()}.
-doc """
Native necessary condition. format is a rendered tmux expression; exact means
the translation covers the whole predicate for one observed state. A true
fallback can admit every row. numeric_range describes qualified integer
conversion, and is omitted for disabled/oversized fallback plans.
""".
-type candidate() :: #{format := binary(), exact := boolean(),
    local_only := [local_reason()], numeric_range => {0, 9007199254740991}}.
-doc """
Diagnostic command template, not executable argv. Scan templates carry kind
and args; text/byte hydration uses target = observed_id, resolved only while
capturing. Its format quotes the field to preserve literal backslashes and
control bytes across tmux print encodings. codec states how returned data is
framed. This value grants no atomicity or persistent-connection guarantee.
""".
-type source_command() ::
    #{entity := tmux_schema:entity(), command := binary(), format := binary(),
      transport := one_shot, codec := scalar_spine,
      kind := tmux_schema:entity(), args := [binary()], filter => binary()} |
    #{entity := tmux_schema:entity(), field := atom(), command := binary(),
      format := binary(), transport := one_shot,
      codec := id_prefixed_quoted_field, target := observed_id}.
-doc """
Capture phases: initial identity/scalar scans, optional candidate scans,
complete text/byte hydration and final identity/scalar scans. An empty server
skips window/pane scans. Execution still validates capture bounds and can
fail.
""".
-type command_plan() :: #{initial_spine := [source_command()],
    candidate := [source_command()], hydration := [source_command()],
    final_spine := [source_command()], empty_server := skip_window_and_pane_scans}.
-doc """
Pure explanation of a query. pushdown reports whether candidate exclusion is
enabled (disabled by default). residual is the full portable predicate, required
lists coverage requirements, and limit applies after residual evaluation.
ordering and deduplication name the identity policy, not arbitrary map order.
capabilities describes the planner baseline without probing a live endpoint.

Capture spans commands. Candidate scalar values are checked against the first
scan; text and relationships are later observations. Excluded rows cannot be
recovered after state changes. Even an exact candidate is not an atomic query.
""".
-type plan() :: #{entity := tmux_schema:entity(), pushdown := boolean(), candidate := candidate(),
    residual := tmux_filter:wire_document(), required := [tmux_snapshot:requirement()],
    limit := infinity | 0..65536, commands := command_plan(), hydration := complete_graph,
    ordering := session_index_window | numeric_id,
    deduplication := membership | physical_id,
    capabilities := #{minimum_tmux := {3, 3}, transport := one_shot},
    consistency := observed, atomic := false,
    candidate_scalars := same_row_checked_against_spine,
    text_and_relations := later_observations,
    temporal_limit := excluded_rows_cannot_be_recovered}.

-doc """
An immutable description of future tmux reads. Only fetch executes it.
""".
-opaque t() :: #query{}.

-doc """
Describe a future server-wide physical pane query. Performs no I/O; `fetch/1`
is the execution boundary.
""".
-spec panes(tmux_server:t()) -> t().
panes(Server) -> #query{server = Server, entity = pane}.
-doc """
Describe a future query over unique physical windows. Performs no I/O.
""".
-spec windows(tmux_server:t()) -> t().
windows(Server) -> #query{server = Server, entity = window}.
-doc """
Describe a future query over session-relative window memberships. Repeated
physical windows retain distinct membership identity. Performs no I/O.
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
conditions. Successive calls share the same normalized resource limits as one
flat conjunction. Each relationship quantifier retains its own scope. Returns
a new immutable query; malformed criteria raise bad_filter. Performs no I/O.
""".
-spec where(map() | tmux_filter:t(), t()) -> t().
where(Criteria, #query{entity = Entity, filter = Previous} = Query) ->
    Filter = tmux_filter:new_or_error(Entity, Criteria),
    Combined = case Previous of
        none -> Filter;
        _ ->
            case tmux_filter:conjoin(Previous, Filter) of
                {ok, Result} -> Result;
                {error, Detail} -> error({bad_filter, Detail})
            end
    end,
    Query#query{filter = Combined}.

-doc """
Set a final result limit from 0 through 65536, applied after residual
filtering and identity handling. It is not a candidate-fetch limit. Performs
no I/O; invalid counts raise bad_query_limit.
""".
-spec limit(0..65536, t()) -> t().
limit(Count, Query) when is_integer(Count, 0, 65536) -> Query#query{limit = Count};
limit(Count, _) -> error({bad_query_limit, Count}).

-doc """
Enable or disable native candidate exclusion, returning a new query. The
default is disabled: evaluate the complete captured view locally. Enabling it
can add a candidate scan without reducing hydration; neither mode promises an
atomic graph. Performs no I/O.
""".
-spec pushdown(boolean(), t()) -> t().
pushdown(Enabled, Query) when is_boolean(Enabled) -> Query#query{pushdown = Enabled}.

-doc """
Inspect command templates, necessary candidate conditions, full residual,
hydration, required fields, ordering and temporal assumptions. Performs no I/O
and does not contact the endpoint to claim dynamic capabilities.
""".
-spec explain(t()) -> plan().
explain(#query{entity = Entity, limit = Limit, pushdown = Enabled} = Query) ->
    Filter = filter(Query),
    Candidate = case Enabled of
        true -> tmux_query_plan:compile(Filter);
        false -> #{format => <<"1">>, exact => false, local_only => [#{reason => disabled}]}
    end,
    #{entity => Entity, pushdown => Enabled, candidate => Candidate, residual => tmux_filter:to_wire(Filter),
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
Execute with default capture bounds and no retry. Returns an ordered selection
whose complete graph remains locally readable. See `fetch/2` for resource
limits, requested retries and operational errors.
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
