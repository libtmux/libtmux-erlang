# Portable regex conformance

The filter API accepts this object under a text field's `regex` operator:

```erlang
#{pattern => <<"^(vim|nvim)$">>, dialect => portable_v1, flags => []}
```

Wire objects use string keys and `"portable_v1"`. Flags default to the empty
list; other flags and unknown keys fail validation. The normalized filter
retains data only. Preparation compiles each pattern once for the captured
context, including filters whose rows later short-circuit.

## Grammar and limits

Patterns and subjects contain ASCII bytes. Matching is case-sensitive and
searches anywhere unless anchored. `^` and `$` mean absolute subject start
and end, including subjects ending in a newline. Dot matches every ASCII
byte except LF; CR matches. Classes support ranges and ASCII complement.
Escape a literal closing bracket or nested opening bracket in a class.

Supported forms are literals, `.`, classes, ordinary groups, alternation,
anchors, and `{m}` or `{m,n}` repetition. Counts contain one or two decimal
digits and range from 0 to 64. Empty groups and alternatives are allowed.
Anchors cannot be repeated directly. Escapes support metacharacters,
`\n`, `\r`, `\t`, `\f`, `\v`, and ASCII `\xHH` bytes.

Backreferences, lookaround, special groups, unbounded repetition, lazy or
possessive modifiers, engine directives and Unicode/POSIX classes fail
validation. Literal metacharacters require escaping.

Patterns are limited to 1,024 bytes and 32 nested groups. The grammar cost is
at most 8,192: each node costs one, sequence/alternative nodes add their child
costs, and repetitions add their maximum count times their child cost.
Rendered PCRE2 source is limited to 65,536 bytes. Subjects are limited to
1 MiB. Non-ASCII subjects return `unsupported_regex_subject`.

PCRE2 runs with `report_errors`, match limit 100,000 and depth limit 1,000.
Resource exhaustion returns `regex_resource_limit`, never a false match.
These are engine resource limits, not a wall-clock deadline. Other engines
can reach different resource limits even when accepted matches agree.
Use a local Boolean callback for regex semantics outside this dialect.

## Running the reference engines

The core depends only on OTP. Node and the locked Rust `regex` crate are
test-only reference backends. This proof checks the grammar's canonical
renderers and matching engines. It does not qualify other ports' public
filter APIs or tmux regex pushdown.

Prepare the Rust test binary before timing the checks:

```console
$ cargo build \
    --manifest-path tools/regex-conformance/Cargo.toml \
    --locked \
    --target-dir _build/regex-conformance
```

Compile the Erlang application:

```console
$ mise exec -- rebar3 compile
```

Run all reference cases with Node and Rust available on PATH:

```console
$ time mise exec -- python3 tools/check_regex.py
```

The receipt in `_build/checks/regex.json` records engine versions, the fixture
digest and whole-run time. CI pins the reference runtimes in its separate
regex job. The normal mid loop checks fixture drift without these runtimes.

Regenerate the fixture after an intentional grammar or oracle change:

```console
$ python3 tools/regex-conformance/generate_fixture.py
```
