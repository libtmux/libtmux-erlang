-module(tmux_scope).
-moduledoc """
Run synchronous work and cleanup while preserving both outcomes.

Use `run/2` around a resource whose handle remains in the caller's scope.
Use `run_or_error/2` for nested scopes or fail-fast programs that need the
callback's value directly and raise when cleanup fails.
`tmux_server:with_server/2` and `tmux_server:with_owned/2` also acquire their
resources and add recovery handles when cleanup fails. This module owns no
process, timeout or retry policy; the supplied functions own those contracts.
""".
-export([run/2, run_or_error/2]).
-export_type([exception/0, failure/0]).

-doc "The original exception class, reason and stack, retained as evidence.".
-type exception() :: {exception, error | exit | throw, term(), erlang:stacktrace()}.
-doc """
Both outcomes when cleanup failed. primary contains the callback's ordinary
return or exception; cleanup contains its separate error or exception.
Resource-specific wrappers may add recovery handles to this map.
""".
-type failure() :: #{code := scope_cleanup_failed,
    primary := {ok, term()} | exception(),
    cleanup := {error, term()} | exception(), atom() => term()}.

-doc """
Run a callback, then attempt cleanup once, synchronously in the calling process.
This function performs only the I/O supplied by those functions. The callback
has no library duration timer. Abrupt uncatchable caller death remains subject
to each resource's existing ownership policy.

Only ok proves cleanup success. Normalize resource-specific successful replies
inside the cleanup function. With successful cleanup, return {ok, Value} or
re-raise the original callback exception with its reason and stack. A callback
returning an error tuple is an ordinary value. Cleanup failure instead returns
{error, Failure} with `t:failure/0`, preserving both outcomes. An unexpected
cleanup return is recorded as invalid_cleanup_result.

Handle an inner scope's error explicitly when nesting scopes. Otherwise it is
an ordinary outer callback value. Keep resource handles for recovery; this
function does not infer ownership or retry cleanup.

```erlang
1> tmux_scope:run(fun() -> done end, fun() -> ok end).
{ok,done}
2> tmux_scope:run(fun() -> done end, fun() -> {error, enoent} end).
{error,#{code => scope_cleanup_failed,
         primary => {ok,done},cleanup => {error,enoent}}}
3> Work = fun() -> error(build_failed) end, ok.
ok
4> {error, F} = tmux_scope:run(Work, fun() -> {error, busy} end), ok.
ok
5> {exception, error, build_failed, [_ | _]} = maps:get(primary, F), ok.
ok
6> maps:get(cleanup, F).
{error,busy}
```
""".
-spec run(fun(() -> Value), fun(() -> ok | {error, term()})) ->
    {ok, Value} | {error, failure()}.
run(Function, Cleanup) when is_function(Function, 0), is_function(Cleanup, 0) ->
    Primary = outcome(Function),
    Retired = case outcome(Cleanup) of
        {ok, ok} -> ok;
        {ok, {error, _} = Error} -> Error;
        {ok, Other} -> {error, #{code => invalid_cleanup_result, value => Other}};
        {exception, _, _, _} = Exception -> Exception
    end,
    case {Primary, Retired} of
        {{ok, Value}, ok} -> {ok, Value};
        {{exception, Class, Reason, Stack}, ok} -> erlang:raise(Class, Reason, Stack);
        _ -> {error, #{code => scope_cleanup_failed,
                       primary => Primary, cleanup => Retired}}
    end.

-doc """
Run work and cleanup with `run/2`, returning the callback value directly.
Raises {scope_cleanup_failed, Failure} if cleanup fails, retaining both
outcomes in `t:failure/0`. With successful cleanup, callback exceptions retain
their original reason and stack. Nested raising scopes propagate an inner
failure through the outer scope while still attempting outer cleanup.
""".
-spec run_or_error(fun(() -> Value), fun(() -> ok | {error, term()})) -> Value.
run_or_error(Function, Cleanup) ->
    case run(Function, Cleanup) of
        {ok, Value} -> Value;
        {error, Failure} -> erlang:error({scope_cleanup_failed, Failure}, none,
            [{error_info, #{module => tmux_error}}])
    end.

outcome(Function) ->
    try {ok, Function()}
    catch Class:Reason:Stack -> {exception, Class, Reason, Stack}
    end.
