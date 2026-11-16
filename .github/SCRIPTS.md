# Scripts

This policy covers the support scripts in this repository: files under
`scripts/`, CI helpers, generators and checkers. It applies the libtmux
decision in [libtmux/docs#323](https://github.com/libtmux/docs/pull/323).

## Keep a script only for a current use

A script stays when this project runs it today: a CI job, a release step, a
code generator, a documentation check, or a maintainer task named in
[CONTRIBUTING.md](CONTRIBUTING.md).

- Parity with Python libtmux or tmuxp is not a use. Delete comparison
  harnesses, oracles, ledgers and generated fixtures, and the CI steps that
  install them.
- A shell step that creates, prepares or stops tmux for an example or test
  means the library lacks an operation. File an issue for the operation and
  remove the step when it lands.
- Delete scripts nothing calls.
- Tooling several ports share lives once, as a shared workflow or action, not
  as a vendored copy.

## Language

Scripts are Erlang, run with `escript`, the same interpreter CI uses for the
library. Do not add shell or Python script files.

## Layout and checks

- A script with tests lives in `scripts/<name>/`, with a `README.md` (what it
  does, who runs it, how) and `tests/`. A short single-purpose script may be
  one file with a usage header.
- Scripts pass the same formatter, linter, type checker and test runner as the
  library, in CI.
- Use current language and tool idioms; no shims below the project's floor.
- Before a new or rewritten script merges, a reviewer who did not write it
  checks it against [WRITING.md](WRITING.md) and
  [no-ai-slop](https://github.com/petergyang/no-ai-slop).

## What stays

- GitHub Actions `run:` lines that call one command.
- A capability Erlang lacks comes from a test-only Erlang dependency, not from
  a second language.
- Test data that is not a comparison, such as workspace files a loader reads.

## Exceptions

- `tools/regex-conformance/` is a Rust program and a JavaScript module. They
  run the Rust `regex` crate and Node's `RegExp` over the portable-regex
  fixture so `scripts/regex/check_regex.erl` can compare their answers with
  the Erlang matcher's. The comparison needs engines independent of the code it
  checks, and Erlang cannot host them. Only the `regex` job in
  [ci.yml](workflows/ci.yml) builds and runs them; the core and the mid loop
  need neither. The toolchain pins are `RUSTUP_TOOLCHAIN` and the
  `setup-node` version in that job.
