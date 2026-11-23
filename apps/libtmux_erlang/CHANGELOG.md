# Changelog

## Unreleased

- Submit ID reads, session renames and window or pane resizes with
  `tmux_control:submit/3` on an owned attachment. Await ordered replies
  or cancel the group. An interrupted group keeps confirmed replies and can
  leave the remaining outcome unknown.
- Read live pane output and native notifications on borrowed sessions with
  `tmux_stream:subscribe/3`. It uses a dedicated client and skips the session
  environment update.
- Open borrowed endpoints without firing discovery after-hooks. Native command
  aliases keep their tmux behavior; discovery requires native `list-commands`.
- Explicitly destroy a borrowed daemon with `tmux_server:kill/1`. Process
  preflight and a native daemon PID guard refuse observed replacements. Stop
  owned daemons with their ownership token instead.
- Wait for screen text on live borrowed panes with `tmux_pane:wait_for_text/3`
  or `tmux_pane_text:start/3`. Replacement and respawn end the observation.
- Wait for pane exit with `tmux_pane:wait_exit/2`. tmux 3.8 uses a filtered
  native event. Older supported daemons use a private hook. The owner
  retires the wait client on caller death and rejects observed replacements.
- Return `exit_status_unavailable` at the deadline when the bound process
  has exited and tmux has published neither a status nor a signal. Return
  `pane_generation_unavailable` if registration cannot pin the terminal
  and confirm the live process.
- Report unrecognized tmux client versions as `invalid_tmux_version` when
  starting a managed program. The error includes the required release and
  confirmed probe cleanup.

## 0.0.3 - 2026-11-22

- Use `tmux_stream:subscribe/3` to read pane bytes and native notifications
  from an owned session. Acknowledge each event and request more credit
  as needed.

## 0.0.2

- Run literal argv in a private tmux 3.8 terminal with `tmux_program:run/3`.
  Collect the application's exit, bounded screen and cleanup receipt. Use
  `tmux_program:start/3` to send input or stop an interactive run.
- Set absolute window width and height with `tmux_window:resize/2`.
- Use `tmux_pane:wait_exit/2` to read a pane's exit status or signal after tmux
  publishes it. Set `remain-on-exit` to retain the pane.
- Wait for literal screen text on an owned live pane with
  `tmux_pane:wait_for_text/3`. Use `tmux_pane_text:start/3` to observe the pane
  before sending input.
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
