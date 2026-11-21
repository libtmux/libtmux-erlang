-module(tmux_test_sandbox).
-moduledoc """
Prepare and verify the private tmux environment used by checks and Common Test.
The CT hook reuses an already prepared environment. Cleanup checks the
directory's identity and leaves it in place if a socket remains.
""".
-include_lib("kernel/include/file.hrl").
-export([with/1, with/2, require/0, fixture_directory/0,
         id/1, init/2, pre_init_per_suite/3, pre_init_per_testcase/4, terminate/1]).
-export_type([environment/0]).

-type environment() :: [{string(), string() | false}].
-define(SELECTORS, ["TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH"]).
-define(CONTEXT, ["TMUX_TMPDIR", "LIBTMUX_TEST_SANDBOX" | ?SELECTORS]).

-doc "Run a callback in the prepared environment, or prepare one for this VM.".
-spec with(fun(() -> Result)) -> Result.
with(Function) ->
    State = local_environment(),
    with_cleanup(Function, fun() -> retire(State) end).

-doc "Run a child-environment callback and remove its fresh private directory.".
-spec with(environment(), fun((environment()) -> Result)) -> Result.
with(Environment, Function) ->
    {Directory, _} = Owned = create(Environment),
    with_cleanup(fun() -> Function(environment(Environment, Directory)) end,
                 fun() -> cleanup(Owned) end).

with_cleanup(Function, Cleanup) ->
    Outcome = try {returned, Function()}
              catch Class:CallbackReason:Stack -> {raised, Class, CallbackReason, Stack}
              end,
    case Cleanup() of
        ok -> finish(Outcome);
        {error, Reason} -> error(#{code => test_sandbox_cleanup_failed,
                                  reason => Reason, callback => Outcome})
    end.

-doc "Refuse an unprepared environment before any tmux operation.".
-spec require() -> ok | {error, map()}.
require() ->
    try
        Directory = os:getenv("LIBTMUX_TEST_SANDBOX"),
        check_absolute(Directory),
        check(os:getenv("TMUX_TMPDIR") =:= Directory, sandbox_mismatch),
        check(lists:all(fun(Name) -> os:getenv(Name) =:= false end, ?SELECTORS),
              inherited_selector),
        Info = directory_info(Directory),
        check(Info#file_info.uid =:= uid(), foreign_directory),
        check(Info#file_info.mode band 8#777 =:= 8#700, unsafe_directory_mode),
        check_socket_paths(Directory),
        ok
    catch throw:Reason -> {error, refusal(Reason)}
    end.

-doc "Create a short owner-only fixture directory inside the verified sandbox.".
-spec fixture_directory() -> {ok, file:filename()} | {error, map()}.
fixture_directory() ->
    case require() of
        ok -> {ok, make_directory(os:getenv("LIBTMUX_TEST_SANDBOX"), "f", "/s")};
        Error -> Error
    end.

-doc "Use one Common Test hook per VM.".
-spec id(term()) -> atom().
id(_) -> ?MODULE.

-doc "Reuse a prepared sandbox, or prepare one for direct rebar3 ct.".
-spec init(term(), term()) -> {ok, map()}.
init(_, _) -> {ok, local_environment()}.

-doc "Verify isolation before a suite can start fixtures.".
-spec pre_init_per_suite(atom(), list(), map()) -> {list(), map()}.
pre_init_per_suite(_, Config, State) ->
    require_ok(),
    {Config, State}.

-doc "Verify isolation again before each testcase starts.".
-spec pre_init_per_testcase(atom(), atom(), list(), map()) -> {list(), map()}.
pre_init_per_testcase(_, _, Config, State) ->
    require_ok(),
    {Config, State}.

-doc "Restore the caller environment and remove only a hook-owned directory.".
-spec terminate(map()) -> ok.
terminate(State) ->
    case retire(State) of
        ok -> ok;
        {error, Reason} -> error(#{code => test_sandbox_cleanup_failed, reason => Reason})
    end.

local_environment() ->
    case os:getenv("LIBTMUX_TEST_SANDBOX") of
        false ->
            {Directory, _} = Owned = create([]),
            Previous = [{Name, os:getenv(Name)} || Name <- ?CONTEXT],
            set_environment(environment([], Directory)),
            #{owned => Owned, previous => Previous};
        _ ->
            require_ok(),
            #{owned => none}
    end.

retire(#{owned := none}) -> ok;
retire(#{owned := Owned, previous := Previous}) ->
    try cleanup(Owned)
    after set_environment(Previous)
    end.

create(Environment) ->
    Parent = case proplists:get_value("TMPDIR", Environment, os:getenv("TMPDIR")) of
        false -> "/tmp";
        "" -> "/tmp";
        Value -> Value
    end,
    try
        check_absolute(Parent),
        _ = directory_info(Parent),
        Directory = make_directory(Parent, "lte", socket_suffix()),
        {Directory, identity(directory_info(Directory))}
    catch throw:Reason -> error(refusal(Reason))
    end.

make_directory(Parent, Prefix, Suffix) ->
    Name = Prefix ++ "-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(6), lowercase)),
    Directory = filename:join(Parent, Name),
    check_path_length(Directory ++ Suffix),
    case file:make_dir(Directory) of
        ok ->
            case file:change_mode(Directory, 8#700) of
                ok -> Directory;
                {error, _} ->
                    _ = file:del_dir(Directory),
                    throw(cannot_secure_directory)
            end;
        {error, eexist} -> make_directory(Parent, Prefix, Suffix);
        {error, _} -> throw(cannot_create_directory)
    end.

environment(Environment, Directory) ->
    maps:to_list(maps:merge(maps:from_list(Environment),
        maps:from_list([{"TMUX_TMPDIR", Directory}, {"LIBTMUX_TEST_SANDBOX", Directory} |
                       [{Name, false} || Name <- ?SELECTORS]]))).

check_absolute(Path) when is_list(Path), Path =/= [] ->
    check(filename:pathtype(Path) =:= absolute, invalid_sandbox_path);
check_absolute(_) -> throw(invalid_sandbox_path).

directory_info(Path) ->
    Directory = lists:foldl(fun(Part, Parent) ->
        Current = filename:join(Parent, Part),
        case file:read_link_info(Current) of
            {ok, #file_info{type = directory}} -> Current;
            _ -> throw(invalid_sandbox_directory)
        end
    end, "", filename:split(Path)),
    {ok, Info} = file:read_link_info(Directory),
    Info.

uid() ->
    case file:read_file_info("/proc/self") of
        {ok, #file_info{uid = Uid}} -> Uid;
        _ -> throw(owner_identity_unavailable)
    end.

socket_suffix() ->
    Default = "/tmux-" ++ integer_to_list(uid()) ++ "/default",
    Fixture = "/f-xxxxxxxxxxxx/s",
    case length(Default) >= length(Fixture) of true -> Default; false -> Fixture end.

check_socket_paths(Directory) -> check_path_length(Directory ++ socket_suffix()).

check_path_length(Path) ->
    check(byte_size(unicode:characters_to_binary(Path)) < 100, socket_path_too_long).

check(true, _) -> ok;
check(false, Reason) -> throw(Reason).

require_ok() ->
    case require() of ok -> ok; {error, Reason} -> error(Reason) end.

refusal(Reason) ->
    #{code => unsafe_test_environment, reason => Reason,
      hint => hint(Reason)}.

hint(socket_path_too_long) -> <<"Set TMPDIR to a shorter absolute directory.">>;
hint(invalid_sandbox_directory) -> <<"Use an existing TMPDIR without symbolic links.">>;
hint(invalid_sandbox_path) ->
    <<"Use an absolute TMPDIR and run the check runner or rebar3 ct.">>;
hint(_) -> <<"Run the check runner or rebar3 ct to prepare an owned tmux sandbox.">>.

cleanup({Directory, Expected}) ->
    try
        check(same_directory(Directory, Expected), sandbox_directory_changed),
        case has_socket(Directory) of
            false ->
                check(same_directory(Directory, Expected), sandbox_directory_changed),
                file:del_dir_r(Directory);
            true -> {error, unretired_socket};
            {error, _} -> {error, cannot_inspect_directory}
        end
    catch throw:Reason -> {error, Reason}
    end.

same_directory(Directory, Expected) ->
    try identity(directory_info(Directory)) =:= Expected
    catch throw:_ -> false
    end.

identity(#file_info{type = Type, inode = Inode, major_device = Major, minor_device = Minor}) ->
    {Type, Major, Minor, Inode}.

has_socket(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            case file:list_dir(Path) of
                {ok, Names} -> lists:foldl(fun(Name, Acc) ->
                    case Acc of false -> has_socket(filename:join(Path, Name)); _ -> Acc end
                end, false, Names);
                Error -> Error
            end;
        {ok, #file_info{mode = Mode}} -> Mode band 8#170000 =:= 8#140000;
        {error, enoent} -> false;
        Error -> Error
    end.

finish({returned, Result}) -> Result;
finish({raised, Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack).

set_environment(Environment) ->
    lists:foreach(fun
        ({Name, false}) -> _ = os:unsetenv(Name);
        ({Name, Value}) -> true = os:putenv(Name, Value)
    end, Environment).
