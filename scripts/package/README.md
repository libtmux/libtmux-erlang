# Check an installed package

Run these checks from the repository root after `mise exec -- rebar3 compile`.
They run the public examples and native consumers outside the checkout. Set
`LIBTMUX_TEST_TMUX` to an absolute executable path to select a tmux release.
Without it the checks use `tmux` from `PATH`.

## Check the compiled OTP archive

The outer loop runs this check. It builds the archive from the compiled
application, unpacks it and runs the consumers against the installed `ebin`
and packaged C helper.

```console
$ mise exec -- escript scripts/package/check_package.erl
```

The archive and `receipt.json` are in `_build/package-check/`. Add `--dialyzer`
to check the installed types after `mise exec -- rebar3 dialyzer` prepares the
project's PLT.

## Check the Hex source before publishing

Prepare the tooling once per runtime and pin set. This step downloads and
verifies the archives in [tools/package-tool.json](../../tools/package-tool.json).

```console
$ mise exec -- escript scripts/package/check_source_package.erl --prepare
```

Build and install the artifact through a private loopback registry. The check
verifies that installation builds the C helper from source and that a missing
C compiler gives the expected build failure.

```console
$ mise exec -- escript scripts/package/check_source_package.erl
```

Find the receipt, artifact, consumer lockfile and command logs under
`_build/source-package-check/`. The receipt binds the artifact digest to the
source revision and records registry and consumer cleanup.

## Check a published Hex version

Run this from the checkout matching the published release. Replace `VERSION`
with that version. Release CI runs this command after publishing and checks
`_build/checks/hex-install.json` for the install result.

```console
$ mise exec -- escript scripts/package/check_hex_install.erl VERSION
```

## Run package unit tests

The [mid loop](../check/README.md) includes the package tests. For an archive
change, run its test module on its own.

```console
$ mise exec -- rebar3 eunit --module check_package_tests
```
