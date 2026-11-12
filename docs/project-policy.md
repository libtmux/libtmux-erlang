# Project policy

This port provides the `libtmux_erlang` core application.

The [architecture decision record](adr-0001-architecture.md) explains the
selected design, alternatives, consequences and conditions for reconsideration.

## OTP application boundaries

Develop the application in the Rebar3 umbrella layout. It is an independent
package boundary with its own metadata, license and changelog.

| Application | Responsibility | Library dependencies |
| --- | --- | --- |
| `libtmux_erlang` | tmux transport, operations, domain objects, snapshots and queries | OTP applications |

Consumers use public APIs through installed packages; source paths and private
core modules are not integration boundaries. Additional packages need their own
reusable responsibility and explicit consumer dependencies.

Package qualification must install the core outside the umbrella. A successful
umbrella build alone does not prove that an independently installed package
works; see [current support](compatibility.md).

## Runtime dependencies

Use the latest stable Erlang/OTP baseline and native OTP facilities. Use OTP
JSON for documents. Prefer module functions, native records, specs, tagged
results and supervised processes where ownership requires them.

Keep Erlang runtime dependencies within OTP. An exception requires a concrete
capability need, maintenance assessment and recorded architecture decision.
Test, build and documentation tools are separate from runtime dependencies.

Support covers tmux 3.3a–3.8, including intermediate releases, on Linux x86_64
and arm64. CI uses only the latest stable Erlang/OTP release and samples the
oldest supported and newest stable tmux releases. Verify upstream releases
before updating the exact pins. Historical results retain their recorded scope.

The Linux transport uses the bundled C11 executable for bounded I/O and owned
process retirement. It is built from packaged source with recorded provenance.

The layout follows [Rebar3 application organization](https://rebar3.org/docs/basic_usage/)
and [OTP application boundaries and dependencies](https://www.erlang.org/doc/system/applications.html).
