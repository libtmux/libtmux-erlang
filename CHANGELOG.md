# Changelog

## Unreleased

## 0.0.3

- [Set up Erlang and Rebar3](docs/installation.md#set-up-erlang-and-rebar3)
  with system tools, mise or asdf. Run examples with the tools on `PATH`.
- [Read live pane output and native notifications](docs/control.md#read-pane-output)
  on an owned tmux server. Subscriptions track credit and report gaps.

## 0.0.2

- Install the core from Hex in a fresh Rebar3 project. The quickstart counts
  panes in a private tmux server, stops the server and prints the count.
- Find installation and first tasks together in the native docs. Examples link
  to the Erlang APIs they use, and the compatibility guide links the generated
  capability manifest.
- On tmux 3.8, [run a program in a private terminal](docs/programs.md) with
  literal arguments. Collect its exit, bounded screen capture and cleanup
  result. Start a program separately to send input or request stop.
- Wait for pane exit or visible text on an owned server. The
  [job guide](docs/jobs.md) shows when to read the rendered screen.
- Run contributor checks and examples with Erlang tooling. The shared
  example-width check uses Python.
- Tagged Hex releases use workload identity and check for HTTP 200 on the
  versioned HexDocs README.

## 0.0.1 - 2026-11-13

- Package the existing 512px logo for a sharp 128px README display on Hex.

- Link the live Erlang guides and API reference from both READMEs and Hex
  package metadata, alongside the executed reader examples.

- Publish the initial core and add tag-based Hex publication, with
  native source qualification, executable docs and OIDC after bootstrap.

- Record bounded local scalar option batches in ADR 0003.

- Report native pane exit/signal details when the installed consumer's input
  job ends unexpectedly, while retaining its expected successful-exit check.

- Add a source-pinned Erlang/Elixir filter comparison that reports wire,
  field-domain and validation-diagnostic incompatibilities.

- Record batched complete-graph hydration, byte framing, measured source cost
  and the explicit isolated strategy in ADR 0002.

- Check recursive native candidate filters against captured full predicates
  on owned linked-window fixtures.

- Check generated relationship filters against an independent graph model,
  including shared windows, repeated memberships and empty quantifiers.

- Support tmux 3.3a–3.8, including intermediate releases. Run CI on the latest
  stable Erlang/OTP with tmux 3.3a and 3.8 on both Linux architectures.

- Document runtime Logger domains, correlated outcomes, capture costs and
  report data boundaries.

- Example attempts invalidate older success receipts before running and
  record caught failures explicitly.

- Reader programs preserve operation and cleanup failures together, including
  nested resource cleanup. The README uses a scoped owned daemon.

- Build separate Hex source artifacts and check a clean Rebar3 installation
  through a signed local registry before registry publication.
