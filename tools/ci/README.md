# CI source builds

The workflow uses exact OTP and Rebar3 versions from .tool-versions. Its nine
Ubuntu 24.04 cells cover tmux 3.3, 3.3a, 3.4, 3.5a, 3.6b, 3.7c and 3.8 on
x86_64, plus 3.3 and 3.8 on arm64. These cells run the currently implemented
core checks; the remaining suite features retain their implementation gates.

[tmux-sources.json](tmux-sources.json) pins official release archives by SHA256
and records the corresponding peeled source commits. build_tmux.py derives an
exact cache key from that pin, runner image/version, architecture, compiler,
native dependency versions, flags and recipe bytes. It checks the installed
binary's hash, version and loader before reuse. An invalid cache rebuilds in
the owned prefix. The workflow saves a new cache only after the owned fixture,
integration and archive-consumer gates pass. It uses no broad restore keys.

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
