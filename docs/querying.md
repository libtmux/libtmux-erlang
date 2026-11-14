# Capture locally; fetch explicitly

- A **snapshot** is observed data.
- A **selection** is ordered rows plus their captured context.
- A **filter** is portable predicate data.
- A **query** describes a future tmux observation. Only `fetch` runs it.

The [README program](../examples/readme_demo.erl) shows both paths on real
tmux: it keeps a captured name after renaming the live window, then runs a
fresh query. Snapshot and selection reads stay local, even after close.

## Criteria

- Criteria are atom-keyed maps with binary text. A bare scalar means equality;
  fields and operators in one map conjoin.
- Boolean branches are the quoted atoms `'and'`, `'or'` and `'not'`. Empty
  AND is true; empty OR is false.
- Callbacks go to `tmux_select:filter/2`, must return Booleans, and propagate
  their failures.
- To-many relations take `some`, `every`, `none` and `count`. To-one relations
  take `is` and `is_not`.
- One `some` with two conditions needs the same related row. Two separate
  `some` conditions can match different rows.
- On an empty to-many relation, `some` is false and `every` and `none` are
  true.
- Unknown fields, invalid operations, type mismatches and incomplete coverage
  fail before any row is read. An unloaded relationship is never an empty one.
- `from_list` keeps order and duplicates but cannot infer relationships.

[Fields and operators](fields.md) come from the runtime validator.

## Cardinality

| Call | Result |
| --- | --- |
| `first` | `{ok, Row}` or `none`; more matches are allowed |
| `one` | `{ok, Row}`, `{error, no_match}`, or a multiple-match error |
| `one_or_none` | `{ok, Row}`, `{ok, none}`, or a multiple-match error |
| `one_or_error` | Row directly; raises on zero or multiple matches |
| `size` | Cached materialized size |
| `count` | Current size, or exact count after supplied criteria |

- Criteria come first and the selection last.
- An ambiguity check stops at the second match, after validation.
- `to_list/1` and `fold/3` hand rows to list code. A selection is not a list.

## Portable input

- `tmux_filter:decode_json/1` rejects duplicate keys, trailing input and
  excess size or depth.
- `from_wire/2` maps wire names explicitly. It never creates atoms from
  payload keys.
- `to_wire/1` exports filter data, not closures or record internals.
- Integers normalize only inside the shared JSON integer range. Text is
  case-sensitive.

Run this local recipe. It uses captured rows and needs no tmux server:

```console
$ mise exec -- escript tools/run_examples.escript filter
```

<!-- example: examples/filter_demo.erl -->

```erlang
-module(filter_demo).
-moduledoc "Validate portable JSON and filter captured rows without tmux I/O.".
-export([run/0]).

-spec run() -> map().
run() ->
    {ok, Editor} = tmux_model:pane(#{id => <<"%1">>, active => true,
        width => 120, current_command => <<"nvim">>}),
    {ok, Shell} = tmux_model:pane(#{id => <<"%2">>, active => false,
        width => 80, current_command => <<"bash">>}),
    Panes = tmux_select:from_list(pane, [Editor, Shell]),
    Criteria = #{active => true, 'or' => [
        #{current_command => #{in => [<<"nvim">>, <<"vim">>]}},
        #{width => #{gte => 160}}
    ]},
    {ok, Filter} = tmux_filter:new(pane, Criteria),
    Encoded = iolist_to_binary(json:encode(tmux_filter:to_wire(Filter))),
    {ok, Document} = tmux_filter:decode_json(Encoded),
    {ok, RoundTrip} = tmux_filter:from_wire(pane, Document),
    {ok, Editor} = tmux_select:one(RoundTrip, Panes),
    [Editor] = tmux_select:to_list(tmux_select:where(Filter, Panes)),
    {error, #{code := duplicate_key}} = tmux_filter:decode_json(
        <<"{\"version\":1,\"version\":2}">>),
    Invalid = #{active => #{contains => <<"yes">>}},
    try tmux_select:where(Invalid, Panes) of
        _ -> error(expected_validation_error)
    catch
        error:{bad_filter, #{code := unsupported_operator} = Detail}:Stack ->
            [active, contains] = maps:get(path, Detail),
            Reason = {bad_filter, Detail},
            Message = erl_error:format_exception(error, Reason, Stack),
            Text = unicode:characters_to_binary(Message),
            {_, _} = binary:match(Text, <<"Allowed:">>)
    end,
    #{matched_ids => [tmux_model:get(id, Editor)],
      wire_round_trip => true, duplicate_keys_rejected => true}.
```

It selects `%1`, round-trips the JSON and rejects the duplicate key.

The [restricted ASCII regex guide](../tools/regex-conformance/README.md) gives
its grammar and limits. Non-ASCII subjects and exhausted match limits are
errors, not nonmatches. Local callbacks provide other regex semantics.

## Source plans

- A query filters the whole captured graph locally by default.
- `tmux_query:pushdown(true, Query)` asks tmux to exclude candidates first. It
  can add a scan and an earlier observation; hydration is unchanged.
  `pushdown(false, Query)` turns it off.
- `tmux_query:explain/1` does no I/O. It reports the `pushdown` choice, command
  templates, candidate conditions, the full residual filter, hydration, fields,
  ordering and identity policy.
- ID, Boolean and qualified unsigned numeric conditions reach tmux's `-f`.
  Text, nullable fields and relations stay local. Numbers compare with tmux
  arithmetic, not string order.
- A candidate can admit extra rows but never excludes a match. Unsupported
  leaves become true. AND and OR compose conservatively; NOT translates only
  exact children.

### Hydration

- Hydration defaults to one framed list scan per nonempty entity collection.
  Each field is expanded once and escaped, so paths with tabs, newlines and
  non-UTF-8 bytes survive.
- An identity preflight adds one tmux client per command. Linked memberships
  add bytes, not rows.
- Each command is bounded to 1 MiB of stdout. If an entity exceeds that, pass
  `hydration => isolated` in the snapshot or fetch options to read one field
  per physical row. The total bound and deadline still apply.
- The commands metadata describes default templates under `hydration` and
  isolated reads under `isolated_hydration`. Snapshot metadata records the
  strategy used and the actual calls.

More: [ADR 0002](adr-0002-batched-hydration.md) has the framing and
measurements.

### Fetch

- Fetch keeps the complete captured graph, checks candidate scalars, evaluates
  the full local filter, and only then applies limits.
- Physical entities deduplicate by ID. Window links keep membership identity.
- Capture options bound rows, output and time. `retry => 1` allows one retry
  of an inconsistent capture within the original deadline. The default is none.
- Captures span several commands and are not atomic. Local re-evaluation cannot
  recover rows excluded before their state changed.
- This one-shot path offers no atomic consistency or same-connection identity.
