# Changelog

## Unreleased

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
