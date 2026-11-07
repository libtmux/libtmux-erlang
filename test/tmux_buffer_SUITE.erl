-module(tmux_buffer_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         byte_buffers/1, paste_delivery/1]).

%% Outer: exact buffers and pane input require an owned native server.
all() -> [byte_buffers, paste_delivery].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

byte_buffers(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, []} = tmux_buffer:list(Server),
        Name = <<"bytes #{pid}; $HOME">>,
        Bytes = <<(list_to_binary(lists:seq(0, 255)))/binary,
            "\n%begin 1 2 3\n%end 1 2 3\n\\r\n">>,
        {ok, _} = tmux_buffer:load(Server, Name, Bytes),
        {ok, Bytes} = tmux_buffer:show(Server, Name),
        {error, #{code := output_limit, stream := stdout}} =
            tmux_buffer:show(Server, Name, #{max_bytes => 1}),
        {ok, [#{name := Name, size := Size, created := Created}]} = tmux_buffer:list(Server),
        Size = byte_size(Bytes),
        true = is_integer(Created),
        {ok, _} = tmux_buffer:load(Server, Name, <<>>),
        {ok, Bytes} = tmux_buffer:show(Server, Name),
        {ok, _} = tmux_buffer:load(Server, <<"empty">>, <<>>),
        {error, #{code := buffer_not_found}} = tmux_buffer:show(Server, <<"empty">>),
        {ok, _} = tmux_buffer:load(Server, automatic, <<"auto">>),
        {ok, <<"auto">>} = tmux_buffer:show(Server, latest),
        {ok, [#{name := Auto}, #{name := Name}]} = tmux_buffer:list(Server),
        {ok, _} = tmux_buffer:rename(Server, Auto, <<"renamed">>),
        {ok, <<"auto">>} = tmux_buffer:show(Server, <<"renamed">>),
        {error, #{code := buffer_not_found}} = tmux_buffer:rename(Server, Auto, <<"absent">>),
        {ok, <<"auto">>} = tmux_buffer:show(Server, <<"renamed">>),
        {ok, Version} = tmux_server:version(Server),
        case tmux_version:at_least(Version, {3, 4}) of
            false ->
                {error, #{code := command_error}} = tmux_buffer:rename(Server, Name, <<"renamed">>),
                {ok, <<"auto">>} = tmux_buffer:show(Server, <<"renamed">>);
            true ->
                {ok, _} = tmux_buffer:rename(Server, Name, <<"renamed">>),
                {ok, Bytes} = tmux_buffer:show(Server, <<"renamed">>)
        end,
        {ok, _} = tmux_buffer:delete(Server, <<"renamed">>),
        {error, #{code := buffer_not_found}} = tmux_buffer:delete(Server, <<"renamed">>),
        case tmux_version:at_least(Version, {3, 4}) of
            false -> {ok, Bytes} = tmux_buffer:show(Server, Name);
            true -> ok
        end,
        case tmux_version:at_least(Version, {3, 7}) of
            true -> ok;
            false ->
                Odd = <<"row\n1:2:3:", 13, "\\r $HOME", 195, 169, 255>>,
                {ok, _} = tmux_buffer:load(Server, Odd, <<"odd">>),
                {ok, [#{name := Odd} | _]} = tmux_buffer:list(Server),
                {ok, <<"odd">>} = tmux_buffer:show(Server, Odd),
                %% Unrelated metadata must not block reducing the store.
                #{directory := Directory} = tmux_test_fixture:info(Fixture),
                Source = filename:join(Directory, "large-buffer-store.conf"),
                Prefix = binary:copy(<<"n">>, 32700),
                ok = file:write_file(Source, [[<<"set-buffer -b ">>, Prefix,
                    integer_to_binary(I), <<" x\n">>] || I <- lists:seq(1, 33)]),
                {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
                    [<<"source-file">>, list_to_binary(Source)]),
                {error, #{code := output_limit}} = tmux_buffer:list(Server),
                {ok, _} = tmux_buffer:rename(Server, Odd, <<"stress-renamed">>),
                {ok, <<"odd">>} = tmux_buffer:show(Server, <<"stress-renamed">>),
                {ok, _} = tmux_buffer:delete(Server, <<"stress-renamed">>)
        end,
        ok = tmux_server:close(Server),
        {error, #{code := server_closed}} = tmux_buffer:show(Server, Name)
    end).

paste_delivery(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        #{directory := Directory} = tmux_test_fixture:info(Fixture),
        Ready = filename:join(Directory, "paste-ready"),
        {ok, Listener} = gen_tcp:listen(0, [local, {ifaddr, {local, Ready}},
            binary, {active, false}]),
        {ok, Version} = tmux_server:version(Server),
        Modern = tmux_version:at_least(Version, {3, 7}),
        Counts = case Modern of true -> <<"[256,12,4]">>; false -> <<"[256,12]">> end,
        Script = <<"import os,socket,sys,tty,json,signal\n"
            "tty.setraw(0)\ns=socket.socket(socket.AF_UNIX)\ns.connect(sys.argv[1])\n"
            "s.sendall(b'R')\nfor n in json.loads(sys.argv[2]):\n data=b''\n"
            " while len(data)<n: data+=os.read(0,n-len(data))\n"
            " s.sendall(len(data).to_bytes(4,'big')+data)\nsignal.pause()\n">>,
        try
            {ok, Session} = tmux_session:create(Server, #{launch => #{argv =>
                [<<"/usr/bin/python3">>, <<"-c">>, Script, list_to_binary(Ready), Counts]}}),
            {ok, Peer} = gen_tcp:accept(Listener, 900),
            try
                {ok, <<"R">>} = gen_tcp:recv(Peer, 1, 900),
                {ok, Snapshot} = tmux_server:snapshot(Server),
                [Pane] = tmux_snapshot:panes(Snapshot),
                ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane)),
                Bytes = list_to_binary(lists:seq(0, 255)),
                {ok, _} = tmux_buffer:load(Server, <<"paste">>, Bytes),
                {ok, _} = tmux_buffer:paste(Pane, <<"paste">>, #{}),
                Bytes = received(Peer),
                {ok, _} = tmux_buffer:load(Server, <<"paste">>, <<"a\nb\n">>),
                {ok, _} = tmux_buffer:paste(Pane, <<"paste">>,
                    #{separator => <<"#{x};">>, delete => true}),
                <<"a#{x};b#{x};">> = received(Peer),
                {error, #{code := buffer_not_found}} = tmux_buffer:show(Server, <<"paste">>),
                {ok, _} = tmux_buffer:load(Server, <<"safe">>, <<"A", 27, "B">>),
                case Modern of
                    true ->
                        {ok, _} = tmux_buffer:paste(Pane, <<"safe">>, #{sanitize => true}),
                        <<"A^[B">> = received(Peer);
                    false ->
                        {error, #{code := unsupported_capability}} =
                            tmux_buffer:paste(Pane, <<"safe">>, #{sanitize => true})
                end,
                {ok, _} = tmux_session:kill(Session),
                {error, #{code := target_gone}} = tmux_buffer:paste(Pane, latest, #{})
            after ok = gen_tcp:close(Peer)
            end
        after ok = gen_tcp:close(Listener)
        end
    end).

received(Peer) ->
    {ok, <<Size:32>>} = gen_tcp:recv(Peer, 4, 900),
    {ok, Bytes} = gen_tcp:recv(Peer, Size, 900),
    Bytes.

with_server(Config, Fun) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), Fun).
