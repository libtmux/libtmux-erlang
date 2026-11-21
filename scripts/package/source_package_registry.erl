-module(source_package_registry).
-moduledoc "Serve the source-package check artifacts over a private loopback HTTP endpoint.".
-include_lib("kernel/include/file.hrl").
-export([start/2, url/1, requests/1, stop/1]).
-export_type([registry/0]).

-define(REQUEST_LIMIT, 256).
-define(RECV_TIMEOUT_MS, 10000).

-doc "A running registry server: its port and the process that owns its state.".
-opaque registry() :: #{port := inet:port_number(), owner := pid()}.

-doc """
Serve the files under `Public` over HTTP on a loopback port chosen by the system.
Every GET or HEAD request is recorded by path and answered with the file, `404` or,
after `limit` requests (default 256), `429`. Responses carry an `ETag` of the file's
SHA-256. Other methods get `405`.
""".
-spec start(file:filename(), #{limit => non_neg_integer()}) -> registry().
start(Public, Options) ->
    Limit = maps:get(limit, Options, ?REQUEST_LIMIT),
    {ok, Listen} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false},
                                      {reuseaddr, true}, {backlog, 128}, {packet, http_bin}]),
    {ok, Port} = inet:port(Listen),
    Owner = spawn_link(fun() -> owner(Listen, Public, Limit) end),
    #{port => Port, owner => Owner}.

-spec url(registry()) -> string().
url(#{port := Port}) ->
    "http://127.0.0.1:" ++ integer_to_list(Port).

-doc "The request paths recorded so far, oldest first, as the client sent them.".
-spec requests(registry()) -> [binary()].
requests(#{owner := Owner}) ->
    ask(Owner, requests).

-doc """
Stop accepting connections, end the handlers and return the recorded request paths and
whether every registry process and the listening socket are gone.
""".
-spec stop(registry()) -> {[binary()], boolean()}.
stop(#{owner := Owner}) ->
    Monitor = erlang:monitor(process, Owner),
    {Requests, Quiet} = ask(Owner, stop),
    receive {'DOWN', Monitor, process, Owner, _} -> ok end,
    {Requests, Quiet andalso not is_process_alive(Owner)}.

ask(Owner, Request) ->
    Monitor = erlang:monitor(process, Owner),
    Tag = make_ref(),
    Owner ! {Request, self(), Tag},
    receive
        {Tag, Answer} ->
            erlang:demonitor(Monitor, [flush]),
            Answer;
        {'DOWN', Monitor, process, Owner, Reason} ->
            error({registry_down, Reason})
    end.

owner(Listen, Public, Limit) ->
    Owner = self(),
    {Acceptor, Monitor} = spawn_monitor(fun() -> accept(Listen, Owner, Public) end),
    owner_loop(#{listen => Listen, acceptor => Acceptor, monitor => Monitor, limit => Limit,
                 count => 0, requests => [], handlers => #{}}).

owner_loop(#{requests := Requests, count := Count, limit := Limit, handlers := Handlers} = State) ->
    receive
        {handler, Pid} ->
            Ref = erlang:monitor(process, Pid),
            owner_loop(State#{handlers := Handlers#{Ref => Pid}});
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Handlers) ->
            owner_loop(State#{handlers := maps:remove(Ref, Handlers)});
        {{record, _}, From, Tag} when Count >= Limit ->
            From ! {Tag, limit},
            owner_loop(State);
        {{record, Path}, From, Tag} ->
            From ! {Tag, ok},
            owner_loop(State#{requests := [Path | Requests], count := Count + 1});
        {requests, From, Tag} ->
            From ! {Tag, lists:reverse(Requests)},
            owner_loop(State);
        {stop, From, Tag} ->
            From ! {Tag, {lists:reverse(Requests), shut_down(State)}}
    end.

% Close the listener, wait for the acceptor, then kill the handlers still running.
shut_down(#{listen := Listen, acceptor := Acceptor, monitor := Monitor, handlers := Handlers}) ->
    ok = gen_tcp:close(Listen),
    Running = await_acceptor(Monitor, Handlers),
    lists:foreach(fun({Ref, Pid}) ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> ok end
    end, maps:to_list(Running)),
    erlang:port_info(Listen) =:= undefined andalso not is_process_alive(Acceptor).

await_acceptor(Monitor, Handlers) ->
    receive
        {handler, Pid} ->
            await_acceptor(Monitor, Handlers#{erlang:monitor(process, Pid) => Pid});
        {'DOWN', Monitor, process, _, _} ->
            Handlers;
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Handlers) ->
            await_acceptor(Monitor, maps:remove(Ref, Handlers))
    end.

accept(Listen, Owner, Public) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> receive go -> serve_connection(Socket, Owner, Public) end end),
            case gen_tcp:controlling_process(Socket, Handler) of
                ok ->
                    Owner ! {handler, Handler},
                    Handler ! go;
                {error, _} ->
                    exit(Handler, kill),
                    ok = gen_tcp:close(Socket)
            end,
            accept(Listen, Owner, Public);
        {error, _} ->
            ok
    end.

serve_connection(Socket, Owner, Public) ->
    Response = case read_request(Socket) of
        {ok, Method, Target} -> answer(Method, Target, Owner, Public);
        error -> response(400, [], <<"bad request">>, true)
    end,
    _ = gen_tcp:send(Socket, Response),
    ok = gen_tcp:close(Socket).

read_request(Socket) ->
    case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT_MS) of
        {ok, {http_request, Method, {abs_path, Target}, _}} ->
            case skip_headers(Socket) of
                ok -> {ok, Method, Target};
                error -> error
            end;
        _ -> error
    end.

skip_headers(Socket) ->
    case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT_MS) of
        {ok, http_eoh} -> ok;
        {ok, {http_header, _, _, _, _}} -> skip_headers(Socket);
        _ -> error
    end.

answer(Method, Target, Owner, Public) when Method =:= 'GET'; Method =:= 'HEAD' ->
    case ask(Owner, {record, Target}) of
        limit -> response(429, [], <<"too many requests">>, true);
        ok ->
            case file_for(Public, Target) of
                {ok, Path} ->
                    {ok, Body} = file:read_file(Path),
                    Tag = <<"\"", (script_util:sha256_hex(Body))/binary, "\"">>,
                    response(200, [{"ETag", Tag}], Body, Method =:= 'GET');
                error -> response(404, [], <<"not found">>, Method =:= 'GET')
            end
    end;
answer(_, _, _, _) ->
    response(405, [{"Allow", "GET, HEAD"}], <<"method not allowed">>, true).

% Map a request target to a regular file under `Public`; a `..` segment maps to nothing.
file_for(Public, Target) ->
    [Raw | _] = binary:split(Target, [<<"?">>, <<"#">>]),
    try uri_string:percent_decode(Raw) of
        Decoded when is_binary(Decoded) ->
            Segments = [S || S <- binary:split(Decoded, <<"/">>, [global]),
                             S =/= <<>>, S =/= <<".">>],
            Safe = not lists:member(<<"..">>, Segments) andalso
                   lists:all(fun(S) -> binary:match(S, <<0>>) =:= nomatch end, Segments),
            Path = filename:join([Public | Segments]),
            case Safe andalso Segments =/= [] andalso filelib:is_regular(Path) of
                true -> {ok, Path};
                false -> error
            end
    catch throw:_ -> error
    end.

response(Status, Headers, Body, WithBody) ->
    Reason = case Status of
        200 -> "OK";
        400 -> "Bad Request";
        404 -> "Not Found";
        405 -> "Method Not Allowed";
        429 -> "Too Many Requests"
    end,
    [io_lib:format("HTTP/1.1 ~b ~s\r\nContent-Length: ~b\r\n", [Status, Reason, byte_size(Body)]),
     "Content-Type: application/octet-stream\r\nConnection: close\r\n",
     [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers], "\r\n",
     [Body || WithBody]].
