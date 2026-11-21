# Changelog

## Unreleased

- Use `tmux_pane:wait_exit/2` to read a pane's exit status or signal after tmux
  publishes it. Set `remain-on-exit` to retain the pane.
- Use `tmux_capability:decision/2` to see the release a feature requires and
  how it behaves on older daemons. Version checks order development builds,
  numbered release candidates, stable releases and letter patches.
- Errors for unsupported releases name the tmux client or daemon, the found
  and required releases, and what to change. Feature refusals give the same
  release details for operations such as JSON layouts and sanitized paste.

## 0.0.1 - 2026-11-13

- Publish the initial core application on Hex with its helper source,
  native records, captured graphs, filters and explicit tmux operations.

- Add bounded one-shot command sequences and ordered scalar option batches,
  with native ID envelopes, strict byte framing and explicit interval semantics.

- Include helper source provenance alongside its binary and license for
  standalone archives; helper protocol and source stay unchanged.

- Expose a versioned fingerprint of captured Linux process identity for
  persistent comparison across endpoint handles, without an I/O or liveness
  claim.

- Batch snapshot text and byte fields in one scan per entity, with strict
  byte framing, identity checks and unchanged capture bracketing. Capture and
  fetch options accept `hydration => isolated` for larger entity output under
  the existing per-command limit. Plans and metadata expose the strategy.

- Correct the minimum tmux version to 3.3a. Support includes all releases
  through 3.8; CI tests the two endpoints. Option, hook and native command
  metadata cover intermediate releases with their exact source provenance.

- Local library exceptions include native EEP-54 explanations for validation,
  missing observations and cardinality errors. Reasons and callback stacks
  retain their existing contracts.

- Emit bounded OTP Logger reports for client results, operation outcomes,
  capture rejection, held read credit and owned-daemon failures. Reports omit
  command payloads, terminal output and resource paths.

- Scoped server lifetimes preserve callback and cleanup outcomes together,
  including recovery handles after incomplete cleanup. Nested resource scopes
  preserve failures in examples without masking the original diagnostic.

- Entity constructors expose generated input-map types and structured
  validation errors. Installed consumer checks verify useful Dialyzer
  diagnostics for invalid fields and missing required identities.

- Source packages include the C helper's source, build rules and provenance.
  Installation compiles the helper; prebuilt executables are excluded.

- Model version 2 binds action targets to their captured identity. Editing
  row identity or provenance fails action validation; valid-shaped binding
  mismatches return `observation_mismatch`. Bind a fresh observation to retarget. Discard retained version-1 rows and
  snapshots and restart consumers when upgrading. No hot-upgrade conversion
  is provided.
