-module(tmux_error).
-moduledoc """
Explain library exceptions through Erlang's native error formatter.

The shell and `erl_error:format_exception/3` call `format_error/2` through
EEP-54 stack metadata. Explanations supplement the original exception reason;
tagged results from `tmux_filter:new/2` and `tmux_select:try_where/2` retain
their existing structured data. Formatting performs no tmux I/O.

Only library-raised errors carry this metadata. Application callback failures
retain their original class, reason and stack. Coverage errors describe missing
observations; formatting never loads those observations or retries an action.
Long detail values may be abbreviated in the explanation. The exception reason
retains the original error data. See [runtime diagnostics](diagnostics.md) for
the separate, bounded Logger report contract.
""".
-behaviour(erl_error).
-export([format_error/2]).

-doc """
Return supplemental native error text, or an empty map for an unknown reason.

This is the `c:erl_error:format_error/2` callback. It neither changes the
exception nor catches it on behalf of a caller.

```erlang
1> #{general := Text} = tmux_error:format_error({bad_query_limit, -1}, []), ok.
ok
2> unicode:characters_to_binary(Text).
<<"The query limit must be an integer from 0 through 65536.">>
```
""".
-spec format_error(term(), erlang:stacktrace()) -> #{general => unicode:chardata()}.
format_error({bad_filter, Detail}, _) -> detail("Invalid filter", Detail);
format_error({bad_selection, Detail}, _) -> detail("Invalid selection", Detail);
format_error({invalid_command, Detail}, _) -> detail("Invalid command value", Detail);
format_error({incomplete_snapshot, Detail}, _) ->
    detail("The captured data is incomplete for this read", Detail);
format_error({filter_evaluation_failed, Detail}, _) ->
    detail("Local filter evaluation failed", Detail);
format_error({prepared_context_mismatch, Detail}, _) ->
    detail("The row is outside the prepared filter's captured context", Detail);
format_error({bad_query_limit, _}, _) ->
    #{general => "The query limit must be an integer from 0 through 65536."};
format_error({unknown_field, Entity, Field}, _) ->
    #{general => ["Unknown ", print(Entity), " field ", print(Field),
        ". Use tmux_schema:fields/1 to inspect permitted fields."]};
format_error(no_match, _) -> #{general => "No row matched the selection."};
format_error({multiple_matches, _}, _) ->
    #{general => "More than one row matched; use tmux_select:first/1 to permit extra matches."};
format_error(invalid_matcher_result, _) ->
    #{general => "Matcher prepare/2 must return {ok, Fun} or {error, Detail}; Fun must be unary."};
format_error({scope_cleanup_failed, _}, _) ->
    #{general => "Resource cleanup failed; the error retains both primary and cleanup outcomes."};
format_error(_, _) -> #{}.

detail(Label, #{code := Code} = Detail) ->
    Path = case Detail of
        #{path := Value} -> [" at ", print(Value)];
        _ -> []
    end,
    Allowed = case Detail of
        #{allowed := Names} -> [" Allowed: ", print(Names), "."];
        _ -> []
    end,
    Required = case Detail of
        #{requirements := Missing} -> [" Missing observations: ", print(Missing), "."];
        _ -> []
    end,
    #{general => [Label, ": ", print(Code), Path, ".", Allowed, Required]};
detail(_, _) -> #{}.

print(Value) -> io_lib:format("~tP", [Value, 8], [{chars_limit, 240}]).
