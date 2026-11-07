-module(tmux_matcher).
-moduledoc """
Prepare a trusted local predicate once for a captured snapshot.

Use tmux_select:matching({Module, State}, Selection). The application chooses
Module; external filter documents cannot select callbacks. Preparation returns
a unary Boolean function or a tagged error. Callback exceptions propagate.
The adapter does not make executable predicates portable or push them to tmux.
""".
-callback prepare(State :: term(), Snapshot :: tmux_snapshot:t()) ->
    {ok, fun((tmux_model:row()) -> boolean())} | {error, term()}.
