-module(tmux_version).
-moduledoc """
Parse the output of tmux -V without invoking tmux.

Support covers tmux 3.3a through 3.8, including intermediate releases.
Comparisons order development builds, numbered release candidates, stable
releases and letter patches. CI tests the endpoints of the supported range. Use
`tmux_server:version/1` for the daemon version observed by an endpoint.
""".
-export([parse/1, require/1, at_least/2, format/1, floor/0]).
-export_type([t/0, minimum/0]).

-doc """
Parsed release components and original output. `candidate` holds the RC number
for a prerelease and `none` for a stable, patched or development build.
""".
-type t() :: #{major := non_neg_integer(), minor := non_neg_integer(),
               patch := binary(), tracking := boolean(),
               candidate := none | pos_integer(), raw := binary()}.
-doc "A stable major/minor floor, or a version spelling with an optional tmux prefix.".
-type minimum() :: {non_neg_integer(), non_neg_integer()} | binary().

-doc "Return the earliest release supported by the library.".
-spec floor() -> binary().
floor() -> <<"3.3a">>.

-doc """
Parse bounded tmux -V output. A release candidate has a positive numeric suffix,
such as 3.8-rc2. Tracking builds cannot also carry a patch or RC suffix.
This performs no I/O and does not qualify a release.
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
            case suffix(MinorPatch) of
                {ok, Minor, Patch, Candidate} when
                    not Tracking orelse (Patch =:= <<>> andalso Candidate =:= none) ->
                    case digits(Major) of
                        true ->
                            {ok, #{major => binary_to_integer(Major),
                                   minor => binary_to_integer(Minor),
                                   patch => Patch, tracking => Tracking,
                                   candidate => Candidate, raw => Raw}};
                        false -> {error, {invalid_tmux_version, Raw}}
                    end;
                _ -> {error, {invalid_tmux_version, Raw}}
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
        case at_least(Version, floor()) of
            true -> {ok, Version};
            false -> {error, {unsupported_tmux_version, Version}}
        end
    end.

-doc """
Compare release stages and numeric components. `next-3.8` comes before
`3.8-rc1`, then `3.8` and `3.8a`. A numeric pair names a stable release.
A binary minimum can name a patch or RC. An invalid spelling raises `badarg`.
This performs no I/O and does not establish runtime qualification.
""".
-spec at_least(t(), minimum()) -> boolean().
at_least(Version, {Major, Minor})
  when is_integer(Major), Major >= 0, is_integer(Minor), Minor >= 0 ->
    rank(Version) >= {Major, Minor, 2, 0, <<>>};
at_least(Version, Minimum) when is_binary(Minimum) ->
    Raw = case Minimum of
        <<"tmux ", _/binary>> -> Minimum;
        _ -> <<"tmux ", Minimum/binary>>
    end,
    case parse(Raw) of
        {ok, Required} -> rank(Version) >= rank(Required);
        {error, _} -> error(badarg)
    end.

-doc "Render a parsed version spelling without the tmux prefix or newline.".
-spec format(t()) -> binary().
format(#{major := Major, minor := Minor, patch := Patch, tracking := Tracking} = Version) ->
    Prefix = case Tracking of true -> <<"next-">>; false -> <<>> end,
    Suffix = case maps:get(candidate, Version, none) of
        none -> Patch;
        Candidate -> <<"-rc", (integer_to_binary(Candidate))/binary>>
    end,
    <<Prefix/binary, (integer_to_binary(Major))/binary, $.,
      (integer_to_binary(Minor))/binary, Suffix/binary>>.

rank(#{major := Major, minor := Minor, patch := Patch, tracking := Tracking} = Version) ->
    case {Tracking, maps:get(candidate, Version, none)} of
        {true, none} -> {Major, Minor, 0, 0, <<>>};
        {false, Candidate} when is_integer(Candidate) -> {Major, Minor, 1, Candidate, <<>>};
        {false, none} -> {Major, Minor, 2, 0, Patch}
    end.

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

suffix(Text) ->
    case binary:split(Text, <<"-rc">>, [global]) of
        [Stable] ->
            {Minor, Patch} = split_patch(Stable),
            case digits(Minor) of
                true -> {ok, Minor, Patch, none};
                false -> error
            end;
        [Minor, Candidate] ->
            case digits(Minor) andalso digits(Candidate) of
                true ->
                    case binary_to_integer(Candidate) of
                        N when N > 0 -> {ok, Minor, <<>>, N};
                        _ -> error
                    end;
                false -> error
            end;
        _ -> error
    end.

digits(<<>>) -> false;
digits(Text) -> digits_tail(Text).

digits_tail(<<>>) -> true;
digits_tail(<<C, Rest/binary>>) when C >= $0, C =< $9 -> digits_tail(Rest);
digits_tail(_) -> false.
