-module(tmux_program).
-moduledoc """
Run an application in a PTY on a private tmux server.

Pass an absolute path to tmux and a list of binary arguments starting with
the application's absolute path. Releases from tmux 3.8 support the history
counters used in the result. Check the minimum with
`tmux_capability:describe/1` and the feature `program_history`.

`run/3` starts, awaits and releases the program. Use `start/3` when you need
to send input, wait from more than one process or request an early stop.
The caller that starts the program owns its lifetime.

See [Run a program in a private terminal](programs.md) for an executable
example, capture limits and cleanup recovery.
""".
-include_lib("kernel/include/file.hrl").
-export([start/3, run/3, await_started/2, await/2, send_text/2, stop/1, release/1]).
-export([submit_input/2]).
-export_type([t/0, options/0, result/0, capture/0, history/0]).
-doc "A handle for one owned program and its retained result.".
-opaque t() :: tmux_program_owner:t().

-doc "Resource limits and environment for an owned launch.".
-type options() :: #{cwd => binary(), env => #{binary() => binary()},
    width => 1..65535, height => 1..65535, history_lines => 0..65535,
    max_bytes => 1..262144, deadline_ms => 1..600000}.

-doc "The tmux history size, limit, line counters and generation.".
-type history() :: #{size := non_neg_integer(), limit := non_neg_integer(),
    added := non_neg_integer(), collected := non_neg_integer(), generation := non_neg_integer()}.

-doc "The verified application exit, rendered terminal bytes and cleanup receipt.".
-type capture() :: #{exit := tmux_pane:exit(), screen := binary(), encoding := terminal_bytes,
    history := history(), pending_bytes := non_neg_integer(), cleanup := complete}.

-doc "A completed capture or a structured failure. A nonzero exit can have a complete capture.".
-type result() :: {ok, capture()} | {error, map()}.

-doc "Start a private terminal, await its result and release the result handle.".
-spec run(binary(), [binary()], options()) -> result().
run(Executable, Argv, Options) ->
    maybe
        {ok, Program} ?= start(Executable, Argv, Options),
        try await(Program, infinity)
        after _ = release(Program)
        end
    end.

-doc """
Admit a run and return its handle while native setup continues.
The deadline covers setup, execution and capture. Cleanup is collected
separately. Eight program slots are shared across each Erlang node.
""".
-spec start(binary(), [binary()], options()) -> {ok, t()} | {error, map()}.
start(Executable, Argv, Options) ->
    maybe
        {ok, #{deadline := Deadline} = Config} ?= prepare(Executable, Argv, Options, now_ms()),
        case application:ensure_all_started(libtmux_erlang) of
            {ok, _} -> tmux_program_owner:start(Deadline, fun(Context) -> execute(Config, Context) end);
            {error, _} -> {error, #{code => application_unavailable, outcome => not_started}}
        end
    end.

-doc "Wait for the launch gate to open. Use `await/2` for the application result.".
-spec await_started(t(), timeout()) -> {ok, #{state := released}} | {error, map()}.
await_started(Program, Timeout) -> tmux_program_owner:request(Program, started, Timeout).

-doc "Wait for the result and cleanup receipt. An `await_timeout` leaves the run active.".
-spec await(t(), timeout()) -> result().
await(Program, Timeout) -> tmux_program_owner:request(Program, await, Timeout).

-doc """
Send up to 2,000 literal input bytes to the live program. The program's terminal
settings govern how it reads the bytes. A second input request returns
`program_input_busy` while the first occupies the input slot.
""".
-spec send_text(t(), binary()) -> {ok, #{bytes := non_neg_integer()}} | {error, map()}.
send_text(Program, Text) ->
    tmux_program_owner:send_text(Program, Text).

-doc "Request stop. Use `await/2` to collect the outcome and confirm retirement.".
-spec stop(t()) -> {ok, stop_requested | already_completed} | {error, map()}.
stop(Program) -> tmux_program_owner:request(Program, stop, 900).

-doc "Discard a completed result. Native resources with unconfirmed retirement keep their slot.".
-spec release(t()) -> ok | {error, map()}.
release(Program) -> tmux_program_owner:request(Program, release, 900).

execute(#{executable := Executable} = Config, Context) ->
    maybe
        ok ?= require_client(Config, Context),
        {ok, TimeLeft} ?= remaining(Config),
        Options = #{executable => Executable, startup_timeout_ms => min(TimeLeft, 900)},
        {ok, Ownership} ?= permit(allocate, Options, Config, Context),
        {ok, StartupTime} ?= remaining(Config),
        {ok, Server, Ownership} ?= tmux_owned_server:await_ready(Ownership, min(StartupTime, 900)),
        run_owned(Server, Config, Context)
    end.

permit(Stage, Detail, Config, {Controller, Token}) ->
    maybe
        {ok, TimeLeft} ?= remaining(Config),
        Controller ! {Token, self(), permit, Stage, Detail},
        receive
            {Token, Stage, Decision} -> Decision
        after TimeLeft -> {error, #{code => deadline}}
        end
    end.

prepare(<<"/", _/binary>> = Executable, [<<"/", _/binary>> | _] = Argv, Options, Started)
  when is_map(Options) ->
    Defaults = #{width => 80, height => 24, env => #{}, history_lines => 1000,
                 max_bytes => 65536, deadline_ms => 30000},
    Allowed = [cwd | maps:keys(Defaults)],
    Config = maps:merge(Defaults, Options),
    #{width := Width, height := Height, history_lines := History,
      max_bytes := Bytes, deadline_ms := Deadline} = Config,
    maybe
        true ?= maps:without(Allowed, Options) =:= #{},
        true ?= is_integer(Width, 1, 65535) andalso is_integer(Height, 1, 65535)
            andalso is_integer(History, 0, 65535) andalso Width * (Height + History) =< 1048576
            andalso is_integer(Bytes, 1, 262144) andalso is_integer(Deadline, 1, 600000),
        {ok, Flags} ?= tmux_args:options(maps:with([width, height, env], Config),
            [{width, dimension, <<"-x">>}, {height, dimension, <<"-y">>},
             {env, environment, <<"-e">>}]),
        {ok, Cwd} ?= directory(maps:get(cwd, Config, default)),
        {ok, Helper} ?= helper(),
        Tag = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
        Run = #{executable => Executable, argv => Argv, flags => Flags, cwd => Cwd,
                history_lines => History, max_bytes => Bytes, helper => Helper,
                channel => <<"libtmux-program-", Tag/binary>>,
                diagnostic => <<"@libtmux-program-report-", Tag/binary>>,
                deadline => Started + Deadline},
        {ok, _} ?= spawn_command(binary:copy(<<"s">>, 99), Run),
        {ok, Run#{executable := binary:copy(Executable), cwd := binary:copy(Cwd),
                  argv := [binary:copy(Arg) || Arg <- Argv],
                  flags := [binary:copy(Flag) || Flag <- Flags]}}
    else
        false -> {error, #{code => invalid_program_options}};
        {error, _} = Error -> Error
    end;
prepare(_, _, _, _) -> {error, #{code => invalid_program_launch}}.

directory(default) ->
    case file:get_cwd() of
        {ok, Path} -> directory(unicode:characters_to_binary(Path));
        {error, Reason} -> {error, #{code => invalid_program_directory, reason => Reason}}
    end;
directory(<<"/", _/binary>> = Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> {ok, Path};
        {ok, _} -> {error, #{code => invalid_program_directory, reason => enotdir}};
        {error, Reason} -> {error, #{code => invalid_program_directory, reason => Reason}}
    end;
directory(_) -> {error, #{code => invalid_program_directory}}.

helper() ->
    case code:priv_dir(libtmux_erlang) of
        {error, _} -> {error, #{code => application_unavailable}};
        Priv -> {ok, unicode:characters_to_binary(filename:absname(filename:join(Priv, "tmux_owned_io")))}
    end.

require_client(#{executable := Executable} = Config, Context) ->
    maybe
        {ok, TimeLeft} ?= remaining(Config),
        {ok, #{exit_status := 0, stdout := Output}} ?=
            permit(probe_version, {Executable, min(900, TimeLeft)}, Config, Context),
        {ok, Version} ?= tmux_version:parse(Output),
        tmux_capability:require(Version, program_history)
    else
        {ok, Result} -> {error, Result#{code => program_client_probe_failed}};
        {error, _} = Error -> Error
    end.

run_owned(Server, #{history_lines := History} = Config, Context) ->
    maybe
        {ok, Version} ?= tmux_server:version(Server),
        ok ?= tmux_capability:require(Version, program_history),
        {ok, #{endpoint := #{socket_path := Path}}} ?= tmux_server:observation_context(Server),
        {ok, _} ?= tmux_option:set({session_defaults, Server}, <<"history-limit">>, integer_to_binary(History)),
        {ok, _} ?= tmux_option:set({window_defaults, Server}, <<"remain-on-exit">>, <<"on">>),
        {ok, _} ?= tmux_option:set({window_defaults, Server}, <<"remain-on-exit-format">>, <<>>),
        {ok, Spawn} ?= spawn_command(Path, Config),
        {ok, #{stdout := Spawned}} ?= submit(Server, Spawn, Config, 64),
        {ok, Target} ?= program_target(Server, Spawned, Config),
        hold_terminal(Target, Config, Context)
    end.

hold_terminal(#{tty := Tty} = Target, #{helper := Helper, deadline := Deadline} = Config,
              {_, Token} = Context) ->
    ReadyBy = min(Deadline, now_ms() + 900),
    maybe
        {ok, Startup} ?= remaining(#{deadline => ReadyBy}),
        {ok, Holder} ?= permit(hold_terminal, {Helper, Tty, Startup}, Config, Context),
        {ok, Pin} ?= await_terminal(Holder, Token, ReadyBy),
        run_program(Target, Pin, Config, Context)
    end.

await_terminal(Holder, Token, ReadyBy) ->
    receive
        {Token, Holder, ok} ->
            maybe
                {ok, #{phase := running, child_pid := Pid}} ?= tmux_transport:status(Holder),
                {ok, Identity} ?= tmux_identity:observe(Pid),
                {ok, {Pid, Identity}}
            else
                _ -> {error, #{code => program_terminal_unavailable}}
            end;
        {Token, Holder, {error, _} = Error} -> Error
    after max(0, ReadyBy - now_ms()) ->
        {error, #{code => program_terminal_unavailable}}
    end.

run_program(#{pane := Pane} = Target, Pin, Config, Context) ->
    Start = fun() -> release_gate(Target, Config, Context) end,
    maybe
        {ok, TimeLeft} ?= remaining(Config),
        {ok, #{exit := Outcome}} ?= tmux_pane:wait_exit(Pane, #{deadline_ms => TimeLeft}, Start),
        finish(Target, Pin, Outcome, Config)
    end.

release_gate(Target, #{channel := Channel} = Config, {Controller, Token} = Context) ->
    maybe
        {ok, Release} ?= tmux_command:wait_for(Channel, signal),
        ok ?= permit(release, none, Config, Context),
        ok ?= program_action(Target, Release, Config),
        Controller ! {Token, self(), started, Target},
        ok
    end.

spawn_command(Socket, #{helper := Helper, cwd := Cwd, executable := Executable,
    channel := Channel, diagnostic := ErrorOption, argv := Argv, flags := Flags}) ->
    Launch = [Helper, <<"--exec-program">>, Executable, Socket, Channel, Cwd, ErrorOption | Argv],
    Format = <<"#{pane_id}\t#{pane_pid}\t#{pid}\t#{pane_tty}">>,
    tmux_command:raw(<<"new-session">>, [<<"-d">>, <<"-P">>, <<"-F">>, Format,
        <<"-s">>, <<"program">>] ++ Flags ++ [<<"--">> | Launch]).

program_target(Server, Spawned, Config) ->
    maybe
        [Id, PidBytes, Daemon, <<"/dev/pts/", _/binary>> = Tty] ?=
            binary:split(string:trim(Spawned), <<"\t">>, [global]),
        {ok, Pane} ?= tmux_pane:get(Server, Id),
        Pid = tmux_model:get(pid, Pane),
        true ?= is_integer(Pid) andalso Pid > 0,
        PidBytes ?= integer_to_binary(Pid),
        {ok, Identity} ?= tmux_identity:observe(Pid),
        {ok, #{server => Server, pane => Pane, identity => Identity,
               daemon => Daemon, tty => Tty, deadline => maps:get(deadline, Config)}}
    else
        {error, _} = Error -> Error;
        _ -> {error, #{code => program_generation_changed}}
    end.

-doc false.
-spec submit_input(map(), binary()) -> {ok, #{bytes := non_neg_integer()}} | {error, map()}.
submit_input(#{pane := Pane, deadline := Deadline} = Target, Text) ->
    Id = tmux_model:get(id, Pane),
    maybe
        {ok, Hex} ?= tmux_pane:literal_keys(Text),
        {ok, Send} ?= tmux_command:raw(<<"send-keys">>, [<<"-t">>, Id, <<"-H">>, <<"--">> | Hex]),
        ok ?= program_action(Target, Send, #{deadline => Deadline}),
        {ok, #{bytes => byte_size(Text)}}
    end.

program_action(#{server := Server, pane := Pane, identity := Identity,
                 daemon := Daemon, tty := Tty}, Effect, Config) ->
    Pid = tmux_model:get(pid, Pane),
    Id = tmux_model:get(id, Pane),
    PidBytes = integer_to_binary(Pid),
    Live = <<"#{&&:#{==:#{pane_pid},", PidBytes/binary, "},#{==:#{pane_dead},0}}">>,
    SamePane = <<"#{&&:#{==:#{pane_tty},", Tty/binary, "},#{==:#{pane_id},", Id/binary, "}}">>,
    Condition = <<"#{&&:#{==:#{pid},", Daemon/binary, "},#{&&:", SamePane/binary, ",", Live/binary, "}}">>,
    maybe
        ok ?= live_program(Identity, Pid),
        {ok, Marker} ?= tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"applied">>]),
        {ok, Action} ?= tmux_command:to_config([Effect, Marker]),
        {ok, Command} ?= tmux_command:raw(<<"if-shell">>,
            [<<"-F">>, <<"-t">>, Id, <<"--">>, Condition, Action]),
        {ok, #{stdout := Response}} ?= submit(Server, Command, Config, 32),
        case Response of
            <<"applied\n">> -> ok;
            <<>> -> {error, #{code => program_generation_changed, outcome => not_started}};
            _ -> {error, #{code => program_action_unconfirmed, outcome => unknown}}
        end
    end.

live_program(Identity, Pid) ->
    case tmux_identity:check(Identity, Pid) of
        ok -> ok;
        {error, #{code := stale_server}} -> {error, #{code => program_generation_changed, outcome => not_started}};
        {error, _} = Error -> Error
    end.

finish(#{server := Server, pane := Pane, daemon := Daemon, tty := Tty}, {Holder, Identity},
       Outcome, #{diagnostic := <<"@", Channel/binary>> = Option, max_bytes := Limit} = Config) ->
    Id = tmux_model:get(id, Pane),
    PendingLimit = min(Limit, 4096),
    Metadata = <<"#{pane_id}\t#{pid}\t#{pane_tty}\t#{pane_dead}\t",
        "#{pane_dead_status}\t#{pane_dead_signal}\t#{", Option/binary, "}\t",
        "#{history_size}\t#{history_limit}\t#{history_added}\t#{history_collected}\t#{history_generation}">>,
    MissingReport = <<"#{&&:#{==:#{pane_tty},", Tty/binary, "},#{==:#{", Option/binary, "},}}">>,
    maybe
        {ok, Wait} ?= tmux_command:wait_for(Channel, wait),
        {ok, WaitAction} ?= tmux_command:to_config(Wait),
        {ok, Report} ?= tmux_command:raw(<<"if-shell">>,
            [<<"-F">>, <<"-t">>, Id, <<"--">>, MissingReport, WaitAction]),
        {ok, Read} ?= tmux_command:raw(<<"display-message">>,
            [<<"-p">>, <<"-t">>, Id, <<"-F">>, Metadata]),
        {ok, Pending} ?= tmux_command:raw(<<"capture-pane">>,
            [<<"-p">>, <<"-P">>, <<"-C">>, <<"-t">>, Id]),
        {ok, Display} ?= tmux_command:raw(<<"capture-pane">>,
            [<<"-p">>, <<"-t">>, Id, <<"-S">>, <<"-">>]),
        {ok, Command} ?= tmux_command:sequence([Report, Read, Pending, Display]),
        {ok, Output} ?= capture_output(submit(Server, Command, Config, Limit + 4 * PendingLimit + 256)),
        ok ?= held_terminal(Identity, Holder),
        capture_result(Output, {Id, Daemon, Tty}, Outcome, Limit, PendingLimit)
    end.

held_terminal(Identity, Pid) ->
    case tmux_identity:check(Identity, Pid) of
        ok -> ok;
        {error, _} -> {error, #{code => program_terminal_unavailable}}
    end.

capture_output({ok, #{stdout := Output}}) -> {ok, {complete, Output}};
capture_output({error, #{code := output_limit, stream := stdout, stdout := Prefix}}) ->
    {ok, {limited, Prefix}};
capture_output({error, Error}) -> {error, maps:remove(stdout, Error)}.

capture_result({State, Output}, Target, Outcome, Limit, PendingLimit) ->
    maybe
        [Header, Rest] ?= binary:split(Output, <<"\n">>),
        {ok, Meta} ?= capture_header(Header, Target, Outcome),
        capture_body(binary:split(Rest, <<"\n">>), State, Meta, Limit, PendingLimit)
    else
        {error, _} = Error -> Error;
        _ -> {error, #{code => invalid_program_capture}}
    end.

capture_header(Header, {Id, Daemon, Tty}, Outcome) ->
    case binary:split(Header, <<"\t">>, [global]) of
        [Id, Daemon, Tty, <<"1">>, Status, Signal, Error | Counters] ->
            case matches_exit(Outcome, Status, Signal) of
                true -> capture_metadata(Outcome, Error, Counters);
                false -> {error, #{code => program_generation_changed}}
            end;
        _ -> {error, #{code => program_generation_changed}}
    end.

capture_body([Pending, Bytes], State, Metadata, Limit, PendingLimit) ->
    PendingBytes = count_pending(Pending, 0),
    Meta = Metadata#{pending_bytes => PendingBytes},
    if
        PendingBytes > PendingLimit -> output_limit(pending, PendingLimit, Meta);
        State =:= limited orelse byte_size(Bytes) > Limit -> output_limit(stdout, Limit, Meta);
        true -> {ok, Meta#{screen => binary:copy(Bytes)}}
    end;
capture_body([_], limited, Meta, _, PendingLimit) ->
    output_limit(pending, PendingLimit, Meta);
capture_body(_, complete, _, _, _) ->
    {error, #{code => invalid_program_capture}}.

output_limit(Stream, Limit, Metadata) ->
    {error, Metadata#{code => output_limit, stream => Stream, limit => Limit}}.

%% tmux escapes control bytes and backslashes as three octal digits.
count_pending(<<$\\, A, B, C, Rest/binary>>, Count)
  when A >= $0, A =< $3, B >= $0, B =< $7, C >= $0, C =< $7 ->
    count_pending(Rest, Count + 1);
count_pending(<<_, Rest/binary>>, Count) -> count_pending(Rest, Count + 1);
count_pending(<<>>, Count) -> Count.

capture_metadata({status, 125}, <<Stage, Raw/binary>>, _) when byte_size(Raw) > 0 ->
    try binary_to_integer(Raw) of
        Errno ->
            {error, #{code => program_launch_failed, stage => launch_stage(Stage), errno => Errno}}
    catch error:badarg -> {error, #{code => invalid_program_capture}}
    end;
capture_metadata(Outcome, <<"S">>, [_, _, _, _, _] = Counters) ->
    try lists:map(fun binary_to_integer/1, Counters) of
        [Size, Max, Added, Collected, Generation] ->
            {ok, #{exit => Outcome, encoding => terminal_bytes,
                history => #{size => Size, limit => Max, added => Added,
                             collected => Collected, generation => Generation}}}
    catch error:badarg -> {error, #{code => invalid_program_capture}}
    end;
capture_metadata(_, <<>>, _) -> {error, #{code => program_launch_unverified}};
capture_metadata(_, _, _) -> {error, #{code => invalid_program_capture}}.

launch_stage($G) -> gate;
launch_stage($D) -> cwd;
launch_stage($X) -> exec;
launch_stage($B) -> acknowledgement;
launch_stage(_) -> unknown.

matches_exit({status, Code}, Status, <<>>) -> integer_to_binary(Code) =:= Status;
matches_exit({signal, Number}, <<>>, Signal) when is_integer(Number) ->
    integer_to_binary(Number) =:= Signal;
matches_exit({signal, Signal}, <<>>, Signal) when is_binary(Signal) -> true;
matches_exit(_, _, _) -> false.

submit(Server, Command, #{deadline := Deadline}, Limit) ->
    maybe
        {ok, Operation} ?= tmux_operation:start_before(Server, Command,
            #{max_stdout => Limit, max_stderr => 4096}, Deadline),
        case tmux_operation:await(Operation, max(0, Deadline - now_ms())) of
            {ok, _} = Success -> Success;
            {error, #{code := await_timeout}} ->
                _ = tmux_operation:cancel(Operation),
                {error, #{code => deadline, outcome => unknown}};
            {error, Error} -> {error, Error}
        end
    end.

remaining(#{deadline := Deadline}) ->
    case Deadline - now_ms() of
        Time when Time > 0 -> {ok, Time};
        _ -> {error, #{code => deadline}}
    end.

now_ms() -> erlang:monotonic_time(millisecond).
