# Writing

This guide covers documentation, user-facing text, comments, commits, and
review descriptions. [CONTRIBUTING.md](CONTRIBUTING.md) owns setup and checks.

## Voice

Lead with the conclusion or the reader's task. Use active voice, concrete
nouns, and short sentences. Assume no shared history: explain the purpose
of a referenced issue, decision, or commit instead of giving only its ID.

Describe observable behavior. Remove filler, marketing claims, emojis, and
tool signatures. Distinguish planned features from implemented behavior and
verified compatibility. Omit installation and usage examples for packages
or APIs that do not exist.

## Markdown

Use CommonMark with blank lines around headings and lists. Wrap repository
prose near 80 columns except tables, links, and commands. Keep personal
information and local absolute paths out of published text.

### Code blocks

- Use `console` fences with a `$ ` prefix for shell commands.
- Put one paste-and-run command in each block. An explicit `&&`, `;`, or
  `\` chain counts as one command.
- Put comments, prerequisites, and explanations outside the fence.
- Split long commands with `\`, using one flag per continuation line.
- Use relative links for repository files and check that targets exist.

Run examples as documented and verify their stated results. Future examples
that touch tmux must own their socket and cleanup. Compiling an example
alone does not prove its runtime behavior.

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** examples use 80 columns, enforced by
  `tools/check_example_width.py` and `.github/example-width.toml`.
  Formatter enforcement is deferred because erlfmt 1.8.0 does not parse native
  record declarations. See the [formatting policy](CONTRIBUTING.md#formatting).
- **Not formatted:** example programs and Markdown fences are maintained at
  80 columns by hand. Native EEP-48 code blocks use the same limit, checked
  by `tools/check_docs.py` using the shared column measure. Expected shell
  replies are compared output; numbered input prompts are checked code.
- **Runs, compiles, exempt:** `ct_doctest` executes native shell transcripts.
  `tools/run_examples.escript` executes the complete reader programs;
  the outer archive check repeats them as an installed consumer.
- **Compared output and copied blocks:** output assertions stay intact.
  Edit programs in examples/, then refresh their `<!-- example: ... -->`
  excerpts; `tools/check_docs.py` rejects drift. Prose policy counterexamples
  below demonstrate formatting and are not executable product examples.

Bad, over 80:

```erlang
    Result = tmux_select:where(#{current_command => #{in => [<<"nvim">>, <<"vim">>]}}, Panes).
```

Good, name the reusable criteria:

```erlang
    Editors = #{current_command => #{in => [<<"nvim">>, <<"vim">>]}},
    Result = tmux_select:where(Editors, Panes).
```

## Package READMEs

Each OTP application owns a README with its existing logo, package name,
purpose and installation or build steps. Use task headings, link sibling
packages and the API reference, and state release and support limits.

Run every shown command from the stated directory. Copy code from complete
executed examples, check displayed output, and link detailed contracts to
their guides. Keep logos and the README in the source package so the package
entry point survives installation. Link its changelog and license.

## README shape

A README is a landing page that readers scan. Follow the layout of the
[Go port's README](https://github.com/libtmux/libtmux-go/blob/master/README.md):
tasks first, each API linked, an example under it.

- **Header:** logo block, centred title and a badge row: CI, the registry
  version when the package is published, libtmux.org docs and license. ExDoc's
  Earmark does not parse Markdown inside an HTML block, so write everything
  inside the centred `div` as HTML.
- **Sections:** each `##` heading is a task in the reader's words, such as
  "Find and filter".
- **API headings:** each `###` heading is the function or module in code font,
  linked to its libtmux.org reference page, then a colon and its job in plain
  words.
- **Under a heading:** a line or two linking sibling APIs, the executed
  example, what it prints, at most one short note and a `More:` link to the
  guide.
- **No walls:** no paragraph over three lines. A list of facts is a bullet
  list.
- **No feature inventory:** sections and examples show what exists. Never open
  with "Implemented: ...".
- **Requirements are floors:** "tmux 3.3a or newer", "Erlang/OTP 29". Leave out
  toolchain patch versions, CI matrix narration and kernel details, and link
  the page that holds them.
- **Cut the obvious:** that examples are tested, how docs are built, what the
  checks cover, and "evidence" or "contract" boilerplate.
- **Packages:** keep the package table. Under it, one heading per package that
  links its directory on GitHub, a one-line description and a link line for the
  API reference, registry and changelog.
- **Support and status, What it leaves out:** short bullets that start in bold.
- **Headline features:** show queries and filters, the planner, batching,
  optimisation and control mode, each under an API-linked heading with an
  executed example. Leave out a feature the library lacks.
- **Examples:** each comes from a file CI compiles and runs and starts with its
  `-module`, `-export` and `-import_record` lines. An example sets up and
  cleans up through the library, such as `tmux_server:with_owned/2`, never with
  shell `tmux` commands.
- **Links:** every link resolves. Link files, not directories, in guides. Do
  not link HexDocs, which is not published.

## Erlang documentation

Keep API contracts beside their definitions. Describe inputs, results,
errors, side effects, process and resource ownership, and cleanup. State
whether a call performs I/O. Use typespecs to describe contracts without
presenting them as runtime validation.

### Interlinking

Link API symbols at their first useful mention in each documentation block.
Use native Erlang Markdown references so ExDoc, the shell and editor tooling
share the same names. Qualify references across modules; short local
references must belong to the current module.

Keep the opening module paragraph a short purpose statement. Put member links
in the following paragraphs: ExDoc can shorten even qualified self-links to
page-local anchors before reusing the summary on the API index.

| Target | Inline reference |
| --- | --- |
| Module | `m:tmux_snapshot` |
| Local function | `fetch/1` |
| Remote function | `tmux_server:snapshot/1` |
| Type | `t:tmux_model:pane/0` or local `t:t/0` |
| Behaviour callback | `c:tmux_matcher:prepare/2` |
| Reader guide | A relative Markdown link to the guide's extra page |

Link related calls when the distinction affects behavior, such as local data
versus I/O, waiting versus cancellation, or a physical window versus one
membership. Keep option keys, error atoms and tmux command names as literal
code. Do not turn every repeated word into a link or hand-code API HTML URLs.

Use `-moduledoc` for navigation and workflows, `-doc` for call contracts, and
document exported types and callbacks beside their definitions. Keep code
examples executable. Change generated documentation through its generator.

Build the native browser with warnings treated as errors and check the
rendered links and anchors. A source reference is not verified until its
rendered target resolves. Follow the
[OTP documentation reference rules](https://www.erlang.org/doc/system/documentation.html#links-in-markdown).

Comments explain constraints, invariants, and non-obvious choices. Remove
comments that repeat names or narrate the next expression. Preserve tooling
directives and explanations of protocol or platform workarounds.

## Commits and reviews

Each independently published application owns its CHANGELOG.md. The root
changelog holds changes spanning applications, including documentation, CI
and release tooling. Source-package assembly must include the relevant file;
release qualification must reject a package without one. Do not invent a
published release heading for an unreleased application.

Use this commit format; the bracketed detail is optional:

```text
scope(type[detail]) Concise description

why: Explanation of necessity or impact.
what:
- Specific technical changes made
- Focused on a single topic
```

Use lowercase scopes unless naming a proper product or class. Explain the
durable reason and change. Keep temporary validation results in the review
discussion.

Review descriptions start with the concrete problem and resulting behavior.
Explain the final change for someone who has not read the conversation.
Include relevant evidence, failures, and skipped checks.
