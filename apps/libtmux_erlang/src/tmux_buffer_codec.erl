-module(tmux_buffer_codec).
-moduledoc false.
-export([list/2]).

%% n: counts stored bytes, before q: and the client print layer. Decode
%% those layers first, then frame by length rather than untrusted newlines.
-spec list(binary(), tmux_version:t()) -> {ok, [map()]} | {error, map()}.
list(Output, Version) ->
    case tmux_text_codec:format(Output, Version) of
        {ok, Bytes} -> rows(Bytes, 4096, [], #{});
        {error, _} -> invalid()
    end.

rows(<<>>, _, Acc, _) -> {ok, lists:reverse(Acc)};
rows(_, 0, _, _) -> {error, #{code => buffer_limit, limit => max_rows}};
rows(Bytes, Left, Acc, Seen) ->
    maybe
        {ok, Length, Rest1} ?= uint(Bytes),
        {ok, Size, Rest2} ?= uint(Rest1),
        {ok, Created, Rest3} ?= uint(Rest2),
        case Rest3 of
            <<Name:Length/binary, $\n, Rest/binary>> when Length > 0 ->
                case maps:is_key(Name, Seen) orelse binary:match(Name, <<0>>) =/= nomatch of
                    true -> invalid();
                    false ->
                        Copy = binary:copy(Name),
                        rows(Rest, Left - 1,
                            [#{name => Copy, size => Size, created => Created} | Acc],
                            Seen#{Copy => true})
                end;
            _ -> invalid()
        end
    end.

uint(Bytes) ->
    case binary:split(Bytes, <<":">>) of
        [Digits, Rest] when byte_size(Digits) > 0, byte_size(Digits) =< 20 ->
            case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)) of
                true ->
                    Value = binary_to_integer(Digits),
                    case Value =< 18446744073709551615 of
                        true -> {ok, Value, Rest};
                        false -> invalid()
                    end;
                false -> invalid()
            end;
        _ -> invalid()
    end.

invalid() -> {error, #{code => invalid_buffer_observation}}.
