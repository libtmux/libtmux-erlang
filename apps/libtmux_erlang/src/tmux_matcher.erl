-module(tmux_matcher).
-moduledoc """
Prepare a trusted local predicate once for a captured snapshot.

Use `tmux_select:matching/2` with `{Module, State}`. The application chooses
Module; external filter documents cannot select the `c:prepare/2`
callback. Preparation returns a unary Boolean function or a tagged error.
Callback exceptions propagate. The adapter does not make executable predicates
portable or push them to tmux.
""".
-doc """
Prepare a local Boolean predicate once for this captured snapshot. Return a
tagged preparation error when the matcher cannot operate. Callback exceptions
remain application failures; this does not make a matcher portable or suitable
for untrusted module selection.
""".
-callback prepare(State :: term(), Snapshot :: tmux_snapshot:t()) ->
    {ok, fun((tmux_model:row()) -> boolean())} | {error, term()}.
