# Changelog

## Unreleased

- Model version 2 binds action targets to their captured identity. Editing
  row identity or provenance fails action validation; valid-shaped binding
  mismatches return `observation_mismatch`. Bind a fresh observation to retarget. Discard retained version-1 rows and
  snapshots and restart consumers when upgrading. No hot-upgrade conversion
  is provided.
