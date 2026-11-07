# libtmux for Erlang

The Erlang port is under development. The current implementation provides
validated native records, generated field schemas, tmux version checks,
command renderers, a bounded subprocess adapter and borrowed endpoint owners.
Operations support bounded admission, cancellation, ownership transfer and
result retention. Session/window creation and rename, pane splits, capture,
literal input and key input use registered stable IDs. Records can be read or
explicitly rebound; detached and stale rows cannot act through these APIs.
Explicit snapshots capture sessions, unique physical windows and panes, and
every window membership. Ordinary lists, relationship navigation and coverage
checks read those captured values without I/O. Captures record their read
intervals and reject detected conflicts; they are not atomic.
Local selections preserve row order and coverage, with portable map filters,
Boolean callbacks, relationship quantifiers and checked cardinality. Native
JSON decoding enforces document bounds and rejects duplicate keys. Prepared
filters remain bound to their captured context. Restricted ASCII regex has
shared PCRE2, JavaScript and Rust matching fixtures. Source queries plan
conservative native filters, fetch complete graph context and apply the full
local predicate before limits.
Integration tests use owned tmux servers. Remaining command families,
persistent control, MCP and the workspace CLI remain implementation
work.

Development targets Erlang/OTP 29.1.2. The planned Linux compatibility floor
is plain tmux 3.3. Native records are experimental in OTP 29; another OTP line
requires consumer and model-upgrade qualification.

Build the three OTP applications:

```console
$ mise exec -- rebar3 compile
```

Run the local checks:

```console
$ time python3 tools/check.py mid
```

Check native record imports and executable examples from an unpacked OTP
archive outside the source checkout:

```console
$ time python3 tools/check.py outer
```

The archive check verifies model imports, the installed helper adapter and
the public endpoint, operation, domain, snapshot and filter calls in
[the consumer example](examples/native_consumer.erl). It runs that example
against a private tmux fixture and verifies cleanup.
Hex packaging and the complete compatibility matrix remain open.
See [contributor setup](.github/CONTRIBUTING.md)
for tool versions, generated sources and check budgets.
