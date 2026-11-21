#!/usr/bin/env escript
%%! -pa _build/default/lib/libtmux_erlang/ebin
-mode(compile).

main(_) ->
    {ok, Source} = file:read_file("test/fixtures/regex-v1.json"),
    #{<<"patterns">> := Patterns} = json:decode(Source),
    Results = [prepare(P) || P <- Patterns],
    io:format("~s~n", [json:encode(#{patterns => Results,
        otp => list_to_binary(erlang:system_info(otp_release)),
        erts => list_to_binary(erlang:system_info(version)),
        pcre2 => re:version()})]).

prepare(#{<<"pattern">> := Pattern, <<"cases">> := Cases}) ->
    {ok, Compiled} = tmux_regex:compile(Pattern),
    {ok, Pcre} = tmux_regex:render(Pattern, pcre2),
    {ok, Javascript} = tmux_regex:render(Pattern, javascript),
    {ok, Rust} = tmux_regex:render(Pattern, rust),
    #{pattern => Pattern, pcre2 => Pcre, javascript => Javascript, rust => Rust,
      cases => [begin
          #{<<"subject">> := Subject, <<"expected">> := Expected} = Case,
          Actual = case tmux_regex:run(Compiled, Subject) of
              {ok, Boolean} -> Boolean;
              {error, #{code := Code}} -> atom_to_binary(Code)
          end,
          case Actual =:= Expected of
              true -> ok;
              false -> error({regex_fixture_mismatch, Pattern, Case, Actual})
          end,
          #{subject => Subject, expected => Expected, actual => Actual}
      end || Case <- Cases]}.
