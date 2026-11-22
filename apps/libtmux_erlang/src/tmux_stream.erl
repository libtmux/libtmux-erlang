-module(tmux_stream).
-moduledoc """
Subscribe to pane bytes and notifications on a dedicated tmux control client.

Each subscription belongs to its creating process. Share a subscription so
another process can join the client with its own credit. If the first
subscriber's process exits, the client retires.

Messages have the form `{tmux_stream, Subscription, Message}`. An event
contains its generation, sequence and native data. A gap reports unknown
loss after the last delivered sequence and retires that subscription. Use a
new subscription to observe subsequent output and `tmux_pane:capture/2`
to read the rendered screen.
""".
-export([subscribe/3, join/2, demand/2, ack/3, close/1]).
-export([new/4, change/4, resolve/4, event/2, down/2, empty/1, finish/2]).
-export_type([subscription/0, credit/0, options/0, event/0, message/0]).

-define(BYTES, 65536).
-define(MESSAGES, 8).
-define(SUBSCRIBERS, 16).
-define(REQUEST_MS, 900).

-doc "One subscription on a dedicated control client.".
-opaque subscription() :: {tmux_stream, tmux_control:t(), reference()}.

-doc "Bytes cover the event's binary fields. Messages count events.".
-type credit() :: #{bytes := 0..?BYTES, messages := 0..?MESSAGES}.

-doc "Initial credit defaults to 64 KiB and eight messages.".
-type options() :: #{credit => credit(), startup_timeout_ms => 1..600000}.

-doc "Raw pane bytes or a native notification name and its unparsed fields.".
-type event() :: {pane_output, binary(), binary()} | {notification, binary(), binary()}.

-doc "Messages delivered to the subscriber's mailbox.".
-type message() :: {event, reference(), pos_integer(), event()}
                 | {gap, reference(), #{after_sequence := non_neg_integer(), extent := unknown,
                                       reason := atom()}}
                 | {closed, reference(), atom()}.

-type state() :: #{control := tmux_control:t(), generation := reference(),
                   subscribers := #{reference() => map()}, terminal := atom()}.

-doc """
Start a dedicated client on an owned server and subscribe this process.
Pass a session captured on that endpoint. The client ignores size changes
from attaching and retires when tmux reports a different session.
The returned subscription includes its initial credit. Start effects after
this call returns to observe their output.
A startup error can return a control handle for `tmux_control:close/1`
when native retirement needs another attempt.
""".
-spec subscribe(tmux_server:t(), tmux_model:session(), options()) ->
    {ok, subscription()} | {error, map()}.
subscribe(Server, Session, Options) ->
    maybe
        {ok, Credit, Startup} ?= initial_credit(Options),
        Id = make_ref(),
        case tmux_control:attach_stream(Server, Session, Startup, {Id, Credit}) of
            {ok, Control} -> activated(Control, Id);
            {error, #{control := Control}} = Error -> abandon(Control, Id, Error);
            {error, _} = Error -> Error
        end
    end.

-doc """
Subscribe this process to the same dedicated client as an active subscription.
The new subscription has its own credit and sequence numbers. It starts
receiving data when it joins.
""".
-spec join(subscription(), #{credit => credit()}) -> {ok, subscription()} | {error, map()}.
join({tmux_stream, Control, _} = Subscription, Options) ->
    maybe
        {ok, Credit, #{}} ?= initial_credit(Options),
        Id = make_ref(),
        Deadline = now_ms() + ?REQUEST_MS,
        case call(Subscription, {join, Id, Credit, Deadline}, ?REQUEST_MS) of
            ok -> activated(Control, Id);
            {error, _} = Failure -> abandon(Control, Id, Failure)
        end
    else
        {ok, _, _} -> invalid_options();
        {error, _} = Error -> Error
    end;
join(_, _) -> invalid_subscription().

activated(Control, Id) ->
    ok = tmux_control:resolve_stream(Control, Id, activate),
    {ok, {tmux_stream, Control, Id}}.

abandon(Control, Id, Error) ->
    ok = tmux_control:resolve_stream(Control, Id, abandon),
    Error.

-doc """
Add credit for future deliveries. Unused credit plus delivered data awaiting
acknowledgement must fit within 64 KiB and eight messages.
An `await_timeout` leaves the credit change unconfirmed.
""".
-spec demand(subscription(), credit()) -> ok | {error, map()}.
demand(Subscription, Credit) ->
    maybe
        ok ?= valid_credit(Credit),
        call(Subscription, {demand, Credit}, 900)
    end.

-doc """
Acknowledge one delivered sequence in its generation. Duplicate
acknowledgements are idempotent. Returned capacity can be requested again
with `demand/2`.
""".
-spec ack(subscription(), reference(), pos_integer()) -> ok | {error, map()}.
ack(Subscription, Generation, Sequence) when is_reference(Generation), is_integer(Sequence), Sequence > 0 ->
    call(Subscription, {ack, Generation, Sequence}, 900);
ack(_, _, _) -> {error, #{code => invalid_ack}}.

-doc """
Close this subscription. Closing the final subscription waits for confirmed
retirement of its control client. A cleanup error leaves retirement running
and permits another close attempt.
""".
-spec close(subscription()) -> ok | {error, map()}.
close(Subscription) -> call(Subscription, close, 1000).

call({tmux_stream, Control, Id}, Action, Timeout) when is_reference(Id) ->
    tmux_control:request(Control, {stream, Id, Action}, Timeout);
call(_, _, _) -> invalid_subscription().

initial_credit(Options) when is_map(Options) ->
    case maps:without([credit, startup_timeout_ms], Options) of
        Extra when map_size(Extra) =:= 0 ->
            Credit = maps:get(credit, Options, #{bytes => ?BYTES, messages => ?MESSAGES}),
            maybe
                ok ?= valid_credit(Credit),
                {ok, Credit, maps:with([startup_timeout_ms], Options)}
            end;
        _ -> invalid_options()
    end;
initial_credit(_) -> invalid_options().

valid_credit(#{bytes := Bytes, messages := Messages} = Credit) when map_size(Credit) =:= 2,
  is_integer(Bytes, 0, ?BYTES), is_integer(Messages, 0, ?MESSAGES) -> ok;
valid_credit(_) -> {error, #{code => invalid_credit}}.

invalid_options() -> {error, #{code => invalid_stream_options}}.
invalid_subscription() -> {error, #{code => invalid_subscription}}.

-doc false.
-spec new(pid(), tmux_control:t(), reference(), {reference(), credit()}) -> state().
new(Owner, Control, Generation, {Id, Credit}) ->
    First = subscriber(Owner, Control, Id, Credit),
    #{control => Control, generation => Generation, subscribers => #{Id => First}, terminal => none}.

subscriber(Owner, Control, Id, Credit) ->
    #{owner => Owner, monitor => monitor(process, Owner), subscription => {tmux_stream, Control, Id},
      active => false, credit => Credit, sent => 0, outstanding => #{}}.

-doc false.
-spec change(reference(), pid(), term(), state()) -> {ok | {error, map()}, state()}.
change(Id, Caller, {join, Next, Credit, Deadline}, #{control := Control, subscribers := Subs} = State)
  when is_reference(Next), not is_map_key(Next, Subs), is_integer(Deadline) ->
    case {Deadline > now_ms(), valid_credit(Credit), maps:is_key(Id, Subs)} of
        {false, _, _} -> {{error, #{code => subscription_expired}}, State};
        {true, ok, true} when map_size(Subs) < ?SUBSCRIBERS ->
            New = subscriber(Caller, Control, Next, Credit),
            {ok, State#{subscribers => Subs#{Next => New}}};
        {true, ok, true} -> {{error, #{code => subscriber_limit}}, State};
        {true, ok, false} -> {{error, #{code => subscription_closed}}, State};
        {true, {error, _} = Error, _} -> {Error, State}
    end;
change(Id, Caller, Action, #{subscribers := Subs} = State) ->
    case maps:find(Id, Subs) of
        {ok, #{owner := Caller} = Sub} -> change_owned(Id, Action, Sub, State);
        {ok, _} -> {{error, #{code => not_owner}}, State};
        error when Action =:= close -> {ok, State};
        error -> {{error, #{code => subscription_closed}}, State}
    end.

change_owned(Id, {demand, #{bytes := Bytes, messages := Messages} = Credit},
             #{credit := #{bytes := Unused, messages := Slots}, outstanding := Outstanding} = Sub,
             #{subscribers := Subs} = State)
  when map_size(Credit) =:= 2, is_integer(Bytes, 0, ?BYTES), is_integer(Messages, 0, ?MESSAGES) ->
    NextBytes = Unused + Bytes,
    NextSlots = Slots + Messages,
    case (NextBytes + lists:sum(maps:values(Outstanding)) =< ?BYTES) andalso
         (NextSlots + map_size(Outstanding) =< ?MESSAGES) of
        true ->
            Next = Sub#{credit => #{bytes => NextBytes, messages => NextSlots}},
            {ok, State#{subscribers => Subs#{Id => Next}}};
        false -> {{error, #{code => credit_limit}}, State}
    end;
change_owned(Id, {ack, Generation, Seq}, #{sent := Sent, outstanding := Outstanding} = Sub,
             #{generation := Generation, subscribers := Subs} = State) when is_integer(Seq), Seq > 0, Seq =< Sent ->
    {ok, State#{subscribers => Subs#{Id => Sub#{outstanding => maps:remove(Seq, Outstanding)}}}};
change_owned(_, {ack, _, _}, _, State) -> {{error, #{code => invalid_ack}}, State};
change_owned(Id, close, #{active := Active} = Sub,
             #{generation := Generation, subscribers := Subs} = State) ->
    case Active of
        true -> notify({closed, Generation, unsubscribed}, Sub);
        false -> discard(Sub)
    end,
    {ok, State#{subscribers => maps:remove(Id, Subs)}};
change_owned(_, _, _, State) -> {{error, #{code => invalid_stream_request}}, State}.

-doc false.
-spec resolve(reference(), pid(), activate | abandon, state()) -> state().
resolve(Id, Caller, Action, #{subscribers := Subs, terminal := Terminal,
                              generation := Generation} = State) ->
    case maps:find(Id, Subs) of
        {ok, #{owner := Caller, active := false} = Sub} ->
            Remaining = case {Action, Terminal} of
                {activate, none} -> Subs#{Id => Sub#{active => true}};
                {activate, Reason} ->
                    terminate_subscription(Reason, Generation, Sub),
                    maps:remove(Id, Subs);
                {abandon, _} ->
                    discard(Sub),
                    maps:remove(Id, Subs)
            end,
            State#{subscribers => Remaining};
        _ -> State
    end.

-doc false.
-spec event(binary(), state()) -> {ok, state()} | {error, atom()}.
event(Line, #{generation := Generation, subscribers := Subs} = State) ->
    maybe
        {ok, Value, Size} ?= decode(Line),
        Next = maps:fold(fun(Id, Sub, Acc) -> deliver(Id, Generation, Value, Size, Sub, Acc) end, #{}, Subs),
        {ok, State#{subscribers => Next}}
    end.

deliver(Id, _, _, _, #{active := false} = Sub, Acc) ->
    Acc#{Id => Sub};
deliver(Id, Generation, Value, Size,
        #{credit := #{bytes := Bytes, messages := Messages}, outstanding := Outstanding, sent := Sent,
          owner := Owner, subscription := Subscription} = Sub, Acc) when Bytes >= Size, Messages > 0 ->
    Sequence = Sent + 1,
    Owner ! {tmux_stream, Subscription, {event, Generation, Sequence, Value}},
    Credit = #{bytes => Bytes - Size, messages => Messages - 1},
    Acc#{Id => Sub#{sent => Sequence, credit => Credit, outstanding => Outstanding#{Sequence => Size}}};
deliver(_, Generation, _, _, Sub, Acc) ->
    gap(Generation, credit_exhausted, Sub),
    Acc.

-doc false.
-spec empty(state()) -> boolean().
empty(#{subscribers := Subs}) -> map_size(Subs) =:= 0.

-doc false.
-spec down(reference(), state()) -> state().
down(Monitor, #{subscribers := Subs} = State) ->
    Remaining = maps:filter(fun
        (_, #{monitor := Ref} = Sub) when Ref =:= Monitor -> discard(Sub), false;
        (_, _) -> true
    end, Subs),
    State#{subscribers => Remaining}.

-doc false.
-spec finish(atom(), state()) -> state().
finish(Reason, #{generation := Generation, subscribers := Subs} = State) ->
    % An accepted join still needs its receipt if the caller confirms it.
    Pending = maps:filter(fun
        (_, #{active := false}) -> true;
        (_, Sub) -> terminate_subscription(Reason, Generation, Sub), false
    end, Subs),
    State#{subscribers => Pending, terminal => Reason}.

terminate_subscription(Reason, Generation, Sub) when Reason =:= closed; Reason =:= owner_down ->
    notify({closed, Generation, Reason}, Sub);
terminate_subscription(Reason, Generation, Sub) ->
    gap(Generation, Reason, Sub).

gap(Generation, Reason, #{sent := Sent} = Sub) ->
    ok = tmux_log:stream_gap(Generation, Reason, Sent),
    notify({gap, Generation, #{after_sequence => Sent, extent => unknown, reason => Reason}}, Sub).

notify(Message, #{owner := Owner, subscription := Subscription} = Sub) ->
    Owner ! {tmux_stream, Subscription, Message},
    discard(Sub).

discard(#{monitor := Monitor}) ->
    _ = demonitor(Monitor, [flush]),
    ok.

now_ms() ->
    erlang:monotonic_time(millisecond).

decode(<<"%output ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [<<$%, Digits/binary>> = Pane, Encoded] ->
            maybe
                true ?= digits(Digits),
                {ok, Bytes} ?= unescape(Encoded, []),
                {ok, {pane_output, binary:copy(Pane), Bytes}, byte_size(Pane) + byte_size(Bytes)}
            else
                false -> {error, invalid_pane_output};
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_pane_output}
    end;
decode(<<"%pause ", _/binary>>) -> {error, pane_output_paused};
decode(<<"%extended-output ", _/binary>>) -> {error, unqualified_pane_output};
decode(<<$%, Rest/binary>>) ->
    {Name, Fields} = case binary:split(Rest, <<" ">>) of
        [Key, Data] -> {Key, Data};
        [Key] -> {Key, <<>>}
    end,
    {ok, {notification, binary:copy(Name), binary:copy(Fields)}, byte_size(Name) + byte_size(Fields)};
decode(_) -> {error, invalid_control_notification}.

digits(<<>>) -> false;
digits(Digits) -> lists:all(fun(Byte) -> Byte >= $0 andalso Byte =< $9 end, binary_to_list(Digits)).

unescape(<<>>, Acc) -> {ok, list_to_binary(lists:reverse(Acc))};
unescape(<<$\\, A, B, C, Rest/binary>>, Acc)
  when A >= $0, A =< $3, B >= $0, B =< $7, C >= $0, C =< $7 ->
    unescape(Rest, [((A - $0) bsl 6) bor ((B - $0) bsl 3) bor (C - $0) | Acc]);
unescape(<<Byte, Rest/binary>>, Acc) when Byte >= 32, Byte =/= $\\ ->
    unescape(Rest, [Byte | Acc]);
unescape(_, _) -> {error, invalid_pane_output}.
