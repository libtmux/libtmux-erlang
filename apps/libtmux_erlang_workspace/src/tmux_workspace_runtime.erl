-module(tmux_workspace_runtime).
-moduledoc false.
-export([run/1]).

%% A Rebar3 archive can load BEAMs, but spawn_executable needs a real helper.
%% Only this standalone CLI's fresh VM changes the code path and logger.
-spec run(fun(() -> term())) -> {ok, term()} | {error, map()}.
run(Fun) ->
    Root = filename:join(temp(), "libtmux-workspace-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16), lowercase))),
    case file:make_dir(Root) of
        {error, Errno} -> {error, #{code => runtime_setup_failed, reason => Errno}};
        ok ->
            App = filename:join(Root, "libtmux_erlang"),
            Ebin = filename:join(App, "ebin"),
            tmux_scope:run(fun() ->
                require(file:change_mode(Root, 8#700)),
                materialize(App, Ebin),
                true = code:add_patha(Ebin),
                require(application:ensure_all_started(libtmux_erlang_workspace)),
                Fun()
            end, fun() -> cleanup(Ebin, Root) end)
    end.

materialize(App, Ebin) ->
    {ok, Sections} = escript:extract(escript:script_name(), []),
    {archive, Archive} = lists:keyfind(archive, 1, Sections),
    Files = ["ebin/libtmux_erlang.app", "priv/tmux_owned_io",
        "priv/owned_io.LICENSE", "priv/owned_io.provenance.json"],
    Prefix = "libtmux_erlang/",
    {ok, Members} = zip:extract(Archive, [memory,
        {file_list, [Prefix ++ F || F <- Files]}]),
    {_, Provenance} = lists:keyfind(Prefix ++ "priv/owned_io.provenance.json", 1, Members),
    {ok, Manifest} = tmux_json:decode(Provenance),
    {_, License} = lists:keyfind(Prefix ++ "priv/owned_io.LICENSE", 1, Members),
    LicenseHash = binary:encode_hex(crypto:hash(sha256, License), lowercase),
    ValidLicense = lists:any(fun
        (#{<<"source">> := <<"LICENSE">>, <<"sha256">> := Hash}) -> Hash =:= LicenseHash;
        (_) -> false
    end, maps:get(<<"files">>, Manifest, [])),
    Protocol = lists:any(fun
        (#{<<"protocol_version">> := 4}) -> true;
        (_) -> false
    end, maps:get(<<"source_changes">>, Manifest, [])),
    case ValidLicense andalso Protocol of
        true -> ok;
        false -> tmux_workspace_wire:fail(invalid_cli_archive, [])
    end,
    require(file:make_dir(App)), require(file:make_dir(Ebin)),
    require(file:make_dir(filename:join(App, "priv"))),
    lists:foreach(fun(F) ->
        case lists:keyfind(Prefix ++ F, 1, Members) of
            {_, Bytes} when byte_size(Bytes) =< 1048576 ->
                require(file:write_file(filename:join(App, F), Bytes, [exclusive]));
            _ -> tmux_workspace_wire:fail(invalid_cli_archive, [])
        end
    end, Files),
    Helper = filename:join(App, "priv/tmux_owned_io"),
    {_, Bundled} = lists:keyfind(Prefix ++ "priv/tmux_owned_io", 1, Members),
    {ok, Actual} = file:read_file(Helper),
    case crypto:hash(sha256, Bundled) =:= crypto:hash(sha256, Actual) of
        true -> require(file:change_mode(Helper, 8#700));
        false -> tmux_workspace_wire:fail(invalid_cli_helper, [])
    end.

cleanup(Ebin, Root) ->
    Stops = [stop(libtmux_erlang_workspace), stop(libtmux_erlang)],
    _ = code:del_path(Ebin),
    Removed = file:del_dir_r(Root),
    case {Stops, Removed} of
        {[ok, ok], ok} -> ok;
        _ -> {error, #{code => runtime_cleanup_failed,
                      applications => Stops, directory => Removed}}
    end.

stop(App) ->
    case application:stop(App) of
        ok -> ok;
        {error, {not_started, App}} -> ok;
        {error, Reason} -> {error, Reason}
    end.
temp() -> case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end.
require(ok) -> ok;
require({ok, _}) -> ok;
require({error, Reason}) ->
    throw({workspace_error, #{code => runtime_setup_failed, reason => Reason}}).
