-module(tmux_pane_text).
-moduledoc """
Wait for literal bytes in a pane's current screen on a server started by
`tmux_server:start_owned/1` or `tmux_server:with_owned/2`. The pane must
still contain the same live process. Respawn and removal end the wait.

`start/3` reads the first screen before returning a handle. Text already on
the screen can match at this point. Send any input after it returns.
The wait uses bounded captures at intervals, so text can appear and disappear
between samples. A match reports visible content only.
The wait uses the owned server's default capture commands.

The starting process owns the wait. `await/2` can time out independently
while the wait continues. Cancel it explicitly or let the owner exit.
Completed handles retain their result for up to 60 seconds. An owner or
endpoint that exits retires its handles. Call `release/1` to free the result
sooner. The endpoint limits concurrent and retained waits.
""".
-behaviour(gen_server).
-export([start/3, await/2, cancel/1, release/1, wait/3]).
-export([start_link/4, init/1, handle_continue/2, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, format_status/1]).
-export_type([t/0, options/0, result/0]).

-doc "A generation-bound handle for one pane text wait.".
-opaque t() :: {pane_text, pid(), reference()}.
-doc "The wait defaults to 2,500 ms and a 16 KiB screen. max_bytes counts captured bytes.".
-type options() :: #{deadline_ms => 1..600000, max_bytes => 1..262144}.
-doc "The matching screen and the byte range where the requested text first appears.".
-type result() :: {ok, #{screen := binary(), match := {non_neg_integer(), pos_integer()}}} |
                  {error, map()}.

-doc "Start sampling a live owned pane. Returns after the first bounded capture.".
-spec start(tmux_model:pane(), binary(), options()) -> {ok, t()} | {error, map()}.
start(Pane, Needle, Options) ->
    Started = now_ms(),
    maybe
        {ok, Config} ?= options(Needle, Options, Started),
        {ok, Server, Id} ?= tmux_target:resolve(pane, Pane),
        {ok, Pid} ?= pane_pid(Pane),
        Token = make_ref(),
        Child = #{id => Token, start => {?MODULE, start_link,
            [self(), Token, Server, Config#{pane => Id, pane_pid => Pid}]},
            restart => temporary, shutdown => 1000},
        try supervisor:start_child(tmux_sup, Child) of
            {ok, Observer} ->
                Handle = {pane_text, Observer, Token},
                Remaining = max(0, maps:get(deadline, Config) - now_ms()),
                case request(Handle, ready, Remaining + 1000) of
                    ok -> {ok, Handle};
                    {error, _} = Error -> discard(Handle), Error
                end;
            {error, _} -> {error, #{code => pane_wait_unavailable}}
        catch
            exit:_ -> {error, #{code => pane_wait_unavailable}}
        end
    end.

-doc "Collect a result. An await_timeout leaves the wait active.".
-spec await(t(), timeout()) -> result().
await(Wait, Timeout) -> request(Wait, await, Timeout).

-doc "Request cancellation. Use `await/2` for the result and cleanup status.".
-spec cancel(t()) -> {ok, cancel_requested | already_completed} | {error, map()}.
cancel(Wait) -> request(Wait, cancel, 900).

-doc "Release a completed wait and free its endpoint slot. Call `cancel/1` to stop an active wait.".
-spec release(t()) -> ok | {error, map()}.
release(Wait) ->
    case request(Wait, release, 900) of
        {error, #{code := pane_wait_expired}} -> ok;
        Result -> Result
    end.

-doc false.
-spec wait(tmux_model:pane(), binary(), options()) -> result().
wait(Pane, Needle, Options) ->
    maybe
        {ok, Handle} ?= start(Pane, Needle, Options),
        try await(Handle, infinity)
        after discard(Handle)
        end
    end.

options(Needle, Options, Started) when is_map(Options) ->
    Limit = maps:get(max_bytes, Options, 16384),
    Millis = maps:get(deadline_ms, Options, 2500),
    case {map_size(maps:without([deadline_ms, max_bytes], Options)) =:= 0,
          is_integer(Millis, 1, 600000) andalso is_integer(Limit, 1, 262144),
          is_binary(Needle) andalso byte_size(Needle) > 0 andalso byte_size(Needle) =< Limit} of
        {true, true, true} -> {ok, #{needle => binary:copy(Needle), max_bytes => Limit,
                                    deadline => Started + Millis}};
        {true, true, false} -> {error, #{code => invalid_needle}};
        _ -> {error, #{code => invalid_pane_wait_options}}
    end;
options(_, _, _) -> {error, #{code => invalid_pane_wait_options}}.

pane_pid(Pane) ->
    case tmux_model:get(pid, Pane) of
        Pid when is_integer(Pid), Pid > 0 -> {ok, Pid};
        _ -> {error, #{code => stale_pane}}
    end.

request({pane_text, Pid, Token}, Kind, Timeout)
  when is_pid(Pid), is_reference(Token),
       (Timeout =:= infinity orelse is_integer(Timeout, 0, 4294967295)) ->
    Tag = make_ref(),
    Request = gen_server:send_request(Pid, {Token, Kind, Tag}),
    case gen_server:receive_response(Request, Timeout) of
        {reply, Reply} -> Reply;
        timeout ->
            gen_server:cast(Pid, {Token, unwait, Tag}),
            {error, #{code => await_timeout}};
        {error, _} -> {error, #{code => pane_wait_expired}}
    end;
request(_, _, _) -> {error, #{code => invalid_pane_wait}}.

discard({pane_text, Pid, Token}) -> gen_server:cast(Pid, {Token, release}).

-doc false.
-spec start_link(pid(), reference(), tmux_server:t(), map()) -> gen_server:start_ret().
start_link(Owner, Token, Server, Config) -> gen_server:start_link(?MODULE, {Owner, Token, Server, Config}, []).

-doc false.
-spec init({pid(), reference(), tmux_server:t(), map()}) -> {ok, map(), {continue, sample}}.
init({Owner, Token, Server, Config}) ->
    {ok, Config#{token => Token, owner_monitor => monitor(process, Owner), server => Server,
        watch => none, endpoint_monitor => none, ready => false, result => none,
        operation => none, abort => none,
        releasing => false, timer => none, requests => gen_server:reqids_new(), waiters => #{}},
        {continue, sample}}.

-doc false.
-spec handle_continue(sample, map()) -> {noreply, map()}.
handle_continue(sample, #{server := Server, deadline := Deadline} = State) ->
    Next = case Deadline - now_ms() of
        Left when Left > 0 -> watch(Server, min(900, Left), State);
        _ -> complete(failure(deadline), State)
    end,
    {noreply, Next}.

watch(Server, Timeout, State) ->
    case tmux_server:watch_closing(Server, Timeout) of
        {ok, Watch, #{owner := Endpoint, config := #{owned := true, server_pid := Daemon}}} ->
            prepare(Daemon, State#{watch => Watch, endpoint_monitor => monitor(process, Endpoint)});
        {ok, Watch, _} -> complete(failure(owned_endpoint_required), State#{watch => Watch});
        {error, Error} -> complete({error, Error}, State)
    end.

prepare(Daemon, #{pane := Id, pane_pid := Pid} = State) ->
    case tmux_identity:observe(Pid) of
        {ok, Identity} ->
            Nonce = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
            Mark = <<"libtmux-pane-", Nonce/binary>>,
            Command = capture_command(Daemon, Id, Pid, Mark),
            sample(State#{identity => Identity, command => Command, prefix => <<Mark/binary, $\n>>});
        {error, _} -> complete(failure(stale_pane), State)
    end.

capture_command(Daemon, Pane, Pid, Mark) ->
    DaemonArg = integer_to_binary(Daemon),
    PidArg = integer_to_binary(Pid),
    Live = <<"#{&&:#{==:#{pane_pid},", PidArg/binary, "},#{==:#{pane_dead},0}}">>,
    Condition = <<"#{&&:#{==:#{pid},", DaemonArg/binary, "},",
        "#{&&:#{==:#{pane_id},", Pane/binary, "},", Live/binary, "}}">>,
    {ok, Tag} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"-t">>, Pane, Mark]),
    {ok, Capture} = tmux_command:raw(<<"capture-pane">>, [<<"-p">>, <<"-t">>, Pane]),
    {ok, Action} = tmux_command:to_config([Tag, Capture]),
    {ok, Command} = tmux_command:raw(<<"if-shell">>,
        [<<"-F">>, <<"-t">>, Pane, <<"--">>, Condition, Action]),
    Command.

sample(#{deadline := Deadline} = State) ->
    case Deadline > now_ms() of
        true -> capture(State);
        false -> complete(failure(deadline), State)
    end.

capture(#{server := Server, command := Command, prefix := Prefix,
          max_bytes := Limit, deadline := Deadline} = State) ->
    case same_pane(State) of
        true ->
            Options = #{max_stdout => Limit + byte_size(Prefix), max_stderr => 4096},
            case tmux_operation:start_before(Server, Command, Options, Deadline) of
                {ok, Operation} -> send_operation(await, State#{operation => Operation});
                {error, _} = Error -> complete(Error, State)
            end;
        false -> complete(failure(stale_pane), State)
    end.

send_operation(Kind, #{operation := Operation, requests := Requests} = State) ->
    Request = tmux_operation:send_request(Operation, Kind),
    State#{requests => gen_server:reqids_add(Request, Kind, Requests)}.

same_pane(#{identity := Identity, pane_pid := Pid}) -> tmux_identity:check(Identity, Pid) =:= ok.

-doc false.
-spec handle_call(term(), gen_server:from(), map()) ->
    {reply, term(), map()} | {noreply, map()} | {stop, normal, ok, map()}.
handle_call({Token, release, _}, _, #{token := Token, result := none} = State) ->
    {reply, {error, #{code => pane_wait_active}}, State};
handle_call({Token, release, _}, _, #{token := Token} = State) ->
    {stop, normal, ok, State};
handle_call({Token, cancel, _}, _, #{token := Token, result := none} = State) ->
    {reply, {ok, cancel_requested}, abort(cancelled, State)};
handle_call({Token, cancel, _}, _, #{token := Token} = State) ->
    {reply, {ok, already_completed}, State};
handle_call({Token, Kind, Tag}, From, #{token := Token, waiters := Waiters} = State)
  when Kind =:= ready; Kind =:= await ->
    case answer(Kind, State) of
        none when map_size(Waiters) < 16 ->
            {Pid, _} = From,
            {noreply, State#{waiters => Waiters#{Tag => {Kind, From, monitor(process, Pid)}}}};
        none -> {reply, {error, #{code => too_many_waiters}}, State};
        Reply -> {reply, Reply, State}
    end;
handle_call(_, _, State) -> {reply, {error, #{code => invalid_pane_wait}}, State}.

-doc false.
-spec handle_cast(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_cast({Token, unwait, Tag}, #{token := Token} = State) -> {noreply, remove_waiter(Tag, State)};
handle_cast({Token, release}, #{token := Token} = State) -> release_state(State);
handle_cast(_, State) -> {noreply, State}.

-doc false.
-spec handle_info(term(), map()) -> {noreply, map()} | {stop, normal, map()}.
handle_info({timeout, Timer, sample}, #{timer := Timer} = State) ->
    {noreply, sample(State#{timer => none})};
handle_info({timeout, Timer, expire}, #{timer := Timer} = State) -> {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, #{owner_monitor := Monitor} = State) ->
    release_state(State);
handle_info({'DOWN', Monitor, process, _, _}, #{endpoint_monitor := Monitor} = State) ->
    endpoint_closed(State);
handle_info({'DOWN', Monitor, process, _, _} = Message, State) ->
    case operation_reply(Message, State) of
        no_reply -> {noreply, drop_monitor(Monitor, State)};
        Next -> continue(Next)
    end;
handle_info({tmux_server_closing, _, _, Watch, _}, #{watch := Watch} = State) ->
    endpoint_closed(State);
handle_info(Message, State) ->
    case operation_reply(Message, State) of
        no_reply -> {noreply, State};
        Next -> continue(Next)
    end.

endpoint_closed(State) -> continue(abort(stale_reference, State#{releasing => true})).

operation_reply(Message, #{requests := Requests} = State) ->
    case gen_server:check_response(Message, Requests, true) of
        {{reply, Result}, await, Left} -> observed(Result, State#{requests => Left});
        {{error, _}, await, Left} -> observed({error, #{code => stale_reference, cleanup => unverified}},
                                             State#{requests => Left});
        {_, cancel, Left} -> State#{requests => Left};
        _ -> no_reply
    end.

observed(Result, #{abort := Reason, operation := Operation} = State) when Reason =/= none ->
    {_, Detail} = Result,
    Cleanup = maps:get(cleanup, Detail, unverified),
    Error = #{code => Reason, cleanup => Cleanup},
    complete({error, with_recovery(Error, Operation)}, State#{operation => none});
observed({ok, #{stdout := Bytes}}, State) -> screen(Bytes, State#{operation => none});
observed({error, Detail}, #{operation := Operation} = State) ->
    complete({error, with_recovery(Detail, Operation)}, State#{operation => none}).

with_recovery(Detail, Operation) ->
    case maps:get(cleanup, Detail, unverified) of
        complete -> Detail;
        Cleanup -> Detail#{cleanup => Cleanup, operation => Operation}
    end.

screen(Bytes, #{prefix := Prefix, needle := Needle, deadline := Deadline} = State) ->
    PrefixSize = byte_size(Prefix),
    case {Bytes, same_pane(State), Deadline - now_ms()} of
        {_, _, Left} when Left =< 0 -> complete(failure(deadline), State);
        {_, false, _} -> complete(failure(stale_pane), State);
        {<<>>, true, _} -> complete(failure(stale_pane), State);
        {<<Prefix:PrefixSize/binary, Captured/binary>>, true, Left} ->
            Ready = reply_waiters(State#{ready => true}),
            case binary:match(Captured, Needle) of
                nomatch -> Ready#{timer => erlang:start_timer(min(20, Left), self(), sample)};
                Match -> complete({ok, #{screen => Captured, match => Match}}, Ready)
            end;
        _ -> complete(failure(unexpected_pane_capture), State)
    end.

abort(_, #{result := Result} = State) when Result =/= none -> State;
abort(Reason, #{operation := none} = State) -> complete(failure(Reason), State);
abort(Reason, #{abort := none} = State) -> send_operation(cancel, State#{abort => Reason});
abort(_, State) -> State.

release_state(State) -> continue(abort(cancelled, State#{releasing => true})).

continue(#{releasing := true, result := Result} = State) when Result =/= none -> {stop, normal, State};
continue(State) -> {noreply, State}.

failure(Code) -> {error, #{code => Code, cleanup => complete}}.

complete(Result, #{timer := Timer} = State) ->
    _ = case Timer of none -> ok; _ -> erlang:cancel_timer(Timer) end,
    reply_waiters(State#{result => Result, timer => erlang:start_timer(60000, self(), expire)}).

answer(ready, #{ready := true}) -> ok;
answer(ready, #{result := Result}) -> Result;
answer(await, #{result := Result}) -> Result.

reply_waiters(#{waiters := Waiters} = State) ->
    maps:fold(fun(Tag, {Kind, From, _}, Acc) ->
        case answer(Kind, Acc) of
            none -> Acc;
            Reply -> gen_server:reply(From, Reply), remove_waiter(Tag, Acc)
        end
    end, State, Waiters).

remove_waiter(Tag, #{waiters := Waiters} = State) ->
    case maps:take(Tag, Waiters) of
        {{_, _, Monitor}, Rest} -> demonitor(Monitor, [flush]), State#{waiters => Rest};
        error -> State
    end.

drop_monitor(Monitor, #{waiters := Waiters} = State) ->
    State#{waiters => maps:filter(fun(_, {_, _, Value}) -> Value =/= Monitor end, Waiters)}.

-doc false.
-spec terminate(term(), map()) -> ok.
terminate(_, #{watch := none}) -> ok;
terminate(_, #{server := Server, watch := Watch}) -> _ = tmux_server:unwatch_closing(Server, Watch), ok.

-doc false.
-spec format_status(map()) -> map().
format_status(Status) ->
    maps:map(fun
        (state, _) -> redacted;
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (_, Value) -> Value
    end, maps:remove(log, Status)).

now_ms() -> erlang:monotonic_time(millisecond).
