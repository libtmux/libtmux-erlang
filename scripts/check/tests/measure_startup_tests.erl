-module(measure_startup_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

failed_startup_has_no_timing_summary_test() ->
    ?assertError({startup_failed, #{status := 7}},
        measure_startup:summarize([result(0, 0.1), result(7, 0.2)])).

summary_keeps_every_whole_command_sample_test() ->
    Summary = measure_startup:summarize([result(0, 0.3), result(0, 0.1), result(0, 0.2)]),
    ?assertMatch(#{samples_seconds := [0.3, 0.1, 0.2], min_seconds := 0.1,
                   median_seconds := 0.2, max_seconds := 0.3}, Summary).

result(Status, Seconds) ->
    #{status => Status, seconds => Seconds, stdout => <<>>, stderr => <<>>}.
