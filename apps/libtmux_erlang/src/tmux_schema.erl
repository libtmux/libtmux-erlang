-module(tmux_schema).
-moduledoc """
Validate schema-defined observations and normalize scalar values.

Field names come from the generated registry, never record reflection or
payload-created atoms. Text is validated UTF-8; byte fields preserve arbitrary
binaries. Integer normalization uses the shared exact JSON integer range.
""".
-export([fields/1, relations/1, field/2, normalize/2, value/2, operators/1]).
-export_type([entity/0, error_detail/0]).

-type entity() :: session | window | window_link | pane.
-type error_detail() :: #{code := atom(), path := [term()], atom() => term()}.
-define(MAX_INTEGER, 9007199254740991).

-spec fields(entity()) -> {ok, map()} | {error, error_detail()}.
fields(Entity) ->
    case lists:member(Entity, tmux_schema_data:entities()) of
        true -> {ok, tmux_schema_data:fields(Entity)};
        false -> {error, #{code => unknown_entity, path => []}}
    end.

-spec relations(entity()) -> {ok, map()} | {error, error_detail()}.
relations(Entity) ->
    maybe
        {ok, _} ?= fields(Entity),
        {ok, tmux_schema_data:relations(Entity)}
    end.

-spec field(entity(), atom()) -> {ok, map()} | {error, error_detail()}.
field(Entity, Field) ->
    maybe
        {ok, Fields} ?= fields(Entity),
        case maps:find(Field, Fields) of
            {ok, Metadata} -> {ok, Metadata};
            error -> {error, #{code => unknown_field, path => [Field]}}
        end
    end.

-spec normalize(entity(), map()) -> {ok, map()} | {error, error_detail()}.
normalize(Entity, Input) when is_map(Input) ->
    maybe
        {ok, Fields} ?= fields(Entity),
        ok ?= known_keys(maps:keys(Input), Fields),
        {ok, Normalized} ?= observations(lists:sort(maps:to_list(Fields)), Input, #{}),
        derived(Entity, Normalized)
    end;
normalize(_Entity, _Input) ->
    {error, #{code => invalid_object, path => []}}.

-spec value(map(), term()) -> {ok, term()} | {error, error_detail()}.
value(#{nullable := true}, none) ->
    {ok, none};
value(#{type := boolean}, Value) when is_boolean(Value) ->
    {ok, Value};
value(#{type := text} = Metadata, Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> {ok, Value};
        _ -> invalid(Metadata)
    end;
value(#{type := bytes}, Value) when is_binary(Value) ->
    {ok, Value};
value(#{type := Type} = Metadata, Value)
  when Type =:= integer; Type =:= uint ->
    DefaultMinimum = case Type of uint -> 0; integer -> -?MAX_INTEGER end,
    Minimum = maps:get(minimum, Metadata, DefaultMinimum),
    case Value of
        Integer when is_integer(Integer, Minimum, ?MAX_INTEGER) -> {ok, Integer};
        Float when is_float(Float), Float >= Minimum, Float =< ?MAX_INTEGER ->
            Integer = trunc(Float),
            case Integer == Float of
                true -> {ok, Integer};
                false -> invalid(Metadata)
            end;
        _ -> invalid(Metadata)
    end;
value(#{type := Type} = Metadata, Value)
  when Type =:= pane_id; Type =:= window_id; Type =:= session_id ->
    Prefix = case Type of pane_id -> $%; window_id -> $@; session_id -> $$ end,
    case valid_id(Prefix, Value) of
        true -> {ok, Value};
        false -> invalid(Metadata)
    end;
value(Metadata, _Value) ->
    invalid(Metadata).

-spec operators(map()) -> [atom()].
operators(#{type := Type, nullable := Nullable}) ->
    Base = [equals, 'not', in, not_in],
    Typed = case Type of
        uint -> [lt, lte, gt, gte];
        integer -> [lt, lte, gt, gte];
        text -> [contains, starts_with, ends_with, regex];
        bytes -> [contains, starts_with, ends_with];
        _ -> []
    end,
    Base ++ Typed ++ case Nullable of true -> [present]; false -> [] end.

known_keys([], _Fields) -> ok;
known_keys([Key | Rest], Fields) ->
    case maps:is_key(Key, Fields) of
        true -> known_keys(Rest, Fields);
        false -> {error, #{code => unknown_field, path => [Key]}}
    end.

observations([], _Input, Accumulator) -> {ok, Accumulator};
observations([{Name, Metadata} | Rest], Input, Accumulator) ->
    Raw = maps:get(Name, Input, not_loaded),
    case observation(Metadata, Raw) of
        {ok, Value} -> observations(Rest, Input, Accumulator#{Name => Value});
        {error, Detail} -> {error, Detail#{path => [Name]}}
    end.

observation(#{required := true}, Value)
  when Value =:= not_loaded; Value =:= unavailable ->
    {error, #{code => required_field, path => []}};
observation(_Metadata, Value) when Value =:= not_loaded; Value =:= unavailable ->
    {ok, Value};
observation(Metadata, Value) ->
    value(Metadata, Value).

derived(session, #{attached_count := Count, attached := Attached} = Fields)
  when is_integer(Count) ->
    Expected = Count > 0,
    case Attached of
        not_loaded -> {ok, Fields#{attached => Expected}};
        Expected -> {ok, Fields};
        _ -> {error, #{code => inconsistent_derived_value, path => [attached]}}
    end;
derived(_Entity, Fields) ->
    {ok, Fields}.

invalid(#{type := Type}) ->
    {error, #{code => invalid_value, path => [], expected => Type}}.

valid_id(Prefix, <<Prefix, Digits/binary>>) when byte_size(Digits) =< 32 ->
    case Digits of
        <<"0">> -> true;
        <<First, Rest/binary>> when First >= $1, First =< $9 -> digits(Rest);
        _ -> false
    end;
valid_id(_Prefix, _Value) -> false.

digits(<<>>) -> true;
digits(<<Digit, Rest/binary>>) when Digit >= $0, Digit =< $9 -> digits(Rest);
digits(_) -> false.
