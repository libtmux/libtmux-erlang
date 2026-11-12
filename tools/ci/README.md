# CI source builds

The workflow uses the latest stable OTP release, pinned with Rebar3 in
.tool-versions. Four Ubuntu 24.04 cells cross tmux 3.3a and 3.8 with x86_64 and
arm64. These are the oldest supported and newest stable tmux releases.
Support includes the releases between them. Each cell runs the current
core checks and clean source-package installation; remaining suite features
retain their implementation gates.

[tmux-sources.json](tmux-sources.json) pins official release archives by SHA256
and records the corresponding peeled source commits. Historical pins remain
available for reproduction; they do not expand the CI matrix.
build_tmux.py derives an exact cache key from that pin, runner image/version,
architecture, compiler, native dependency versions, flags and recipe bytes.
It checks the installed binary's hash, version and loader before reuse. An
invalid cache rebuilds in the owned prefix. The workflow saves a new cache
only after the owned fixture, integration and archive-consumer gates pass.
It uses no broad restore keys.

This follows the [Go port's cache identity and validation approach](https://github.com/libtmux/libtmux-go/blob/d8ea6f77ede9f75e96af78719c8c1707fc47bdfb/.github/scripts/tmux_build.py).
The [setup-beam documentation](https://github.com/erlef/setup-beam/blob/54075bcc5e249e4758d363f27d099f55d843f124/README.md)
recommends exact versions with strict matching. Actions are pinned to complete
commit IDs, checkout credentials are not persisted, and the workflow token
has contents read permission. Failed matrix cells retain their logs and
receipts; fail-fast is disabled.

PropEr 1.5.0 and rebar3_proper 0.12.1 are isolated in the property profile.
The core application has no runtime dependency on them. Prepare that profile
outside timed inner/mid checks:

```console
$ mise exec -- rebar3 as property,test get-deps
```

Run the generated properties separately:

```console
$ time mise exec -- rebar3 as property proper \
    --dir property \
    --numtests 300
```

EUnit owns the small deterministic checks. Common Test owns real tmux
lifecycle, cleanup, framing and installed-consumer cases, including native
ct_doctest examples. The initial generated properties check portable-filter
round trips, Boolean composition and arbitrary byte operands. Generated
state-machine sequences remain part of the lifecycle qualification work.

## Documentation publication

[docs.yml](../../.github/workflows/docs.yml) builds selected source through
the shared libtmux/docs producer. Production publication requires a manual
dispatch with `publish` enabled; its default is false. Ready pull requests
from this repository may publish previews unless labelled `no-preview`.
Draft and fork pull requests build without publishing.

Publication and [close cleanup](../../.github/workflows/docs-preview-cleanup.yml)
share one queue. Cleanup reads the current PR state before assuming its role,
so rerunning a close event for a reopened PR leaves its preview intact. It
deletes only that PR's `en/erlang/pr-N/` prefix and never checks out PR code.
The mid loop exercises these shell steps with local GitHub and AWS stand-ins.

Keep the producer and deploy workflows pinned to the same complete shared
commit. Qualify the selected source build before enabling publication; a
workflow or IAM role alone does not establish a deployed documentation tree.
