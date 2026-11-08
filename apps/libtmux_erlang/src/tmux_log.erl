-module(tmux_log).
-moduledoc false.
-include_lib("kernel/include/logger.hrl").
-export([transport/2, credit/4, operation/4, capture/4, owned/3, shutdown/1]).

%% Reports are built only after Logger's module-level check. Keep these closed
%% projections separate from status/error maps, which can contain user bytes.
-spec transport(map(), {ok | error, map()}) -> ok.
transport(State, Result = {_, Detail}) ->
    Level = case {maps:get(cleanup, Detail, complete), code(Detail)} of
        {incomplete, _} -> warning;
        {_, helper_unavailable} -> warning;
        {_, helper_failure} -> warning;
        {_, helper_exit} -> warning;
        {_, exec_failed} -> warning;
        {_, unsupported_capability} -> warning;
        _ -> debug
    end,
    ?LOG(Level, transport_report(State, Result), #{domain => [libtmux, transport]}),
    ok.

transport_report(State, Result) ->
    (result(Result))#{event => transport_result, transport => maps:get(token, State),
        mode => maps:get(mode, State),
        duration_us => elapsed(maps:get(started_us, State)),
        stdout_bytes => maps:get(size, maps:get(stdout, State)),
        stderr_bytes => maps:get(size, maps:get(stderr, State)),
        stdin_delivered => maps:get(input_delivered, State)}.

-spec credit(map(), stdout | stderr, pos_integer(), pos_integer()) -> ok.
credit(State, Stream, Sequence, Bytes) ->
    ?LOG_DEBUG(#{event => transport_credit_held, transport => maps:get(token, State),
        stream => Stream, sequence => Sequence, held_bytes => Bytes},
        #{domain => [libtmux, transport]}),
    ok.

-spec operation(reference(), reference(), map(), {ok | error, map()}) -> ok.
operation(Generation, Id, Op, Result = {_, Detail}) ->
    Level = case maps:get(cleanup, Detail, complete) of
        incomplete -> warning;
        _ -> debug
    end,
    ?LOG(Level, (result(Result))#{event => operation_result,
        generation => Generation, operation => Id, phase => maps:get(phase, Op),
        stage => maps:get(stage, Op),
        tracked_duration_us => elapsed(maps:get(started_us, Op)),
        stdout_bytes => byte_size(maps:get(stdout, Detail, <<>>)),
        stderr_bytes => byte_size(maps:get(stderr, Detail, <<>>))},
        #{domain => [libtmux, operation]}),
    ok.

-spec capture(map(), reference(), integer(),
    {ok, tmux_snapshot:t(), [term()]} | {error, map()}) -> ok.
capture(Context, Id, Started, Result) ->
    ?LOG_DEBUG(maps:merge(#{event => capture_result, capture => Id,
        generation => maps:get(generation, Context), duration_us => elapsed(Started)},
        capture_result(Result)), #{domain => [libtmux, query]}),
    ok.

capture_result({ok, Snapshot, _}) ->
    Metadata = tmux_snapshot:metadata(Snapshot),
    #{result => ok, source_calls => length(maps:get(source_calls, Metadata)),
      observed_bytes => maps:get(observed_bytes, Metadata)};
capture_result({error, Detail}) ->
    (reason(Detail))#{result => error, code => code(Detail)}.

-spec owned(atom(), map(), map()) -> ok.
owned(Event, State, Detail) ->
    ?LOG_WARNING((reason(Detail))#{event => Event, ownership => maps:get(token, State),
        code => code(Detail)}, #{domain => [libtmux, ownership]}),
    ok.

-spec shutdown(map()) -> ok.
shutdown(#{reports := Reports}) ->
    ?LOG_ERROR(#{event => owned_server_shutdown_incomplete,
        scope => application, code => owned_cleanup_incomplete,
        failed_owners => length(Reports)}, #{domain => [libtmux, ownership]}),
    ok.

result({Tag, Detail}) ->
    #{result => Tag, code => code(Detail),
      cleanup => maps:get(cleanup, Detail, unverified),
      outcome => maps:get(outcome, Detail, unknown)}.

code(#{code := Code}) when is_atom(Code) -> Code;
code(_) -> none.

reason(#{reason := Reason}) when is_atom(Reason) -> #{reason => Reason};
reason(_) -> #{}.

elapsed(Started) -> max(0, erlang:monotonic_time(microsecond) - Started).
