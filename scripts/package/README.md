# Check an installed package

Run from the repository root after `rebar3 compile`. The libtmux_erlang
checks install outside the checkout and execute the public examples.
Select tmux with an absolute `LIBTMUX_TEST_TMUX` path, or use `tmux` on `PATH`.

## Check the compiled OTP archive

The [outer loop](../check/README.md) checks the installed beams and C helper:

```console
$ escript scripts/package/check_package.erl
```

Find the archive and receipt in `_build/package-check/`. Add `--dialyzer`
after `rebar3 dialyzer` to check the installed types.

## Check the Hex source before publishing

Prepare the [pinned tools](../../tools/package-tool.json) once per runtime
and pin set:

```console
$ escript scripts/package/check_source_package.erl --prepare
```

Install through a private signed registry. A missing C compiler must fail
before a successful installation builds the helper from source:

```console
$ escript scripts/package/check_source_package.erl
```

Find the artifact, lockfile, command logs and receipt under
`_build/source-package-check/`. The receipt binds source and artifact
identities and records registry and consumer cleanup. `source_package_tools`
owns downloads and cache integrity; `source_package_registry` owns serving.

## Check a published Hex version

Use the matching release checkout and replace `VERSION` with its version:

```console
$ escript scripts/package/check_hex_install.erl VERSION
```

The [release verifier](../../.github/RELEASE.md#verify-after-hex-approval)
checks the installed quickstart on tmux 3.8 after approval. Its receipt is
`_build/checks/hex-install.json`. The [mid loop](../check/README.md) includes
all package unit tests.
