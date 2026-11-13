# Publish libtmux_erlang to Hex

The first candidate is **0.0.1**. This is an early development release:
the supported one-shot APIs work, while control command submission and
streaming remain unfinished. Preparing this version does not publish it.
The [changelogs](../CHANGELOG.md) stay Unreleased until publication.

The [Hex release workflow](workflows/release.yml) publishes the core package
and its native API documentation when a matching `vVERSION` tag is pushed.
PRs and manual dispatch build a candidate without publishing. Website
publication through [docs.yml](workflows/docs.yml) is a separate operation.

## First release: maintainer setup

1. [Create a Hex account](https://hex.pm/signup), confirm the email address,
   and enable two-factor authentication in the security dashboard.
2. Create a GitHub environment named **hexpm** in this repository's
   [environment settings](https://github.com/libtmux/libtmux-erlang/settings/environments).
   Select deployment tags matching `v*`. Restrict who may create release tags
   through the repository's rulesets.
3. Choose one bootstrap route below. Hex OIDC can publish subsequent releases,
   but [cannot create a public package or its first release](https://hex.pm/docs/workload-identity).
4. Merge the release PR, inspect its native CI results, and review the exact
   commit that will receive the release tag. Account setup alone does not
   authorize a release.

### Route A: temporary API key in GitHub

Create a short-lived key in the [Hex keys dashboard](https://hex.pm/dashboard/keys)
with **API Read** and **Publish** permissions. Read is needed to wait for
staged approval; Publish bootstraps the first public package. Follow Hex's
[CI key instructions](https://hex.pm/docs/publish#publishing-from-ci).
Store it as the
**hexpm environment secret** named `HEX_API_KEY`. The following command
prompts for the value; keep it out of shell history and repository files.

```console
$ gh secret set HEX_API_KEY \
    --repo libtmux/libtmux-erlang \
    --env hexpm
```

Then push the reviewed release tag as described below. New Hex packages use
[staged publishing](https://hex.pm/docs/workload-identity#staged-publishing):
open the approval URL printed by the job and approve using fresh 2FA.
Package and documentation uploads can require separate approvals. The job
waits with `--wait`; its publishing job has a 30-minute limit. If that wait
expires, inspect Hex's pending release before approving or rerunning.

After the package is public, configure OIDC and revoke the temporary key.

### Route B: one manual publication

Use a clean checkout of the reviewed release commit on qualified Linux.
Install the versions in [.tool-versions](../.tool-versions), a C11 compiler,
Make and supported tmux; see [CONTRIBUTING.md](CONTRIBUTING.md).
The publisher lives only in the `release` profile. It is absent from the
installed package's dependencies.

Authenticate interactively. This changes the local Rebar3 account settings.

```console
$ mise exec -- rebar3 as release hex user auth
```

Prepare the pinned native documentation renderer.

```console
$ mise exec -- python3 tools/build_docs.py --prepare
```

Build the compiler documentation chunks and validate the rendered links.

```console
$ mise exec -- python3 tools/build_docs.py
```

Build and inspect the source package, including the C helper source and its
license. For this candidate the archive is
`_build/release/lib/libtmux_erlang/hex/libtmux_erlang-0.0.1.tar`.

```console
$ mise exec -- rebar3 as release hex build package \
    --app libtmux_erlang
```

Exercise the actual publisher without uploading or authenticating.

```console
$ mise exec -- rebar3 as release hex publish \
    --yes \
    --dry-run \
    --doc-dir "$PWD/_build/docs/core"
```

After reviewing the candidate and its native CI, publish once with the
maintainer's explicit release decision. Native records require these prebuilt
EEP-48 docs; do not substitute legacy EDoc source parsing.

```console
$ mise exec -- rebar3 as release hex publish \
    --yes \
    --wait \
    --doc-dir "$PWD/_build/docs/core"
```

Configure OIDC before pushing the tag. The tag workflow compares the existing
public package byte for byte with its qualified tarball and skips the package
upload when they match. It still publishes the documentation. A mismatch
fails; the workflow never uses `--replace` or reverts a release.

## Configure OIDC after bootstrap

As a full package owner with 2FA, open the package's Workload identities tab
and add this GitHub identity:

- Repository owner: `libtmux`
- Repository: `libtmux-erlang`
- Workflow: `release.yml`
- Environment: `hexpm`

The publisher job has `id-token: write`. Pinned `rebar3_hex` 7.5.0 exchanges
the GitHub token automatically when no Hex credential is configured.
The job explicitly unsets an empty `HEX_API_KEY` so it reaches that path.
No AWS identity or website publisher credential is involved.

Revoke the bootstrap key at Hex and remove its environment secret.

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
$ python3 tools/check_release.py
```

For the initial candidate, create the annotated tag locally. Later releases
use their matching `vVERSION` instead.

```console
$ git tag -a v0.0.1 -m 'Release 0.0.1'
```

Check that the tag resolves to this commit and matches the package version.

```console
$ python3 tools/check_release.py --tag v0.0.1
```

The next command starts the publishing workflow and is the release action.

```console
$ git push origin v0.0.1
```

The workflow runs the existing native suite on OTP 29.1.2, tmux 3.3a and 3.8,
and both qualified Linux architectures, plus helper sanitizers, properties,
regex conformance and documentation checks. The publish job verifies that
its exact source tarball matches the one installed by native CI. It checks
reproducibility again before calling the native publisher.

## Confirm delivery or retry

Inspect the **Hex release** run, the package's public release, and
`https://hexdocs.pm/libtmux_erlang/0.0.1/`. The final job installs the exact
version from public Hex in an empty consumer with an empty build cache,
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
$ mise exec -- python3 tools/check_source_package.py --prepare
```

```console
$ mise exec -- python3 tools/check_source_package.py
```
