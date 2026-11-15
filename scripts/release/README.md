# check_release

Checks a release before and after publication:

- the application version is SemVer without build metadata, and a `vVERSION`
  tag matches it exactly;
- the checkout is clean and the tag points at `HEAD`;
- a source tarball matches the one on Hex byte for byte, and, with
  `--qualified-receipt`, the passing native CI receipt for the same commit and
  bytes.

`.github/workflows/release.yml` runs it in the candidate and publish jobs and
reads its output (`version`, `head`, `sha256`, `published`) from
`GITHUB_OUTPUT`. Only HTTP 404 means a version is unpublished; any other
registry answer or a different payload fails.

Compile the library first, then run from the repository root:

```console
$ escript scripts/release/check_release.erl --tag v0.0.1
```

Run the tests with:

```console
$ rebar3 eunit --module check_release_tests
```
