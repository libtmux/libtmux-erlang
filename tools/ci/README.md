# CI source builds

The workflow uses the latest stable OTP release, pinned with Rebar3 in
.tool-versions. Four Ubuntu 24.04 cells cross tmux 3.3a and 3.8 with x86_64 and
arm64. These are the oldest supported and newest stable tmux releases.
Support includes the releases between them. Each cell runs the current
core checks and clean source-package installation; remaining suite features
retain their implementation gates.

The workflow builds tmux with the shared
[build-tmux action](https://github.com/libtmux/.github/blob/30f81842b1e639ea4e25f93f1f2543504178e228/actions/build-tmux/README.md)
and installs packages with the shared
[apt-get action](https://github.com/libtmux/.github/blob/30f81842b1e639ea4e25f93f1f2543504178e228/actions/apt-get/README.md).
The build-tmux action pins each release archive by SHA256, keys its cache on
the runner image, compiler and recipe, and validates a restored build before
use. It saves a cache entry only after that validation. Both actions are
pinned to a full commit.

The [setup-beam documentation](https://github.com/erlef/setup-beam/blob/54075bcc5e249e4758d363f27d099f55d843f124/README.md)
recommends exact versions with strict matching. Actions are pinned to complete
commit IDs, checkout credentials are not persisted, and the workflow token
has contents read permission. Failed matrix cells retain their logs and
receipts; fail-fast is disabled.

PropEr 1.5.0 and rebar3_proper 0.12.1 are isolated in the property profile.
The core application has no runtime dependency on them. Prepare that profile
outside timed inner/mid checks:

```console
$ rebar3 as property,test get-deps
```

Run the generated properties separately:

```console
$ time rebar3 as property proper \
    --dir property \
    --numtests 300
```

EUnit owns the small deterministic checks. Common Test owns real tmux
lifecycle, cleanup, framing and installed-consumer cases, including native
ct_doctest examples. The initial generated properties check portable-filter
round trips, Boolean composition and arbitrary byte operands. Generated
state-machine sequences remain part of the lifecycle qualification work.

## Documentation previews

Pull requests build documentation through the same pinned producer as manual
builds. Production publication requires an explicit `publish: true` dispatch.
Preview publication stays disabled: the approved shared publisher rechecks the
current head, tested merge and open state, but still needs to recheck draft
status and the `no-preview` label immediately before uploading.

The caller also excludes draft, fork and `no-preview` pull requests from
publication. Publication and cleanup share one queue so a cleanup cannot race
a preview upload. The default-branch close workflow checks current state again
before deletion and removes only that pull request's `en/erlang/pr-N/` prefix.
The [cleanup script](../../scripts/docs/README.md#remove-a-closed-preview) runs
without checking out pull request content.
