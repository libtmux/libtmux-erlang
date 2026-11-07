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
  Erlang formatting qualification remains open; no formatter widens examples.
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

## Erlang documentation

Keep API contracts beside their definitions. Describe inputs, results,
errors, side effects, process and resource ownership, and cleanup. State
whether a call performs I/O. Use typespecs to describe contracts without
presenting them as runtime validation.

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
