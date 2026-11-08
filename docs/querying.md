# Capture locally; fetch explicitly

A snapshot is observed data. A selection is ordered rows plus their captured
context. A filter is portable predicate data. A query describes a future tmux
observation. Only `fetch` executes a query.

The [README program](../examples/readme_demo.erl) shows both paths against
real tmux. It retains a captured name after renaming the live window, then
executes a fresh source query. All ordinary snapshot and selection reads stay
local, even after the endpoint closes.

## Criteria

Local criteria use atom-keyed maps and binary text. Bare scalars mean equality;
fields and operators in one map conjoin. Boolean branches use quoted `'and'`,
`'or'` and `'not'`. Empty AND is true and empty OR is false. Callbacks belong
to `tmux_select:filter/2` and must return Booleans; callback failures propagate.

Relations use `some/every/none/count` for to-many values and `is/is_not` for
to-one values. One `some` containing two conditions requires the same related
row. Two separate `some` conditions can match different rows. Empty to-many
relations make `some` false and `every` and `none` true.

[Fields and operators](fields.md) come from the runtime validator. Unknown
fields, invalid operations, type mismatches and incomplete coverage fail before
row traversal. An unloaded relationship never becomes an empty relationship.
`from_list` keeps supplied order and duplicates but cannot infer relationships.

## Cardinality

| Call | Result |
| --- | --- |
| `first` | `{ok, Row}` or `none`; more matches are allowed |
| `one` | `{ok, Row}`, `{error, no_match}`, or a multiple-match error |
| `one_or_none` | `{ok, Row}`, `{ok, none}`, or a multiple-match error |
| `one_or_error` | Row directly; raises on zero or multiple matches |
| `size` | Cached materialized size |
| `count` | Current size, or exact count after supplied criteria |

Criteria come first and the selection last. Ambiguity stops after the second
match once validation is complete. `to_list/1` and `fold/3` keep ordinary Erlang
list consumers available; a selection is not a list protocol.

## Portable input

`tmux_filter:decode_json/1` rejects duplicate keys, trailing input and excessive
size/depth. `from_wire/2` maps generated wire names explicitly; it never creates
atoms from payload keys. `to_wire/1` exports filter data, not closures or native
record internals. Integral numbers normalize only within the exact shared JSON
integer range. Text is case-sensitive and is not implicitly normalized.

Run this complete local recipe. It uses captured rows and needs no tmux server:

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

It selects `%1`, preserves the meaning of the JSON round trip, and rejects
ambiguous duplicate keys. The installed-archive check runs the same program.

The [restricted ASCII regex guide](../tools/regex-conformance/README.md) gives
its grammar and resource limits. Non-ASCII subjects and exhausted match limits
are errors, not nonmatches. Local callbacks provide other regex semantics.

## Source plans

Queries filter the complete captured graph locally by default. Enable native
candidate exclusion explicitly with `tmux_query:pushdown(true, Query)`. It can add
a candidate scan and an earlier observation without reducing graph hydration.
`tmux_query:explain/1` reports the choice in its `pushdown` field.

`tmux_query:explain/1` performs no I/O. It reports command templates, native
candidate conditions, full residual data, complete hydration, required fields,
ordering, identity policy and temporal assumptions. ID, Boolean and qualified
unsigned numeric conditions can reach tmux's `-f`. Text, nullable fields and
relations remain local. Numeric comparisons use tmux arithmetic formats,
not string ordering.

A candidate is a necessary condition: it can admit extra rows but must not
exclude a same-state full-filter match. Unsupported leaves become true;
AND and OR compose conservatively; NOT translates only exact children.
Membership trees are balanced to respect tmux's recursion limit.

Fetch retains a complete captured graph, validates any candidate scalar agreement,
evaluates the full local filter, and only then applies limits. Physical entities
deduplicate by ID; window links retain membership identity. `pushdown(false, Q)`
disables earlier candidate exclusion. Capture options bound rows, output and
time; `retry => 1` requests at most one inconsistent-capture retry within the
original capture deadline. The default is no retry.

Captures span several commands and are not atomic. Local re-evaluation cannot
recover rows excluded before their state changed. Atomic consistency and a
same-connection identity promise remain unsupported by this one-shot path.
