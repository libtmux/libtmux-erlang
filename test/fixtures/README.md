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

Other ports can consume the same file. Only the Erlang consumer is currently
verified here; these fixtures do not establish cross-port conformance.

[regex-v1.json](regex-v1.json) checks the restricted ASCII portable_v1 regex
dialect against PCRE2, JavaScript and Rust regex engines. It contains explicit
edge cases and deterministic generated expressions whose expected results use
an independent position-set oracle. See the
[conformance runner](../../tools/regex-conformance/README.md) for the grammar,
resource limits, tool setup and the scope of this proof.
