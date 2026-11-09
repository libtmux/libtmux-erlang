-module(tmux_workspace_cli).
-moduledoc false.
-export([main/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    _ = logger:remove_handler(default),
    ok = logger:add_handler(default, logger_std_h,
        #{config => #{type => standard_error}}),
    ok = io:setopts(standard_io, [{encoding, unicode}]),
    Ref = make_ref(),
    ok = gen_event:add_handler(erl_signal_server, tmux_workspace_signal, {self(), Ref}),
    _ = gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
    ok = os:set_signal(sigterm, handle),
    Result = try dispatch(Args, Ref)
        catch
            throw:{workspace_error, Detail} -> failure(Detail);
            Class:_Reason:Stack ->
                {4, #{status => error, error => #{code => internal_error,
                    class => Class, location => location(Stack)}}}
        end,
    case Result of
        {help, Text} -> io:put_chars(standard_io, Text), erlang:halt(0);
        {Exit, Data} ->
            io:put_chars(standard_io, [tmux_workspace_wire:encode(safe(Data)), $\n]),
            erlang:halt(Exit)
    end.

dispatch(Args, Ref) ->
    Spec = spec(),
    case Args of
        [] -> {help, argparse:help(Spec, #{progname => "libtmux-workspace"})};
        ["--help"] -> {help, argparse:help(Spec, #{progname => "libtmux-workspace"})};
        [Command, "--help"] when Command =:= "plan"; Command =:= "apply" ->
            {help, argparse:help(Spec, #{progname => "libtmux-workspace", command => [Command]})};
        _ ->
            case argparse:parse(Args, Spec, #{progname => "libtmux-workspace"}) of
                {ok, Parsed, [_, Command], _} -> command(Command, Parsed, Ref);
                {error, _} -> failure(#{code => invalid_arguments});
                _ -> failure(#{code => missing_command})
            end
    end.

spec() ->
    #{help => "Plan and apply JSON workspaces through an explicitly configured tmux endpoint.",
      arguments => [#{name => config, long => "-config", type => binary,
                      help => "Trusted endpoint configuration (or LIBTMUX_WORKSPACE_CONFIG)"}],
      commands => #{
        "plan" => #{help => "Observe tmux and write a plan without mutations.", arguments => [
            #{name => source, type => binary},
            #{name => output, long => "-output", type => binary, required => true},
            #{name => adopt, long => "-adopt", type => binary, action => append, default => []},
            #{name => allow_shell, long => "-allow-shell", action => {store, true}, default => false}]},
        "apply" => #{help => "Execute the stored plan; stop on drift or uncertain outcomes.",
            arguments => [#{name => plan, type => binary}]}}}.

command(Command, Parsed, Ref) ->
    Config = config(Parsed),
    {Token, Input} = case Command of
        "plan" ->
            Workspace = unwrap(tmux_workspace:load(maps:get(source, Parsed))),
            {maps:get(endpoint, tmux_workspace:to_map(Workspace)), Workspace};
        "apply" ->
            LoadedPlan = unwrap(tmux_workspace_plan:read(maps:get(plan, Parsed))),
            {maps:get(<<"endpoint">>, tmux_workspace_plan:to_map(LoadedPlan)), LoadedPlan}
    end,
    Endpoint = endpoint(Token, Config),
    Shell = maps:get(<<"allowShell">>, Config, false),
    case Command =:= "plan" andalso maps:get(allow_shell, Parsed) andalso not Shell of
        true -> tmux_workspace_wire:fail(shell_not_allowed, []);
        false -> ok
    end,
    tmux_workspace_state:checkpoint(#{cancel => Ref}),
    scoped(tmux_workspace_runtime:run(fun() ->
        scoped(tmux_server:with_server(Endpoint, fun(Server) ->
            case Command of
                "plan" ->
                    Plan = unwrap(tmux_workspace_plan:new(maps:get(source, Parsed), Server,
                        #{adopt => maps:get(adopt, Parsed), cancel => Ref,
                          allow_shell => maps:get(allow_shell, Parsed)})),
                    ok = unwrap_ok(tmux_workspace_plan:write(Plan, maps:get(output, Parsed))),
                    Map = tmux_workspace_plan:to_map(Plan),
                    {0, #{status => planned, plan_hash => maps:get(<<"planHash">>, Map),
                        steps => length(maps:get(<<"steps">>, Map))}};
                "apply" ->
                    case tmux_workspace_apply:run(Input, Server,
                            #{allow_shell => Shell, cancel => Ref}) of
                        {ok, Receipt} -> {0, #{status => applied, result => Receipt}};
                        {error, Error} -> failure(Error)
                    end
            end
        end))
    end)).

config(Parsed) ->
    File = case maps:find(config, Parsed) of
        {ok, Path} -> Path;
        error -> case os:getenv("LIBTMUX_WORKSPACE_CONFIG") of
            false -> tmux_workspace_wire:fail(config_required, []);
            Value -> unicode:characters_to_binary(Value)
        end
    end,
    Config = tmux_workspace_wire:fields(tmux_workspace_wire:read(File),
        [<<"version">>, <<"endpoints">>, <<"allowShell">>], []),
    check(maps:get(<<"version">>, Config, none) =:= 1, invalid_config),
    check(is_boolean(maps:get(<<"allowShell">>, Config, false)), invalid_config),
    Endpoints = tmux_workspace_wire:require(<<"endpoints">>, Config, []),
    check(is_map(Endpoints) andalso map_size(Endpoints) =< 64, invalid_config),
    maps:foreach(fun(Key, _) -> endpoint(Key, Config) end, Endpoints), Config.

endpoint(Token, Config) ->
    _ = tmux_workspace_wire:text(Token, [<<"endpoint">>]),
    E = case maps:find(Token, maps:get(<<"endpoints">>, Config)) of
        {ok, Value} -> tmux_workspace_wire:fields(Value,
            [<<"socketPath">>, <<"executable">>], [<<"endpoints">>, Token]);
        error -> tmux_workspace_wire:fail(unknown_endpoint, [<<"endpoint">>])
    end,
    Socket = tmux_workspace_wire:require(<<"socketPath">>, E, []),
    absolute(Socket),
    case maps:find(<<"executable">>, E) of
        error -> #{socket_path => Socket};
        {ok, Executable} -> absolute(Executable),
            #{socket_path => Socket, executable => Executable}
    end.
absolute(Value) ->
    _ = tmux_workspace_wire:text(Value, []),
    check(filename:pathtype(Value) =:= absolute, invalid_config).

scoped({ok, Value}) -> Value;
scoped({error, Detail}) -> failure(Detail).
unwrap({ok, Value}) -> Value;
unwrap({error, Detail}) -> throw({workspace_error, Detail}).
unwrap_ok(ok) -> ok;
unwrap_ok({error, Detail}) -> throw({workspace_error, Detail}).
check(true, _) -> ok;
check(false, Code) -> tmux_workspace_wire:fail(Code, []).
failure(Detail) ->
    Code = maps:get(code, Detail, operational_error),
    Exit = case Code of
        plan_conflict -> 3;
        desired_input_changed -> 3;
        C when C =:= cancelled; C =:= scope_cleanup_failed;
               C =:= runtime_setup_failed; C =:= runtime_cleanup_failed -> 4;
        _ -> case maps:is_key(operation_outcome, Detail) orelse
                  maps:is_key(outcome, Detail) of
            true -> 4;
            false -> case lists:member(Code, [file_error, read_failed, write_failed,
                    server_unavailable, helper_unavailable, invalid_cli_archive,
                    invalid_cli_helper]) of true -> 4; false -> 2 end
        end
    end,
    {Exit, #{status => error, error => Detail}}.

%% Public core errors may carry opaque recovery handles or captured diagnostics.
%% Preserve JSON data and step receipts without printing closures or raw terms.
safe(M) when is_map(M) -> maps:map(fun(_, V) -> safe(V) end,
    maps:without([server, ownership, stdout, stderr, origin, stack], M));
safe(L) when is_list(L) -> [safe(V) || V <- L];
safe({exception, throw, {workspace_error, Detail}, _}) -> #{error => safe(Detail)};
safe({exception, Class, _, Stack}) -> #{class => Class, location => location(Stack)};
safe(T) when is_tuple(T) -> [safe(V) || V <- tuple_to_list(T)];
safe(V) when is_atom(V); is_binary(V); is_integer(V); is_float(V) -> V;
safe(_) -> redacted.
location([{M, F, A, Info} | _]) ->
    #{module => M, function => F, arity => case A of
        N when is_integer(N) -> N; L -> length(L) end,
      line => proplists:get_value(line, Info, 0)};
location(_) -> #{}.
