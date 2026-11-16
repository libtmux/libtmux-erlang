# Regex fixture scripts

Two scripts keep `test/fixtures/regex-v1.json`, the portable regex fixture,
honest.

`generate_fixture.erl` writes the fixture: explicit edge cases and 100
generated expressions whose expected results come from a position-set matching
oracle. Its random draws come from a Mersenne Twister (MT19937) seeded from a
fixed integer, so the file is stable byte for byte. `--check` fails when the committed file differs. The
mid loop runs the check.

`check_regex.erl` renders every pattern for PCRE2, JavaScript and Rust, runs
the JavaScript and Rust reference engines over every case and requires their
answers to match the fixture. It writes `_build/checks/regex.json`. The `regex`
job in `.github/workflows/ci.yml` runs it. Build the Rust binary first as
described in the [conformance guide](../../tools/regex-conformance/README.md).

Compile the library, then run from the repository root:

```console
$ escript scripts/regex/generate_fixture.erl --check
```

```console
$ escript scripts/regex/check_regex.erl
```

Run the tests with:

```console
$ rebar3 eunit --module=generate_fixture_tests,check_regex_tests
```
