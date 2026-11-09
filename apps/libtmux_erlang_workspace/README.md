<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-128.png" width="128" height="128" alt="libtmux workspace for Erlang">
  </picture>

# libtmux workspace for Erlang

</div>
<!-- /libtmux-logo -->

Plan and apply versioned JSON workspaces through the public Erlang core API.
Review saved operations before execution; failures preserve the completed
prefix and distinguish observed drift from uncertain command outcomes.

The [workspace guide](https://github.com/libtmux/libtmux-erlang/blob/master/docs/workspaces.md)
provides real input files, complete runnable programs and checked output. The
outer suite repeats them using installed core and workspace OTP archives.

The application uses the core's public API and OTP libraries.
[Project policy](https://github.com/libtmux/libtmux-erlang/blob/master/docs/project-policy.md)
defines package boundaries. The source-package check installs workspace and
its core dependency through a signed local registry, builds the CLI and runs it
outside the checkout.
Build the standalone workspace CLI with Rebar3 escriptize. It plans without
mutations and applies saved operations with per-step drift checks, explicit
adoption, launch hashes and completed-prefix receipts. The guide includes a
complete owned-server example and the trusted endpoint configuration.
Registry publication and large-workspace performance remain separate gates.
No registry release is advertised.
