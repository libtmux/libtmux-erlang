-module(tmux_test_sandbox_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

hook_prepares_once_and_removes_only_its_own_directory_test() ->
    with_environment([{"LIBTMUX_TEST_SANDBOX", false}, {"TMUX_TMPDIR", false},
                      {"TMUX", "outside"}, {"TMUX_PANE", "%1"},
                      {"LIBTMUX_SOCKET", "outside"}, {"LIBTMUX_SOCKET_PATH", "outside"}],
        fun() ->
            {ok, Owner} = tmux_test_sandbox:init(test, []),
            Directory = os:getenv("LIBTMUX_TEST_SANDBOX"),
            try
                ?assertEqual(ok, tmux_test_sandbox:require()),
                {ok, #file_info{mode = Mode}} = file:read_link_info(Directory),
                ?assertEqual(8#700, Mode band 8#777),
                ?assert(length(Directory ++ "/tmux-1000/default") < 100),
                {ok, Reused} = tmux_test_sandbox:init(test, []),
                ?assertEqual(Directory, os:getenv("LIBTMUX_TEST_SANDBOX")),
                ok = tmux_test_sandbox:terminate(Reused),
                ?assert(filelib:is_dir(Directory))
            after ok = tmux_test_sandbox:terminate(Owner)
            end,
            ?assertNot(filelib:is_dir(Directory)),
            ?assertEqual(false, os:getenv("LIBTMUX_TEST_SANDBOX")),
            ?assertEqual("outside", os:getenv("TMUX"))
        end).

unprepared_environment_refuses_test() ->
    with_environment([{"LIBTMUX_TEST_SANDBOX", false}, {"TMUX_TMPDIR", false}], fun() ->
        ?assertMatch({error, #{code := unsafe_test_environment}},
                     tmux_test_sandbox:require())
    end).

guard_rejects_selectors_mismatches_and_public_directories_test() ->
    tmux_test_sandbox:with([], fun(Environment) ->
        with_environment(Environment, fun() ->
            lists:foreach(fun({Name, Value, Reason}) ->
                with_environment([{Name, Value}], fun() ->
                    ?assertMatch({error, #{reason := Reason}}, tmux_test_sandbox:require())
                end)
            end, [{"TMUX", "", inherited_selector},
                  {"TMUX_TMPDIR", "/tmp/unrelated", sandbox_mismatch},
                  {"LIBTMUX_TEST_SANDBOX", "relative", invalid_sandbox_path}]),
            Directory = os:getenv("LIBTMUX_TEST_SANDBOX"),
            ok = file:change_mode(Directory, 8#755),
            try
                ?assertMatch({error, #{reason := unsafe_directory_mode}},
                             tmux_test_sandbox:require())
            after ok = file:change_mode(Directory, 8#700)
            end
        end)
    end).

exception_cleanup_does_not_follow_a_symlink_test() ->
    tmux_test_sandbox:with([], fun(Outer) ->
        Outside = proplists:get_value("LIBTMUX_TEST_SANDBOX", Outer),
        Keep = filename:join(Outside, "keep"),
        ok = file:write_file(Keep, <<"keep">>),
        Self = self(),
        ?assertError({badmatch, {error, enoent}},
            tmux_test_sandbox:with([], fun(Inner) ->
                Directory = proplists:get_value("LIBTMUX_TEST_SANDBOX", Inner),
                Self ! {directory, Directory},
                ok = file:make_symlink(Outside, filename:join(Directory, "outside")),
                {ok, Contents} = file:read_file(filename:join(Directory, "missing")),
                Contents
            end)),
        Directory = receive {directory, Path} -> Path end,
        ?assertNot(filelib:is_dir(Directory)),
        ?assertEqual({ok, <<"keep">>}, file:read_file(Keep))
    end).

cleanup_preserves_a_replacement_directory_test() ->
    tmux_test_sandbox:with([], fun(Environment) ->
        Parent = proplists:get_value("LIBTMUX_TEST_SANDBOX", Environment),
        Renamed = filename:join(Parent, "original"),
        Self = self(),
        ?assertException(error, #{code := test_sandbox_cleanup_failed,
                                  reason := sandbox_directory_changed},
            tmux_test_sandbox:with([{"TMPDIR", Parent}], fun(Child) ->
                Directory = proplists:get_value("LIBTMUX_TEST_SANDBOX", Child),
                ok = file:write_file(filename:join(Directory, "original"), <<"owned">>),
                ok = file:rename(Directory, Renamed),
                ok = file:make_dir(Directory),
                ok = file:write_file(filename:join(Directory, "replacement"), <<"keep">>),
                Self ! {replacement, Directory}
            end)),
        Directory = receive {replacement, Path} -> Path end,
        ?assertEqual({ok, <<"owned">>}, file:read_file(filename:join(Renamed, "original"))),
        ?assertEqual({ok, <<"keep">>}, file:read_file(filename:join(Directory, "replacement")))
    end).

long_parent_refuses_before_callback_or_directory_creation_test() ->
    tmux_test_sandbox:with([], fun(Environment) ->
        Root = proplists:get_value("LIBTMUX_TEST_SANDBOX", Environment),
        Long = filename:join(Root, lists:duplicate(75, $x)),
        ok = file:make_dir(Long),
        Self = self(),
        ?assertException(error, #{reason := socket_path_too_long},
            tmux_test_sandbox:with([{"TMPDIR", Long}], fun(_) -> Self ! ran end)),
        ?assertEqual({ok, []}, file:list_dir(Long)),
        receive ran -> ?assert(false) after 0 -> ok end
    end).

remaining_socket_prevents_directory_removal_test() ->
    Self = self(),
    ?assertException(error, #{code := test_sandbox_cleanup_failed,
                              reason := unretired_socket},
        tmux_test_sandbox:with([], fun(Environment) ->
            Directory = proplists:get_value("LIBTMUX_TEST_SANDBOX", Environment),
            {ok, Socket} = socket:open(local, stream, default),
            ok = socket:bind(Socket, #{family => local,
                path => filename:join(Directory, "left.sock")}),
            Self ! {socket, Directory, Socket}
        end)),
    {Directory, Socket} = receive {socket, Path, Handle} -> {Path, Handle} end,
    try ?assert(filelib:is_dir(Directory))
    after
        ok = socket:close(Socket),
        ok = file:del_dir_r(Directory)
    end.

callback_failure_survives_cleanup_failure_test() ->
    tmux_test_sandbox:with([], fun(Environment) ->
        Parent = proplists:get_value("LIBTMUX_TEST_SANDBOX", Environment),
        with_environment([{"TMPDIR", Parent}, {"LIBTMUX_TEST_SANDBOX", false},
                          {"TMUX", "outside"}], fun() ->
            try
                ?assertException(error, #{code := test_sandbox_cleanup_failed,
                                          reason := unretired_socket,
                                          callback := {raised, error, {badmatch, {error, enoent}}, _}},
                    tmux_test_sandbox:with(fun() ->
                        Directory = os:getenv("LIBTMUX_TEST_SANDBOX"),
                        {ok, Socket} = socket:open(local, stream, default),
                        ok = socket:bind(Socket, #{family => local,
                            path => filename:join(Directory, "left.sock")}),
                        self() ! {socket, Directory, Socket},
                        {ok, Contents} = file:read_file(filename:join(Directory, "missing")),
                        Contents
                    end)),
                ?assertEqual(false, os:getenv("LIBTMUX_TEST_SANDBOX")),
                ?assertEqual("outside", os:getenv("TMUX"))
            after
                receive {socket, Kept, Open} ->
                    ok = socket:close(Open),
                    ok = file:del_dir_r(Kept)
                after 0 -> ok
                end
            end
        end)
    end).

empty_tmpdir_uses_an_owned_default_test() ->
    Result = tmux_test_sandbox:with([{"TMPDIR", ""}], fun(Environment) ->
        Directory = proplists:get_value("LIBTMUX_TEST_SANDBOX", Environment),
        {ok, #file_info{type = directory, mode = Mode}} = file:read_link_info(Directory),
        ?assertEqual(8#700, Mode band 8#777),
        ok
    end),
    ?assertEqual(ok, Result).

with_environment(Changes, Function) ->
    Previous = [{Name, os:getenv(Name)} || {Name, _} <- Changes],
    set_environment(Changes),
    try Function()
    after set_environment(Previous)
    end.

set_environment(Environment) ->
    lists:foreach(fun
        ({Name, false}) -> _ = os:unsetenv(Name);
        ({Name, Value}) -> true = os:putenv(Name, Value)
    end, Environment).
