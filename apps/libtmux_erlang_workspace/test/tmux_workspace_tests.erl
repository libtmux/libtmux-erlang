-module(tmux_workspace_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

file_and_directory_identity_test() ->
    temporary(fun(Dir) ->
        Real = filename:join(Dir, <<"real">>),
        Inner = filename:join(Real, <<"inner">>),
        ok = file:make_dir(Real),
        ok = file:make_dir(Inner),
        ok = file:make_symlink(<<"real/inner">>, filename:join(Dir, <<"alias">>)),
        Path = write(Dir, desired(#{<<"cwd">> => <<"alias/..">>,
                                    <<"argv">> => [<<"printf">>, <<"$HOME; #{x}">>]})),
        {ok, Workspace} = tmux_workspace:load(Path),
        #{id := Id, endpoint := <<"dev">>, sessions := [Session]} = tmux_workspace:to_map(Workspace),
        #{key := <<"/sessions/0">>, windows := [Window]} = Session,
        #{key := <<"/sessions/0/windows/0">>, panes := [Pane]} = Window,
        ?assertMatch(#{key := <<"/sessions/0/windows/0/panes/0">>, cwd := Real,
            launch := #{argv := [<<"printf">>, <<"$HOME; #{x}">>]}}, Pane),
        ok = file:make_symlink(<<"workspace.json">>, filename:join(Dir, <<"source.json">>)),
        {ok, Alias} = tmux_workspace:load(filename:join(Dir, <<"source.json">>)),
        ?assertEqual(Id, maps:get(id, tmux_workspace:to_map(Alias)))
    end).

schema_and_error_paths_test() ->
    temporary(fun(Dir) ->
        Base = desired(#{<<"argv">> => [<<"sh">>]}),
        Cases = [
            {Base#{<<"version">> => 2}, unsupported_version, [<<"version">>]},
            {Base#{<<"socket">> => <<"/tmp/borrowed">>}, unknown_field, [<<"socket">>]},
            {Base#{<<"sessions">> => []}, invalid_collection, [<<"sessions">>]},
            {desired(#{<<"argv">> => []}), invalid_collection, pane_path(<<"argv">>)},
            {desired(#{<<"argv">> => [<<>>]}), invalid_text, pane_path(<<"argv">>) ++ [0]},
            {desired(#{<<"argv">> => [<<"sh">>], <<"shell">> => <<"sh">>}),
                ambiguous_launch, lists:droplast(pane_path(<<"argv">>))},
            {desired(#{<<"argv">> => [<<"sh">>], <<"env">> => #{}}),
                unknown_field, pane_path(<<"env">>)}
        ],
        lists:foreach(fun({Document, Code, JsonPath}) ->
            ?assertMatch({error, #{code := Code, path := JsonPath,
                                  file := <<"workspace.json">>}},
                tmux_workspace:load(write(Dir, Document)))
        end, Cases),
        Duplicate = Base#{<<"sessions">> => [
            #{<<"key">> => <<"same">>, <<"name">> => <<"editor">>,
              <<"windows">> => [#{<<"key">> => <<"same">>, <<"name">> => <<"api">>,
                  <<"panes">> => [#{<<"argv">> => [<<"sh">>]}]}]}]},
        ?assertMatch({error, #{code := duplicate_key, path := [<<"sessions">>, 0,
            <<"windows">>, 0, <<"key">>]}}, tmux_workspace:load(write(Dir, Duplicate))),
        Path = filename:join(Dir, <<"workspace.json">>),
        ok = file:write_file(Path, <<"{\"version\":1,\"\\u0076ersion\":1}">>),
        ?assertMatch({error, #{code := duplicate_key, path := [<<"version">>]}},
                     tmux_workspace:load(Path)),
        #{<<"sessions">> := [Session]} = Base,
        lists:foreach(fun(Name) ->
            Changed = Base#{<<"sessions">> => [Session#{<<"name">> => Name}]},
            ?assertMatch({error, #{code := invalid_name,
                path := [<<"sessions">>, 0, <<"name">>]}},
                tmux_workspace:load(write(Dir, Changed)))
        end, [<<"a:b">>, <<"a.b">>, <<"a\nb">>, <<"a\\b">>])
    end).

filesystem_boundaries_test() ->
    temporary(fun(Dir) ->
        ?assertMatch({error, #{code := file_error, reason := enoent}},
            tmux_workspace:load(filename:join(Dir, <<"absent.json">>))),
        ?assertMatch({error, #{code := not_regular_file}}, tmux_workspace:load(Dir)),
        Path = filename:join(Dir, <<"workspace.json">>),
        ok = file:write_file(Path, binary:copy(<<" ">>, 262145)),
        ?assertMatch({error, #{code := document_limit}}, tmux_workspace:load(Path)),
        ok = file:make_symlink(<<"loop">>, filename:join(Dir, <<"loop">>)),
        ?assertMatch({error, #{code := file_error, reason := eloop}},
            tmux_workspace:load(filename:join(Dir, <<"loop">>))),
        ?assertMatch({error, #{code := invalid_directory, reason := enoent,
                              path := [<<"sessions">>, 0, <<"windows">>, 0,
                                       <<"panes">>, 0, <<"cwd">>]}},
            tmux_workspace:load(write(Dir, desired(#{<<"cwd">> => <<"missing">>,
                                                    <<"argv">> => [<<"sh">>]})))),
        ?assertMatch({error, #{code := invalid_file}}, tmux_workspace:load(42))
    end).

explicit_shell_is_inert_test() ->
    temporary(fun(Dir) ->
        Shell = <<"printf '%s' '$HOME; #{x}'">>,
        Document = (desired(#{<<"shell">> => Shell}))#{<<"id">> => <<"demo">>},
        {ok, Workspace} = tmux_workspace:load(write(Dir, Document)),
        #{id := <<"demo">>, sessions := [#{windows := [#{panes := [Pane]}]}]} =
            tmux_workspace:to_map(Workspace),
        ?assertMatch(#{cwd := Dir, launch := #{shell := Shell}}, Pane),
        ?assertEqual(["workspace.json"], element(2, file:list_dir(Dir)))
    end).

desired(Pane) ->
    #{<<"version">> => 1, <<"endpoint">> => <<"dev">>, <<"sessions">> => [
        #{<<"name">> => <<"editor">>, <<"windows">> => [
            #{<<"name">> => <<"api">>, <<"panes">> => [Pane]}]}]}.

pane_path(Field) -> [<<"sessions">>, 0, <<"windows">>, 0, <<"panes">>, 0, Field].

write(Dir, Document) ->
    Path = filename:join(Dir, <<"workspace.json">>),
    ok = file:write_file(Path, json:encode(Document)),
    Path.

temporary(Function) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Pid = list_to_binary(os:getpid()),
    Dir = <<"/tmp/ltm-workspace-", Pid/binary, "-", Suffix/binary>>,
    ok = file:make_dir(Dir),
    try Function(Dir) after ok = file:del_dir_r(Dir) end.
