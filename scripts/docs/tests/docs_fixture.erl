-module(docs_fixture).
-moduledoc false.
-compile(nowarn_missing_spec).
-export([with_tree/2, write/3, git/2, init_repository/1, setup/0, cleanup/1]).

setup() ->
    {ok, _} = application:ensure_all_started(libtmux_erlang).

cleanup(_) -> ok = application:stop(libtmux_erlang).

% Run `Fun` with a temporary directory holding `Files`, a list of {Path, Data}.
with_tree(Files, Fun) ->
    script_util:with_tmp_dir("docs-test", fun(Directory) ->
        Root = unicode:characters_to_binary(Directory),
        lists:foreach(fun({Path, Data}) -> write(Root, Path, Data) end, Files),
        Fun(Root)
    end).

write(Root, Path, Data) ->
    ok = docs_util:write_file(filename:join(Root, Path), Data).

git(Root, Arguments) ->
    Identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false"],
    script_util:run_ok("git", Identity ++ Arguments,
        #{cwd => Root, env => #{<<"GIT_CONFIG_GLOBAL">> => <<"/dev/null">>,
                                <<"GIT_CONFIG_NOSYSTEM">> => <<"1">>}}).

init_repository(Root) ->
    _ = git(Root, ["init", "--quiet"]),
    _ = git(Root, ["add", "--all"]),
    _ = git(Root, ["commit", "--quiet", "--message", "fixture"]),
    ok.
