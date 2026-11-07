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

## Erlang documentation

Keep API contracts beside their definitions. Describe inputs, results,
errors, side effects, process and resource ownership, and cleanup. State
whether a call performs I/O. Use typespecs to describe contracts without
presenting them as runtime validation.

Comments explain constraints, invariants, and non-obvious choices. Remove
comments that repeat names or narrate the next expression. Preserve tooling
directives and explanations of protocol or platform workarounds.

## Commits and reviews

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
