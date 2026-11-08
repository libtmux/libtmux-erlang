-module(tmux_args).
-moduledoc false.
-export([options/2, options/3, launch_options/2, respawn_options/1]).
-type schema() :: [{atom(), atom(), binary()}].

-spec options(map(), schema()) -> {ok, [binary()]} | {error, map()}.
options(Options, Schema) when is_map(Options) ->
    Allowed = [Key || {Key, _, _} <- Schema],
    case maps:keys(maps:without(Allowed, Options)) of
        [] -> fields(Schema, Options, []);
        Unknown -> {error, #{code => unknown_option, path => [hd(lists:sort(Unknown))]}}
    end;
options(_, _) -> {error, #{code => invalid_options, path => []}}.

-spec options(map(), schema(), map()) -> {ok, [binary()]} | {error, map()}.
options(Options, Schema, Defaults) when is_map(Options) ->
    options(maps:merge(Defaults, Options), Schema);
options(_, _, _) -> {error, #{code => invalid_options, path => []}}.

-spec launch_options(map(), schema()) -> {ok, [binary()], [binary()]} | {error, map()}.
launch_options(Options, Extra) when is_map(Options) ->
    Schema = [{detach, flag, <<"-d">>}, {cwd, format, <<"-c">>},
              {env, environment, <<"-e">>} | Extra],
    maybe
        {ok, Flags} ?= options(maps:merge(#{detach => true}, maps:remove(launch, Options)), Schema),
        {ok, Launch} ?= tmux_command:launch(maps:get(launch, Options, default_shell)),
        {ok, Flags, Launch}
    end;
launch_options(_, _) -> {error, #{code => invalid_options, path => []}}.

-spec respawn_options(map()) -> {ok, [binary()], [binary()]} | {error, map()}.
respawn_options(Options) when is_map(Options) ->
    maybe
        {ok, Flags} ?= options(maps:remove(launch, Options),
            [{force, flag, <<"-k">>}, {cwd, format, <<"-c">>}, {env, environment, <<"-e">>}]),
        {ok, Launch} ?= case maps:get(launch, Options, previous) of
            previous -> {ok, []};
            Spec when is_map(Spec) -> tmux_command:launch(Spec);
            _ -> {error, #{code => invalid_launch}}
        end,
        {ok, Flags, Launch}
    end;
respawn_options(_) -> {error, #{code => invalid_options, path => []}}.

fields([], _, Acc) -> {ok, lists:append(lists:reverse(Acc))};
fields([{Key, Kind, Flag} | Rest], Options, Acc) ->
    case maps:find(Key, Options) of
        error -> fields(Rest, Options, Acc);
        {ok, Value} ->
            case encode(Kind, Flag, Value) of
                {ok, Args} -> fields(Rest, Options, [Args | Acc]);
                {error, Detail} -> {error, Detail#{path => [Key]}}
            end
    end.

encode(flag, Flag, true) -> {ok, [Flag]};
encode(flag, _, false) -> {ok, []};
encode(boolean, _, Value) when is_boolean(Value) -> {ok, []};
encode(bytes, Flag, Value) when is_binary(Value), byte_size(Value) =< 32768 ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, [Flag, Value]};
        _ -> {error, #{code => invalid_option}}
    end;
encode(key_table, Flag, Value)
  when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 1024 ->
    encode(bytes, Flag, Value);
encode(text, Flag, Value) ->
    maybe
        {ok, _} ?= tmux_schema:value(#{type => text}, Value),
        encode(bytes, Flag, Value)
    end;
encode(text_format, Flag, Value) ->
    maybe
        {ok, _} ?= tmux_schema:value(#{type => text}, Value),
        encode(format, Flag, Value)
    end;
encode(format, Flag, Value) ->
    maybe
        {ok, Literal} ?= tmux_command:literal_format(Value),
        {ok, [Flag, Literal]}
    end;
encode(dimension, Flag, Value) when is_integer(Value, 1, 65535) ->
    {ok, [Flag, integer_to_binary(Value)]};
encode(direction, _, horizontal) -> {ok, [<<"-h">>]};
encode(direction, _, vertical) -> {ok, [<<"-v">>]};
encode(pipe_direction, _, output) -> {ok, [<<"-O">>]};
encode(pipe_direction, _, input) -> {ok, [<<"-I">>]};
encode(pipe_direction, _, both) -> {ok, [<<"-I">>, <<"-O">>]};
encode(size, Flag, {percent, Value}) when is_integer(Value, 1, 100) ->
    {ok, [Flag, <<(integer_to_binary(Value))/binary, $%>>]};
encode(size, Flag, {cells, Value}) when is_integer(Value, 1, 2147483647) ->
    {ok, [Flag, integer_to_binary(Value)]};
encode(coordinate, Flag, all) -> {ok, [Flag, <<"-">>]};
encode(coordinate, Flag, Value) when is_integer(Value, -2147483648, 32767) ->
    {ok, [Flag, integer_to_binary(Value)]};
encode(environment, Flag, Values) when is_map(Values), map_size(Values) =< 256 ->
    environment(lists:sort(maps:to_list(Values)), Flag, []);
encode(_, _, _) -> {error, #{code => invalid_option}}.

environment([], _, Acc) -> {ok, lists:append(lists:reverse(Acc))};
environment([{Key, Value} | Rest], Flag, Acc)
  when is_binary(Key), byte_size(Key) > 0, is_binary(Value) ->
    case byte_size(Key) + byte_size(Value) < 32768 andalso
         binary:match(Key, [<<0>>, <<"=">>]) =:= nomatch andalso
         binary:match(Value, <<0>>) =:= nomatch of
        true -> environment(Rest, Flag, [[Flag, <<Key/binary, $=, Value/binary>>] | Acc]);
        false -> {error, #{code => invalid_environment}}
    end;
environment(_, _, _) -> {error, #{code => invalid_environment}}.
