# Publish libtmux_erlang to Hex

The published core is **0.0.1**. This is an early development release:
the supported one-shot APIs work, while control command submission and
streaming remain unfinished. Describe later changes under Unreleased in the
[changelogs](../CHANGELOG.md) until their publication.

The [Hex release workflow](workflows/release.yml) publishes the core package
and its native API documentation when a matching `vVERSION` tag is pushed.
PRs and normal manual dispatch build a candidate without publishing. A manual
identity check exchanges and revokes a scoped token without uploading. Website
publication through [docs.yml](workflows/docs.yml) is a separate operation.

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
`libtmux_erlang`. It makes one read-only package request, revokes the token,
and requires Hex to reject it afterward. It prints no token and uploads no
package or documentation. A passing run confirms authentication and revocation;
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
$ mise exec -- escript scripts/release/check_release.erl
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
$ mise exec -- escript scripts/release/check_release.erl \
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
reproducibility again before calling the native publisher.

## Confirm delivery or retry

Inspect the **Hex release** run, the [public package](https://hex.pm/packages/libtmux_erlang)
and its HexDocs page for the selected release version. The final job installs
that version from public Hex in an empty consumer with an empty build cache,
compiles the helper from source, and executes the existing reader examples
and native-record consumers. Its receipt is the `hex-public-install` artifact.

A staged upload, a pushed tag, or a green dry run does not establish delivery.
After successful publication, date the release entries in both changelogs.

If publication or propagation is incomplete, inspect the public package and
pending approval first. Rerun the same tag's failed jobs after resolving the
cause. An identical public package is accepted; different bytes fail before
upload. If the package itself needs a correction, prepare a new version.

## Check the workflow without releasing

Every matching PR runs the real publisher with `--dry-run`, without a Hex
environment, key or OIDC permission. After this workflow reaches the default
branch, a manual dispatch also builds only; it has no publish input.

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-erlang \
    --ref master
```

The native source-package check remains available without any Hex account:
it builds the real tarball and installs it through a signed local registry.

```console
$ mise exec -- escript scripts/package/check_source_package.erl --prepare
```

```console
$ mise exec -- escript scripts/package/check_source_package.erl
```
