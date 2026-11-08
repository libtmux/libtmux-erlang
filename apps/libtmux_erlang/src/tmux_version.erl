-module(tmux_version).
-moduledoc """
Parse the output of tmux -V without invoking tmux.

Support covers tmux 3.3a through 3.8, including intermediate releases. The
minimum-version check includes the patch letter; numeric feature comparisons
use major/minor components. CI tests the endpoints of the supported range. Use
`tmux_server:version/1` for the daemon version observed by an endpoint.
""".
-export([parse/1, require/1, at_least/2]).
-export_type([t/0]).

-doc """
Parsed numeric daemon version plus patch, tracking and original-output
metadata.
""".
-type t() :: #{major := non_neg_integer(), minor := non_neg_integer(),
               patch := binary(), tracking := boolean(), raw := binary()}.

-doc """
Parse bounded tmux -V output into numeric components and patch/tracking
metadata. This is pure parsing, not a probe or compatibility qualification.
""".
-spec parse(binary()) -> {ok, t()} | {error, {invalid_tmux_version, term()}}.
parse(<<"tmux ", Text/binary>> = Raw) when byte_size(Raw) =< 64 ->
    {Name, Tracking} = case trim_newline(Text) of
        <<"next-", Rest/binary>> -> {Rest, true};
        Rest -> {Rest, false}
    end,
    case binary:split(Name, <<".">>, [global]) of
        [Major, MinorPatch] when byte_size(Major) > 0,
                                byte_size(MinorPatch) > 0 ->
            {Minor, Patch} = split_patch(MinorPatch),
            case digits(Major) andalso digits(Minor) of
                true ->
                    {ok, #{major => binary_to_integer(Major),
                           minor => binary_to_integer(Minor),
                           patch => Patch, tracking => Tracking, raw => Raw}};
                false -> {error, {invalid_tmux_version, Raw}}
            end;
        _ -> {error, {invalid_tmux_version, Raw}}
    end;
parse(Raw) ->
    {error, {invalid_tmux_version, Raw}}.

-doc """
Reject a tmux release below the supported floor.

```erlang
1> {ok, Version} = tmux_version:require(<<"tmux 3.3a">>), ok.
ok
2> tmux_version:at_least(Version, {3, 4}).
false
```
""".
-spec require(binary()) ->
    {ok, t()} | {error, {invalid_tmux_version | unsupported_tmux_version, term()}}.
require(Raw) ->
    maybe
        {ok, Version} ?= parse(Raw),
        #{major := Major, minor := Minor, patch := Patch} = Version,
        case {Major, Minor, Patch} >= {3, 3, <<"a">>} of
            true -> {ok, Version};
            false -> {error, {unsupported_tmux_version, Version}}
        end
    end.

-doc """
Compare numeric major/minor components with a required floor. Patch letters do
not promote an older minor release. Performs no I/O.
""".
-spec at_least(t(), {non_neg_integer(), non_neg_integer()}) -> boolean().
at_least(#{major := Major, minor := Minor}, {RequiredMajor, RequiredMinor}) ->
    {Major, Minor} >= {RequiredMajor, RequiredMinor}.

trim_newline(<<>>) -> <<>>;
trim_newline(Text) ->
    case binary:last(Text) of
        10 -> binary:part(Text, 0, byte_size(Text) - 1);
        _ -> Text
    end.

split_patch(Text) ->
    Last = binary:last(Text),
    case Last >= $a andalso Last =< $z of
        true -> {binary:part(Text, 0, byte_size(Text) - 1), <<Last>>};
        false -> {Text, <<>>}
    end.

digits(<<>>) -> false;
digits(Text) -> digits_tail(Text).

digits_tail(<<>>) -> true;
digits_tail(<<C, Rest/binary>>) when C >= $0, C =< $9 -> digits_tail(Rest);
digits_tail(_) -> false.
