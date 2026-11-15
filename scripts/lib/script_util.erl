-module(script_util).
-moduledoc """
Helpers shared by the Erlang scripts under `scripts/`.

Every script is an Erlang module that `escript` runs from the repository
root and that Rebar3 compiles, type checks and tests with the library. Start
`main/1` with the three lines below; they put the compiled helpers on the code
path, so run `rebar3 compile` first.

```erlang
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    ...
```

Subprocesses run through the library's own packaged helper, so a command that
outlives its deadline is killed with its descendants and its output is bounded.
""".
-export([boot/1, run/3, run_ok/3, git/2, sha256_hex/1, with_tmp_dir/2]).
-export_type([result/0]).

-define(OUTPUT_LIMIT, 1048576).

-doc """
Outcome of one command: its exit status (`timeout` when the deadline passed,
`error` when it never ran or its output overflowed), both output streams and
the whole-command duration in seconds.
""".
-type result() :: #{status := non_neg_integer() | timeout | error,
                    stdout := binary(), stderr := binary(), seconds := float(),
                    reason => atom()}.

-doc """
Change into the repository root, put the compiled application on the code path
and start it. Returns `ok`.
""".
-spec boot(file:filename_all()) -> ok.
boot(Root) ->
    ok = file:set_cwd(Root),
    ok = code:add_pathsa([filename:join(Root, "_build/default/lib/libtmux_erlang/ebin")]),
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    ok.

-doc """
Run `Executable` (a name found on `PATH` or an absolute path) with `Arguments`.

Options: `cwd` (absolute directory), `env` (a map of binary names to binary
values, `false` unsets), `stdin` (binary), `timeout_ms` (default 30000, at most
600000) and `max_stdout` (default and maximum 1 MiB). Performs I/O; never
raises for a failing command.
""".
-spec run(file:filename_all(), [file:filename_all()], map()) -> result().
run(Executable, Arguments, Options) ->
    Started = erlang:monotonic_time(microsecond),
    Elapsed = fun() -> (erlang:monotonic_time(microsecond) - Started) / 1.0e6 end,
    case executable(Executable) of
        error -> #{status => error, reason => not_found, stdout => <<>>,
                   stderr => <<>>, seconds => Elapsed()};
        Path ->
            Transport = maps:merge(#{timeout_ms => 30000, max_stdout => ?OUTPUT_LIMIT},
                                   Options),
            Result = tmux_transport:run(Path, [to_binary(A) || A <- Arguments], Transport),
            outcome(Result, Elapsed())
    end.

-doc """
Run a command that must exit with status 0 and return its standard output.
Raises `{command_failed, Executable, Arguments, Result}` otherwise.
""".
-spec run_ok(file:filename_all(), [file:filename_all()], map()) -> binary().
run_ok(Executable, Arguments, Options) ->
    case run(Executable, Arguments, Options) of
        #{status := 0, stdout := Stdout} -> Stdout;
        Result -> error({command_failed, Executable, Arguments, Result})
    end.

-doc "Run `git` in `Root` and return its standard output without trailing whitespace.".
-spec git([file:filename_all()], file:filename_all()) -> binary().
git(Arguments, Root) ->
    string:trim(run_ok("git", Arguments, #{cwd => to_binary(Root)}), trailing).

-doc "Lowercase hexadecimal SHA-256 of a file's bytes or of an iolist.".
-spec sha256_hex({file, file:filename_all()} | iodata()) -> binary().
sha256_hex({file, Path}) ->
    {ok, Bytes} = file:read_file(Path),
    sha256_hex(Bytes);
sha256_hex(Data) ->
    binary:encode_hex(crypto:hash(sha256, Data), lowercase).

-doc """
Run `Fun` with a fresh private directory under `TMPDIR` (or `/tmp`) and remove
it afterwards, whatever `Fun` does.
""".
-spec with_tmp_dir(string(), fun((file:filename()) -> Result)) -> Result.
with_tmp_dir(Prefix, Fun) ->
    Base = case os:getenv("TMPDIR") of
        Value when is_list(Value), Value =/= "" -> Value;
        _ -> "/tmp"
    end,
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase)),
    Directory = filename:join(Base, Prefix ++ "-" ++ Suffix),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    try Fun(Directory)
    after ok = file:del_dir_r(Directory)
    end.

executable(Name) ->
    Text = unicode:characters_to_list(Name),
    case filename:pathtype(Text) of
        absolute -> unicode:characters_to_binary(Text);
        _ -> case os:find_executable(Text) of
                 false -> error;
                 Path -> unicode:characters_to_binary(Path)
             end
    end.

to_binary(Value) -> unicode:characters_to_binary(Value).

outcome({ok, #{exit_status := Status, stdout := Out, stderr := Err}}, Seconds) ->
    #{status => Status, stdout => Out, stderr => Err, seconds => Seconds};
outcome({error, #{code := timeout} = Error}, Seconds) ->
    failure(timeout, timeout, Error, Seconds);
outcome({error, #{code := Code} = Error}, Seconds) ->
    failure(error, Code, Error, Seconds).

failure(Status, Reason, Error, Seconds) ->
    #{status => Status, reason => Reason, seconds => Seconds,
      stdout => maps:get(stdout, Error, <<>>), stderr => maps:get(stderr, Error, <<>>)}.
