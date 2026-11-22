# Guides

- [Start a private server and count its panes](first-task.md) in a fresh
  Rebar3 project.
- [Inspect an existing socket](installation.md#inspect-an-existing-server).
- [Create, capture and query a workspace](../README.md#create-capture-and-query)
  with sessions, windows and panes.
- [Install the core application](installation.md) from Hex or source.

## Read and filter server state

- [Query captured rows or fetch fresh state](querying.md).
- [Traverse a shared-window graph](graph.md).
- [Read runtime diagnostics](diagnostics.md).

## Act on tmux

- [Own a daemon or open a borrowed handle](ownership.md).
- [Prepare and submit command values](commands.md).
- [Attach a control client](control.md).
- [Read live pane output](control.md#read-pane-output).
- [Run or stop a program in a private terminal](programs.md).
- [Wait for a job and capture its output](jobs.md).
- [Wait for visible text in a running pane](jobs.md#wait-for-visible-text).
- [Read and write scoped options](options.md).
- [Store bytes and paste into a pane](buffers.md).
- [Rearrange panes](panes.md).
- [Load configuration and wait for an event](configuration.md).
- [Pipe terminal output](pipe.md).
- [Install hooks and wait for completion](hooks.md).
- [Register bindings in a key table](keys.md).

## Reference

- [Native API browser](api.md).
- [Fields and operators](fields.md).
- [Option catalogue](options-reference.md).
- [Command catalogue and feature minimums](commands-reference.md).
- [Supported versions and open gaps](compatibility.md).

## Project

- [Application boundaries and runtime dependencies](project-policy.md).
- [Architecture decisions](adr-0001-architecture.md).
