# Portable filter fixtures

[filters-v1.json](filters-v1.json) supplies a captured graph, versioned wire
filters, expected ordered identities, and validation failures with exact paths.
Graph field names use the generated wire schema. JSON null means known
absence; a single-key base64 object represents arbitrary bytes. Missing fields
remain unloaded. Each window link retains its session-relative index.

The cases cover correlated and independent quantifiers, empty relationships,
physical versus membership counts, nullable comparisons, integer normalization,
Unicode, byte values and Boolean identities. The Erlang runner also checks
repeatability, normalization idempotence and wire round trips across composed
conditions. It runs in the normal EUnit suite without tmux I/O.

The optional [cross-port comparison](../../tools/filter-conformance/README.md)
also exercises the unchanged wire documents through Elixir v0.1.1. It finds
wire, field-domain and diagnostic differences, so full interoperability
remains FAIL. The comparison records its narrower projected-graph matches
separately; they do not establish cross-port conformance.

The test-only [graph properties](../../property/prop_tmux_graph.erl) generate
complete captured graphs with empty relations, shared physical windows and
repeated memberships. An independent plain-map interpreter checks recursive
Boolean and relationship criteria, wire round trips, composition, quantifier
correlation and physical versus membership counts. The bounded generated
grammar supplements these fixed cases; it does not cover every operator or
establish native tmux pushdown equivalence.

The [source-query suite](../tmux_query_SUITE.erl) checks candidate implication
and declared exactness through tmux's own format evaluator on an owned,
linked-window graph. Seeded recursive pane criteria combine native scalars with
local text, nullable fields and relationship conditions. The fixture checks
used values and memberships before and after evaluation. Batch framing here
is limited to canonical pane IDs and generated `0`/`1` results; captures
retain interval semantics.

[regex-v1.json](regex-v1.json) checks the restricted ASCII portable_v1 regex
dialect against PCRE2, JavaScript and Rust regex engines. It contains explicit
edge cases and deterministic generated expressions whose expected results use
an independent position-set oracle. See the
[conformance runner](../../tools/regex-conformance/README.md) for the grammar,
resource limits, tool setup and the scope of this proof.
