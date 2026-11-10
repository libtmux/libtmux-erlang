<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-128.png" width="128" height="128" alt="libtmux workspace for Erlang">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux workspace for Erlang

</div>

`libtmux_erlang_workspace` plans and applies JSON workspaces through the
[Erlang core library](../libtmux_erlang/README.md). Review saved operations
before execution; failures preserve the completed prefix and distinguish
observed drift from uncertain command outcomes.

[Workspace guide](../../docs/workspaces.md) ·
[Core API reference](https://libtmux.org/en/erlang/latest/reference/) ·
[Changelog](CHANGELOG.md)

## Build the standalone CLI

Use Erlang/OTP 29.1.2, Rebar3 3.28.0, Linux x86_64 or arm64, tmux 3.3a–3.8,
and make with a C11 compiler. This application is unreleased; build from the
repository root with the [pinned tools](../../.github/CONTRIBUTING.md#setup):

```console
$ mise exec -- rebar3 escriptize
```

Inspect the available commands:

```console
$ mise exec -- _build/default/bin/libtmux-workspace --help
```

The escript includes the compiled helper, its license and provenance. Copy it
to another machine using the same Linux architecture and OTP baseline. The
[CLI guide](../../docs/workspaces.md#configure-the-endpoint) explains trusted
endpoint configuration, planning and applying a saved plan.

## Apply a workspace and verify an empty second plan

Run this complete [example program](../../examples/workspace_apply_demo.erl)
from the repository root:

```console
$ mise exec -- escript tools/run_examples.escript workspace-apply
```

It reads the [argv-only input](../../examples/workspace_apply.json), creates
one session with two panes on its own server, writes and reloads the plan,
applies it, and verifies the captured graph. Planning the unchanged input
again produces zero steps. The program removes its temporary files and
retires its server and clients.

The runner checks this output:

<!-- example-output: workspace_apply_demo -->

```json
{
  "sessions": 1,
  "windows": 1,
  "panes": 2,
  "plan_round_trip": true,
  "second_plan_empty": true,
  "files_removed": true
}
```

The installed-consumer checks repeat this program and run the actual CLI
outside the checkout, including a fresh build from the two source packages.

## Plan changes on an existing server

The CLI resolves endpoint names through a trusted host configuration. A
workspace file cannot choose an arbitrary socket. Plans store stable targets,
ownership markers, launch intent and preconditions; apply executes that saved
plan and stops on observed drift or an uncertain result.

Use the [planning workflow](../../docs/workspaces.md#review-a-plan-then-execute-it)
for real input and host files, explicit adoption, CLI exit codes and recovery.
Read [CLI interruption](../../docs/workspaces.md#interrupt-the-cli) before
relying on cancellation: SIGTERM returns a receipt, while Ctrl-C and SIGKILL
exit without JSON and can leave remote steps applied or temporary files behind.

## Check the package boundary

The workspace application depends on the core's public API and OTP libraries.
Source-package qualification installs workspace and its core dependency through
a signed local registry, builds the helper and CLI, and runs installed examples.
See [project policy](../../docs/project-policy.md) and
[source installation checks](../../.github/CONTRIBUTING.md#current-checks).

Registry publication and complete performance qualification remain separate
gates. No registry release is advertised. Changes are listed in the
[changelog](CHANGELOG.md); the package uses the [MIT license](LICENSE).
