# Publish libtmux_erlang to Hex

See [Hex](https://hex.pm/packages/libtmux_erlang) for published core versions.
Describe pending changes under Unreleased in the [root changelog](../CHANGELOG.md)
and the [core changelog](../apps/libtmux_erlang/CHANGELOG.md).

The [Hex release workflow](workflows/release.yml) submits the core package and
its native API documentation when a matching `vVERSION` tag is pushed. PRs and
manual dispatch without inputs build a candidate. Manual dispatch also supports
public release verification, an Ubuntu tmux check and a workload identity check.
Website publication uses [docs.yml](workflows/docs.yml).

## Publishing setup

A full package owner with two-factor authentication configures the identity
below. The GitHub environment named **hexpm** allows deployment tags matching
`v*` and the `master` branch for identity checks. Restrict release-tag creation
through the repository's rulesets.

The first release used a temporary `HEX_API_KEY`; current jobs never receive
that secret. A new public package still needs one authenticated first
publication, because [workload identity requires an existing package](https://hex.pm/docs/workload-identity).

## Configure OIDC after bootstrap

As a full package owner with 2FA, open the package's Workload identities tab
and add this GitHub identity:

- Repository owner: `libtmux`
- Repository: `libtmux-erlang`
- Workflow: `release.yml`
- Environment: `hexpm`

The publisher job has `id-token: write` and does not receive `HEX_API_KEY`.
Pinned `rebar3_hex` 7.5.0 exchanges the GitHub token automatically. No AWS
identity or website publisher credential is involved.

Verify the saved identity from master before removing the bootstrap key:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-erlang \
    --ref master \
    --field verify_identity=true
```

The check uses the pinned publisher's Hex client to exchange a token scoped to
`libtmux_erlang`. A read-only API request must deny its read permission
(HTTP 403), then reject authentication after revocation (HTTP 401).
The check prints no token and uploads no package or documentation. A passing
run confirms authentication and revocation;
the next release establishes publishing through OIDC. Staged publishing still
requires approval when enabled on Hex.

After that check passes, revoke the bootstrap key at Hex and remove its
environment secret.

```console
$ gh secret delete HEX_API_KEY \
    --repo libtmux/libtmux-erlang \
    --env hexpm
```

## Cut a release tag

For later versions, update `vsn` in
[`libtmux_erlang.app.src`](../apps/libtmux_erlang/src/libtmux_erlang.app.src)
and describe changes in both the root and core changelogs. Keep unreleased
changes distinct from published releases. Merge and check the release commit
before tagging. Never move a published tag to repair a release.

Start with a clean, current master checkout.

```console
$ git switch master
```

```console
$ git pull --ff-only origin master
```

Validate the candidate metadata and clean source tree.

```console
$ escript scripts/release/check_release.erl
```

Enter the new release tag, including its `v` prefix. It must match the updated
application version. Create its annotated tag locally.

```console
$ read -r LIBTMUX_RELEASE_TAG
```

```console
$ git tag --annotate "$LIBTMUX_RELEASE_TAG" \
    --message "Release ${LIBTMUX_RELEASE_TAG#v}"
```

Check that the tag resolves to this commit and matches the package version.

```console
$ escript scripts/release/check_release.erl \
    --tag "$LIBTMUX_RELEASE_TAG"
```

The next command starts the publishing workflow and is the release action.

```console
$ git push origin "$LIBTMUX_RELEASE_TAG"
```

The workflow runs the existing native suite on OTP 29.1.2, tmux 3.3a and 3.8,
and both qualified Linux architectures, plus helper sanitizers, properties,
regex conformance and documentation checks. The publish job verifies that
its exact source tarball matches the one installed by native CI. It checks
reproducibility again before submitting the package and docs together. The job
ends when Hex accepts the upload. When Hex stages artifacts for approval, the
publisher logs the approval link and expiry.

## Verify after Hex approval

Approve any staged artifacts on Hex. Copy the numeric run ID from the tag
push's **Hex release** URL and enter it when prompted.

```console
$ read -r LIBTMUX_HEX_SUBMISSION_RUN
```

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-erlang \
    --ref master \
    --field verify_publication_run="$LIBTMUX_HEX_SUBMISSION_RUN"
```

The verifier checks out the exact tag and reads its candidate tarball and
native source-package receipt from the submission run. These artifacts are
retained for 14 days. The public tarball must match the qualified bytes and
the versioned HexDocs README must return HTTP 200. The verifier then builds
the packaged C helper in an empty Rebar3 project and runs the installed
quickstart on source-built tmux 3.8. Find its receipt under
`hex-public-install`. After verification, date both changelog entries.

If an artifact is still staged or propagating, check its state and run
verification again when it is public. Retry a failed submission on the same
tag. If the exact package is already public, the retry submits its docs.
Different package bytes fail before upload.

## Check Ubuntu's packaged tmux

The Ubuntu check records the distro package version and runs the pane-exit
example on that binary. Dispatch it independently of release verification.

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-erlang \
    --ref master \
    --field check_ubuntu_tmux=true
```

## Check the workflow without releasing

Every matching PR and manual dispatch without inputs builds a candidate
and exercises combined submission with `--dry-run`. Only a tag push can
submit a release.

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-erlang \
    --ref master
```

The native source-package check remains available without any Hex account:
it builds the real tarball and installs it through a signed local registry.

```console
$ escript scripts/package/check_source_package.erl --prepare
```

```console
$ escript scripts/package/check_source_package.erl
```
