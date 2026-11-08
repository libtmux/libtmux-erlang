# Changelog

## Unreleased

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
