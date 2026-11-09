-module(native_consumer).
-moduledoc """
Construct native values and exercise a borrowed endpoint through public APIs.

Run through tools/check_package.py to compile this module against an unpacked
OTP application archive outside the library checkout.
""".
-export([run/0, pane_ids/1, run_endpoint/2]).
-import_record(tmux_model, [pane]).

-doc """
Return pane IDs from an ordinary list of validated domain records.

```erlang
1> native_consumer:pane_ids([]).
[]
```
""".
-spec pane_ids([tmux_model:pane()]) -> [tmux_model:pane_id()].
pane_ids(Rows) ->
    [Id || #pane{id = Id} <:- Rows].

-spec run() -> ok.
run() ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    tmux_scope:run_or_error(fun() ->
        {ok, Pane} = tmux_model:pane(#{id => <<"%1">>, active => true,
            width => 120, current_command => <<"vim">>}),
        [<<"%1">>] = pane_ids([Pane]),
        #pane{id = <<"%1">>, active = true, width = 120} = Pane,
        {ok, Pane} = tmux_model:validate(Pane),
        {error, #{code := invalid_row}} =
            tmux_model:validate(Pane#pane{model_version = 1}),
        Selection = tmux_select:from_list(pane, [Pane]),
        {ok, Pane} = tmux_select:one(#{width => #{gte => 120}}, Selection),
        {ok, Regex} = tmux_filter:new(pane, #{current_command => #{regex => #{
            pattern => <<"^(vim|nvim)$">>, dialect => portable_v1}}}),
        {ok, Regex} = tmux_filter:from_wire(pane, tmux_filter:to_wire(Regex)),
        {ok, Pane} = tmux_select:one(Regex, Selection),
        {error, #{code := duplicate_key}} =
            tmux_filter:decode_json(<<"{\"version\":1,\"version\":2}">>),
        {ok, Floor} = tmux_version:parse(<<"tmux 3.3">>),
        {ok, #{argument_spec := KeyFlags}} =
            tmux_capability:command(Floor, <<"send-keys">>),
        nomatch = binary:match(KeyFlags, <<"K">>),
        ok = tmux_capability:require(Floor, native_list_filter),
        {error, #{code := unsupported_capability}} =
            tmux_capability:require(Floor, layout_json),
        ok = ct_doctest:module(?MODULE),
        ok
    end, fun() ->
        ok = application:stop(libtmux_erlang)
    end).

-spec run_endpoint(binary(), binary()) -> ok.
run_endpoint(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    tmux_scope:run_or_error(fun() ->
        {ok, Message} = tmux_command:raw(<<"display-message">>,
                                        [<<"-p">>, <<"archive consumer">>]),
        {ok, #{stdout := <<"archive consumer\n">>, cleanup := complete}} =
            tmux_server:command(Server, Message, #{}),
        {ok, Wait} = tmux_command:wait_for(<<"archive-consumer">>, wait),
        {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
        {ok, _} = tmux_operation:await_started(Operation, 900),
        {error, #{code := await_timeout}} = tmux_operation:await(Operation, 0),
        {ok, cancel_requested} = tmux_operation:cancel(Operation),
        {error, #{outcome := unknown, cleanup := complete}} =
            tmux_operation:await(Operation, 900),
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"archive-domain">>,
              cwd => filename:dirname(Socket),
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            SessionId0 = tmux_model:get(id, Session),
            ClientEndpoint = #{socket => Socket, executable => Executable},
            tmux_test_fixture:with_client(ClientEndpoint, SessionId0, [],
                fun(Client) ->
                    #{name := ClientName} = Client,
                    {ok, Destination} = tmux_session:create(Server,
                        #{name => <<"archive-client">>,
                          launch => #{argv => [<<"/bin/cat">>]}}),
                    tmux_scope:run_or_error(fun() ->
                        {ok, _} = tmux_session:select(Destination, ClientName),
                        {ClientName, DestinationId} =
                            tmux_test_fixture:client_session(Client),
                        DestinationId = tmux_model:get(id, Destination),
                        {ok, _} = tmux_session:select(Session, ClientName,
                            #{update_environment => false}),
                        {ClientName, SessionId0} =
                            tmux_test_fixture:client_session(Client)
                    end, fun() ->
                        {ok, _} = tmux_session:kill(Destination),
                        ok
                    end)
                end),
            {ok, _} = tmux_session:rename(Session, <<"archive-#{pid};">>),
            {ok, Renamed} = tmux_session:get(Server, SessionId0),
            <<"archive-#{pid};">> = tmux_model:get(name, Renamed),
            {ok, Window} = tmux_window:create(
                Session, #{launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, _} = tmux_option:set(Session, <<"@workspace">>, <<"archive">>),
            {ok, <<"archive">>} = tmux_option:get(
                Session, <<"@workspace">>, #{}),
            {ok, _} = tmux_option:set(
                Session, {<<"update-environment">>, 0}, <<>>),
            {ok, #{0 := <<>>}} = tmux_option:get(
                Session, <<"update-environment">>, #{}),
            {ok, _} = tmux_option:unset(Session, <<"update-environment">>),
            none = tmux_option:get(Session, <<"update-environment">>, #{}),
            {ok, _} = tmux_window:respawn(Window, #{force => true}),
            {ok, Pane} = tmux_pane:split(Window,
                #{direction => horizontal, size => {percent, 40},
                  launch => #{shell => <<>>}}),
            [Id] = pane_ids([Pane]),
            {ok, Detached} = tmux_model:pane(#{id => Id}),
            {ok, Bound} = tmux_server:bind(Server, Detached),
            {ok, _} = tmux_window:select_layout(Window, even_horizontal),
            {ok, _} = tmux_pane:resize(Pane, #{width => 24}),
            {ok, Geometry} = tmux_pane:get(Server, Id),
            24 = tmux_model:get(width, Geometry),
            {ok, <<"\n">>} = tmux_pane:capture(
                Bound, #{start => 0, 'end' => 0}),
            {ok, _} = tmux_window:rename(Window, <<"consumer-#{pane_id};">>),
            {ok, Current} = tmux_window:get(Server, tmux_model:get(id, Window)),
            <<"consumer-#{pane_id};">> = tmux_model:get(name, Current),
            OriginalLayout = tmux_model:get(layout, Current),
            {ok, Version} = tmux_server:version(Server),
            case tmux_version:at_least(Version, {3, 8}) of
                true ->
                    {ok, #{<<"V">> := 2, <<"L">> := LayoutRoot}} =
                        tmux_json:decode(OriginalLayout),
                    true = is_map(LayoutRoot);
                false -> ok
            end,
            {ok, _} = tmux_window:select_layout(Window, tiled),
            {ok, _} = tmux_window:select_layout(Window, OriginalLayout),
            {ok, RestoredWindow} =
                tmux_window:get(Server, tmux_model:get(id, Window)),
            OriginalLayout = tmux_model:get(layout, RestoredWindow),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            #{server_instance := Instance} = tmux_snapshot:metadata(Snapshot),
            {ok, InstanceKey} = tmux_identity:fingerprint(Instance),
            {ok, #{<<"instance">> := InstanceKey}} = tmux_json:decode(
                iolist_to_binary(json:encode(#{instance => InstanceKey}))),
            {ok, CatPane} = tmux_select:one(
                #{window_id => tmux_model:get(id, Window),
                  pid => #{present => true}}, tmux_select:panes(Snapshot)),
            Buffer = <<"archive-buffer">>,
            Artifact = <<0, 255, "\n%end 1 2 3\n">>,
            {ok, _} = tmux_buffer:load(Server, Buffer, Artifact),
            {ok, Artifact} = tmux_buffer:show(Server, Buffer),
            {ok, [#{name := Buffer}]} = tmux_buffer:list(Server),
            {ok, _} = tmux_buffer:rename(Server, Buffer, <<"archive-saved">>),
            {error, #{code := buffer_not_found}} =
                tmux_buffer:show(Server, Buffer),
            {ok, _} = tmux_buffer:load(Server, <<"archive-input">>,
                <<"archive paste\n">>),
            {ok, _} = tmux_buffer:paste(CatPane, <<"archive-input">>,
                #{delete => true}),
            {error, #{code := buffer_not_found}} =
                tmux_buffer:show(Server, <<"archive-input">>),
            {ok, _} = tmux_buffer:delete(Server, <<"archive-saved">>),
            {ok, Source} = tmux_select:one(
                #{window_id => tmux_model:get(id, Window)},
                tmux_select:window_links(Snapshot)),
            {ok, _} = tmux_pane:break(Pane, Source, Session, #{index => 20}),
            {ok, _} = tmux_pane:join(Pane, CatPane, #{}),
            {ok, _} = tmux_pane:move(Pane, CatPane, #{before => true}),
            {ok, _} = tmux_pane:swap(Pane, CatPane, #{}),
            {ok, _} = tmux_window_link:link(Source, Session, #{index => 9}),
            SessionId = tmux_model:get(id, Session),
            {ok, Duplicate} = tmux_window_link:get(Server, SessionId, 9),
            {ok, _} = tmux_window_link:move(Duplicate, Session, #{index => 11}),
            {ok, Moved} = tmux_window_link:get(Server, SessionId, 11),
            {ok, _} = tmux_window_link:swap(Source, Moved, #{}),
            {ok, _} = tmux_window_link:select(Moved),
            {ok, _} = tmux_window_link:unlink(Moved, #{force => true}),
            {error, #{code := stale_link}} = tmux_window_link:select(Moved),
            {ok, _} = tmux_window:get(Server, tmux_model:get(id, Window)),
            {ok, CapturedWindow} = tmux_snapshot:get(
                window, tmux_model:get(id, Window), Snapshot),
            {ok, Children} = tmux_snapshot:related(
                panes, CapturedWindow, Snapshot),
            true = lists:member(Id, pane_ids(Children)),
            ok = tmux_snapshot:require(
                [{relation, window, panes}, {field, pane, pid}], Snapshot),
            {ok, Filter} = tmux_filter:new(pane, #{id => Id,
                window => #{is => #{name => <<"consumer-#{pane_id};">>}}}),
            {ok, Document} = tmux_filter:decode_json(
                iolist_to_binary(json:encode(tmux_filter:to_wire(Filter)))),
            {ok, Filter} = tmux_filter:from_wire(pane, Document),
            {ok, Selected} = tmux_select:one(
                Filter, tmux_select:panes(Snapshot)),
            [Id] = pane_ids([Selected]),
            {ok, Prepared} = tmux_filter:prepare(Filter, Snapshot),
            {ok, true} = tmux_filter:matches(Prepared, Selected),
            Query = tmux_query:pushdown(true,
                tmux_query:where(Filter, tmux_query:panes(Server))),
            #{candidate := #{exact := false}} = tmux_query:explain(Query),
            {ok, Fetched} = tmux_query:fetch(Query),
            [Id] = pane_ids(tmux_select:to_list(Fetched)),
            #{query := #{candidate_count := 1, pushed_down := true}} =
                tmux_select:summary(Fetched),
            {ok, InputWindow} = tmux_window:create(Session,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            InputWindowId = tmux_model:get(id, InputWindow),
            {ok, InputSnapshot} = tmux_server:snapshot(Server),
            {ok, InputPane} = tmux_select:one(#{window_id => InputWindowId},
                tmux_select:panes(InputSnapshot)),
            {ok, _} = tmux_pane:split(InputPane,
                #{launch => #{shell => <<>>}}),
            {ok, _} = tmux_option:set(
                InputWindow, <<"remain-on-exit">>, <<"on">>),
            {ok, _} = tmux_option:set(
                InputWindow, <<"remain-on-exit-format">>, <<>>),
            {ok, DoneSignal} = tmux_command:wait_for(
                <<"archive-input-complete">>, signal),
            {ok, _} = tmux_hook:set(InputWindow,
                {<<"pane-died">>, 0}, DoneSignal),
            {ok, InputWait} = tmux_command:wait_for(
                <<"archive-input-complete">>, wait),
            {ok, InputOperation} = tmux_operation:start(Server, InputWait, #{}),
            tmux_scope:run_or_error(fun() ->
                {ok, _} = tmux_pane:send_text(InputPane, <<"archive input">>),
                {ok, _} = tmux_pane:send_keys(
                    InputPane, [enter, {control, <<"d">>}]),
                {ok, #{cleanup := complete}} =
                    tmux_operation:await(InputOperation, 900),
                {ok, CompletedInput} = tmux_pane:get(
                    Server, tmux_model:get(id, InputPane)),
                true = tmux_model:get(dead, CompletedInput),
                case tmux_model:get(exit_status, CompletedInput) of
                    0 -> ok;
                    ObservedExit ->
                        {ok, ExitProbe} = tmux_command:raw(
                            <<"display-message">>, [<<"-p">>, <<"-t">>,
                                tmux_model:get(id, CompletedInput),
                                <<"#{pane_id}|#{pane_dead}|",
                                  "#{pane_dead_status}|#{pane_dead_signal}">>]),
                        ExitDetails = case tmux_server:command(
                            Server, ExitProbe, #{}) of
                            {ok, #{stdout := NativeExit}} -> NativeExit;
                            {error, ExitFailure} -> maps:with(
                                [code, outcome, phase, cleanup], ExitFailure)
                        end,
                        error({unexpected_pane_exit,
                            #{expected => 0, observed => ObservedExit,
                              pane => tmux_model:get(id, CompletedInput),
                              native => ExitDetails}})
                end,
                {ok, _} = tmux_pane:kill(CompletedInput),
                {error, #{code := target_gone}} = tmux_pane:get(
                    Server, tmux_model:get(id, InputPane)),
                {ok, _} = tmux_window:kill(InputWindow),
                {error, #{code := target_gone}} =
                    tmux_window:get(Server, InputWindowId)
            end, fun() ->
                tmux_scope:run_or_error(fun() ->
                    {ok, _} = tmux_operation:cancel(InputOperation)
                end, fun() ->
                    case tmux_operation:await(InputOperation, 900) of
                        {ok, #{cleanup := complete}} -> ok;
                        {error, #{cleanup := complete}} -> ok
                    end
                end), ok
            end),
            HookName = <<"after-split-window">>,
            {ok, _} = tmux_option:set(Session, <<"@manual-hook">>, <<>>),
            {ok, FirstHook} = tmux_command:raw(<<"set-option">>,
                [<<"-a">>, <<"-t">>, SessionId0, <<"@manual-hook">>, <<"A">>]),
            {ok, SecondHook} = tmux_command:raw(<<"set-option">>,
                [<<"-a">>, <<"-t">>, SessionId0, <<"@manual-hook">>, <<"B">>]),
            {ok, _} = tmux_hook:set(Session, {HookName, 7}, FirstHook),
            {ok, _} = tmux_hook:append(Session, HookName, SecondHook),
            {ok, _} = tmux_hook:run(Session, HookName),
            {ok, <<"BA">>} = tmux_option:get(Session, <<"@manual-hook">>, #{}),
            {ok, _} = tmux_hook:clear(Session, HookName),
            {ok, #{}} = tmux_hook:get(Session, HookName, #{}),
            {ok, _} = tmux_hook:unset(Session, HookName),
            none = tmux_hook:get(Session, HookName, #{})
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end),
        ok
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
