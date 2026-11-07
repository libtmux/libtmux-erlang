# Contributing

This repository is a stub for the Erlang libtmux port. It contains repository
settings and contributor instructions. Package manifests, source code, tests,
and CI belong to later implementation work.

[AGENTS.md](../AGENTS.md) governs scope and change discipline.
[WRITING.md](WRITING.md) governs prose and commit messages.

## Setup

Use mise to install the exact development versions in
[.tool-versions](../.tool-versions). Initial development targets only the
latest stable Erlang/OTP release. Check the
[official downloads](https://www.erlang.org/downloads) when updating OTP,
then update the exact pin. Older OTP compatibility is outside the current
scope. Install tools before timing checks:

```console
$ mise install
```

Check the selected versions:

```console
$ mise current
```

Verify that the pinned build tool runs on the selected Erlang runtime:

```console
$ mise exec -- rebar3 version
```

tmux is not needed to check this stub. No library compatibility or
installation claim is established by selecting a development toolchain.

## Current checks

Validate the repository settings after editing them:

```console
$ time jq empty .github/repository.json
```

Before handoff, check changed files for whitespace errors:

```console
$ time git diff --check
```

Check staged files before committing:

```console
$ time git diff --cached --check
```

Git does not include untracked files in those checks; inspect newly created
files before staging them. Verify relative Markdown links, the
`CLAUDE.md -> AGENTS.md` symlink, and the settings on both GitHub repositories.
There are no source, build, or test checks yet.

## Check budgets

Time the entire command, including startup and setup. Add tests only for
critical behavior once implementation begins.

| Loop | Budget | Library target | Scope |
| --- | --- | --- | --- |
| Inner | Under 5s | Under 2s | Changed critical behavior or metadata |
| Mid | Under 30s | Under 10s | Unit, lint, and generated-file checks |
| Outer | Under 5 min | Under 60s | Builds, types, integration, and matrices |

The inner and mid loops must not install tools, use the network, build for
production, launch browsers, sleep, or scan broad corpora. Use events or
subscriptions instead of arbitrary waits. Investigate timeouts and waits
over one second as structural defects. Tag slow tests with a one-line reason
and run them in the outer loop. Fix a loop that exceeds its budget before
adding tests; do not raise the budget. Benchmarks are separate: each run
stays under 10 minutes and the full sweep under one hour.

## Review

Keep changes focused. Follow native Erlang conventions and preserve existing
work. A review description explains the resulting behavior and reports
relevant checks, whole-command durations, failures, and skipped checks.
Implementation, release, and compatibility claims need their own evidence.

Future real-tmux checks follow the ownership rules in
[AGENTS.md](../AGENTS.md). Package, CI, documentation export, and release
workflows belong to later implementation work.
