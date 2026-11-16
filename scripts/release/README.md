# release

Checks a release and publishes it to Hex.

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

Compile the library first, then run from the repository root:

```console
$ escript scripts/release/check_release.erl --tag v0.0.1
```

## publish_hex

Publishes the qualified package and the prebuilt documentation to Hex. The
publish job of `.github/workflows/release.yml` runs it with the `published`
output of `check_release.erl`:

```console
$ escript scripts/release/publish_hex.erl --published false
```

`--published true` skips the package, which Hex already holds, and publishes
only the documentation from `_build/docs/core`. An empty or unset
`HEX_API_KEY` is removed from the environment of the Rebar3 commands, so a run
without the repository secret authenticates the way an unset key does. Each
command waits for Hex within ten minutes, prints its output and stops the
script at the first failure.

## Tests

Run the tests of both scripts with:

```console
$ rebar3 eunit --module=check_release_tests,publish_hex_tests
```
