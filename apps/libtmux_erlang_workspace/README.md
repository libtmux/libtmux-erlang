<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-128.png" width="128" height="128" alt="libtmux workspace for Erlang">
  </picture>

# libtmux workspace for Erlang

</div>
<!-- /libtmux-logo -->

Load versioned JSON workspace files and inspect validated desired sessions,
windows and panes with `tmux_workspace:load/1` and `tmux_workspace:to_map/1`.
Relative cwd values resolve against the canonical file directory. Endpoint
names remain host-configuration keys; loading never contacts tmux or launches
programs.

The [workspace guide](https://github.com/libtmux/libtmux-erlang/blob/master/docs/workspaces.md)
provides a real input file,
complete runnable program and checked output. The outer suite repeats that
program using installed core and workspace OTP archives.

The application uses the core's public JSON API and OTP libraries.
[Project policy](https://github.com/libtmux/libtmux-erlang/blob/master/docs/project-policy.md)
defines package boundaries. The source-package check installs workspace and
its core dependency through a signed local registry and executes this loader.
Planning, applying changes and a workspace CLI remain implementation work.
No registry release or CLI installation is advertised.
