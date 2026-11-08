# Project policy

This port provides an Erlang core and a workspace consumer. An MCP package,
server or SDK integration is excluded from implementation and release scope.

The [architecture decision record](adr-0001-architecture.md) explains the
selected design, alternatives, consequences and conditions for reconsideration.

## OTP application boundaries

Develop the applications together in the Rebar3 umbrella. Each application is
an independent package boundary with its own metadata, license and changelog.

| Application | Responsibility | Library dependencies |
| --- | --- | --- |
| `libtmux_erlang` | tmux transport, operations, domain objects, snapshots and queries | OTP applications |
| `libtmux_erlang_workspace` | JSON workspace loading, plans, apply and CLI | Public core API and OTP applications |

The workspace application declares its core dependency in its application
metadata. It uses public APIs through installed packages; source paths and
private core modules are not integration boundaries. The core is independent
of the workspace application. Additional core packages need their own reusable
responsibility and explicit consumer dependencies.

Package qualification must install each consumer outside the umbrella against
the produced core package. A successful umbrella build alone does not prove
that an independently installed workspace package works. The workspace CLI is
still implementation work; see [current support](compatibility.md).

## Runtime dependencies

Use the latest stable Erlang/OTP baseline and native OTP facilities. Use OTP
JSON for documents and the standard argument parser for the planned CLI.
Prefer module functions, native records, specs, tagged results and supervised
processes where ownership requires them.

Keep Erlang runtime dependencies within OTP. An exception requires a concrete
capability need, maintenance assessment and recorded architecture decision.
Test, build and documentation tools are separate from runtime dependencies.

The Linux transport uses the bundled C11 executable for bounded I/O and owned
process retirement. It is built from packaged source with recorded provenance.
Workspace code uses that transport through the public core API.

The layout follows [Rebar3 application organization](https://rebar3.org/docs/basic_usage/)
and [OTP application boundaries and dependencies](https://www.erlang.org/doc/system/applications.html).
