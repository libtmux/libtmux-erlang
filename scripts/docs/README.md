# Documentation checks and build

Two escripts check and build the documentation. CI, the release workflow and
the mid and outer check loops run them; contributors run them after editing a
guide, an example or a doc comment. Run both from the repository root after
the library compiles, because they load the helpers that Rebar3 builds.

```console
$ rebar3 compile
```

## check_docs

`check_docs.erl` checks the guide corpus: `README.md`, `docs/*.md` and
`apps/*/README.md`.

- Relative links resolve inside the checkout and name existing headings.
- A `<!-- example: path -->` block equals its source file. Use `path#region`
  to display the lines between `% docs:begin region` and `% docs:end region`
  in an Erlang example. An `example-input` block equals its JSON file.
- Every other code block is classified: Erlang terms are read with
  `file:consult/1`, JSON output carries an `example-output` marker, and a
  `console` block holds one command.
- Numbered prompts in native `-moduledoc` examples stay within 80 columns,
  counting East Asian wide characters as two.

```console
$ escript scripts/docs/check_docs.erl
```

`--examples-receipt _build/checks/examples.json` also compares displayed JSON
with what the examples printed. `--html-directory _build/docs/core` uses
`check_rendered_docs` to check links, anchors and resources in the rendered
tree. Source links into this repository must name objects in the checkout.

The receipt is printed and written to `_build/checks/`: `docs-corpus.json`,
`docs-corpus-runtime.json` or `docs-rendered.json`. The terms read by
`file:consult/1` stay in `doc-terms.config`. The exit status is 1 when a
check fails.

## build_docs

`build_docs.erl` builds the native API browser with the ExDoc escript that
`tools/docs-tool.json` pins. Download it once; this is the only network use.
The script verifies the HTTPS peer, the size and the SHA-256 digest.

```console
$ escript scripts/docs/build_docs.erl --prepare
```

The build compiles the library and stages guides, source pages and media
through `docs_sources`. It runs ExDoc with warnings as errors and checks the
rendered HTML.

```console
$ escript scripts/docs/build_docs.erl
```

The output is `_build/docs/core`. The receipt `_build/checks/docs.json` records
the commit, the working-tree state, a digest of `git diff --binary HEAD` and
the hashes of inputs, sources, media and beams. A file that differs from
`HEAD` is labelled a working-tree preview. The build fails when its inputs
change while it runs.

## Tests

The EUnit modules in `tests/` build temporary trees and check each failure
for its reason. They need `git` but no network, ExDoc or tmux.

```console
$ rebar3 eunit \
    --module docs_util_tests,check_docs_tests,build_docs_tests
```
