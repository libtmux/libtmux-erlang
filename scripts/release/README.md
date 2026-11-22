# release

Checks a release, verifies its publishing identity and publishes it to Hex.

## check_hex_identity

The authentication-only dispatch of `.github/workflows/release.yml` runs this
script in the `hexpm` environment with `id-token: write`. It uses the same
`hex_cli_auth:workload_identity_auth/2` function as pinned `rebar3_hex`, scopes
the token to `libtmux_erlang`, and revokes it after one read-only API request.
The read must deny permission (HTTP 403) because the token can only publish;
after revocation it must reject authentication (HTTP 401). It uploads nothing
and never prints or saves tokens. A configured `HEX_API_KEY` environment
variable makes the check fail.

Dispatch the check from master:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-erlang \
    --ref master \
    --field verify_identity=true
```

This verifies authentication, not a release upload or approval. The workflow
does not pass the bootstrap `HEX_API_KEY` secret to either job.

## check_release

Checks a release before and after publication:

- the application version is SemVer without build metadata, and a `vVERSION`
  tag matches it exactly;
- the checkout is clean and the tag points at `HEAD`;
- a source tarball matches the one on Hex byte for byte, and, with
  `--qualified-receipt`, the passing native CI receipt for the same commit and
  bytes.

`.github/workflows/release.yml` runs it in the candidate and publish jobs and
reads its output (`version`, `head`, `sha256`, `published`) from
`GITHUB_OUTPUT`. `--from-actions` takes the tag from `GITHUB_REF_NAME` on a
push event and checks no tag on any other event. Only HTTP 404 means a version
is unpublished; any other registry answer or a different payload fails.

Public verification selects `--submission-run RUN_ID` through the Actions API.
It requires this repository's release workflow, a tag push, SemVer and an exact
commit. The workflow keeps its verifier before checking out the submitted tag;
`--checkout DIRECTORY --submitted-head HEAD` then binds that checkout to the
selected run before checking the artifact and native qualification receipt.

After the public install check, the workflow requires HTTP 200 on the
versioned HexDocs README. Run the same read-only check with a published version.

```console
$ escript scripts/release/check_release.erl --hexdocs 0.0.1
```

Compile the library first, then run from the repository root:

```console
$ escript scripts/release/check_release.erl --tag v0.0.1
```

## publish_hex

Submits the qualified package and the prebuilt documentation together. The
publish job of `.github/workflows/release.yml` runs it with the `published`
output of `check_release.erl`:

```console
$ escript scripts/release/publish_hex.erl --published false
```

`--published true` submits only the documentation from `_build/docs/core`
when the exact package is already public. An empty or unset `HEX_API_KEY`
is removed from the Rebar3 environment. The command prints Hex's submission
status and any approval links.

## Tests

Run the release and identity checks' unit tests with:

```console
$ rebar3 eunit \
    --module=check_release_tests,publish_hex_tests,check_hex_identity_tests
```
