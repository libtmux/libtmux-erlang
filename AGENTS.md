# Agent instructions

This repository implements the Erlang libtmux port. The active implementation
epic governs scope; architecture approval does not establish package or
runtime qualification. Check current code and evidence before claiming support.

## Guides

- Setup, checks, and contributions:
  [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
- Documentation, comments, commits, and review text:
  [.github/WRITING.md](.github/WRITING.md).

Each guide owns its subject. `CLAUDE.md` is a relative symlink to this file.

## Changes

- Check the branch and working tree. Preserve unrelated changes and symlinks.
- Make the smallest coherent change that solves the verified problem.
- Reuse existing files, helpers, APIs, and tests before adding new ones.
- Add a file for a distinct responsibility or independent reuse. Avoid
  single-use wrappers and one-line re-exports.
- Add tests for critical behavior. A regression test must fail for the
  intended reason before its passing result can establish a fix.
- Prefer `rg`, `ag`, or `fd` for searches and `jq` for JSON.
- Follow native Erlang conventions. Sibling ports are behavioral references.
- Target the latest stable Erlang/OTP release only for now. Verify upstream
  releases when updating [.tool-versions](.tool-versions).
- Answer questions before editing. When responding to feedback, state
  agreement or disagreement and explain the reason before making changes.
- Report checks as `PASS`, `FAIL`, `PARTIAL`, or `UNVERIFIED`, with their
  scope and whole-command duration. Verify claims against this repository;
  a sibling port's results do not establish Erlang support.
- Commit, push, publish, or change remote settings only within the user's
  current authorization.

## Shared resources

Future tmux checks must use unique, owned sockets and temporary directories.
Clear inherited `TMUX` and `TMUX_PANE`. Never use or stop the default server.
Clean up only resources owned by the run and verify that owned processes
exit on success, failure, and cancellation.
