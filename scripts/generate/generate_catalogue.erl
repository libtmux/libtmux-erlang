-module(generate_catalogue).
-moduledoc """
Machinery shared by the tmux catalogue generators: the pinned source manifest,
the command line, the schema and generated-file round trip, and the readers
for tmux's C sources.
""".
-export([main/3, run/3, parse_pins/1, git_source/1, literal/1, search/2, matches/2,
         find/2, value_error/2, ensure/3, field/2, members/1, is_hex/2]).
-export_type([pins/0, source/0, spec/0, options/0]).

-type pins() :: [{Version :: binary(), Commit :: binary()}].
-type source() :: #{read := fun((Commit :: binary(), Path :: binary()) -> binary()),
                    list => fun((Commit :: binary()) -> [binary()]),
                    preprocess => fun((binary()) -> binary())}.
-type spec() :: #{name := string(),
                  schema := string(),
                  refresh := fun((source(), pins()) -> generate_json:json()),
                  validate := fun((generate_json:json(), pins()) -> ok),
                  generate := fun((generate_json:json()) -> [{string(), binary()}]),
                  drift := string(),
                  done => string()}.
-type options() :: #{check := boolean(), refresh_from => file:filename()}.

-define(MANIFEST, "schema/tmux-sources.json").

-doc """
Run a generator from the command line. Exits with status 1 on a refused schema
or generated-file drift and status 2 on a usage error.
""".
-spec main(spec(), file:filename(), [string()]) -> ok.
main(Spec, Root, Arguments) ->
    Options = parse_arguments(Spec, Arguments),
    try run(Spec, Root, Options) of
        ok ->
            case Spec of
                #{done := Done} -> io:format("~ts~n", [Done]);
                _ -> ok
            end;
        {drift, Path} ->
            io:format(standard_error, "~ts: ~ts~n", [maps:get(drift, Spec), Path]),
            erlang:halt(1)
    catch
        error:{value_error, Message} ->
            io:format(standard_error, "error: ~ts~n", [Message]),
            erlang:halt(1)
    end.

-doc """
Refresh the schema when `refresh_from` is set, validate it, then check or write
the generated files. Returns the first file that differs in check mode.
""".
-spec run(spec(), file:filename(), options()) -> ok | {drift, string()}.
run(Spec, Root, Options) ->
    {ok, Manifest} = file:read_file(filename:join(Root, ?MANIFEST)),
    Pins = parse_pins(Manifest),
    Schema = filename:join(Root, maps:get(schema, Spec)),
    case Options of
        #{refresh_from := Tree} ->
            ok = script_util:boot(Root),
            Refreshed = (maps:get(refresh, Spec))(git_source(Tree), Pins),
            ok = file:write_file(Schema, [generate_json:encode(Refreshed), "\n"]);
        _ ->
            ok
    end,
    {ok, Text} = file:read_file(Schema),
    Data = generate_json:decode(Text),
    ok = (maps:get(validate, Spec))(Data, Pins),
    Outputs = (maps:get(generate, Spec))(Data),
    case maps:get(check, Options) of
        true -> drift(Root, Outputs);
        false -> lists:foreach(fun({Path, Content}) ->
                                   ok = file:write_file(filename:join(Root, Path), Content)
                               end, Outputs)
    end.

drift(_, []) -> ok;
drift(Root, [{Path, Content} | Rest]) ->
    case file:read_file(filename:join(Root, Path)) of
        {ok, Content} -> drift(Root, Rest);
        _ -> {drift, Path}
    end.

parse_arguments(Spec, Arguments) ->
    Options = parse_arguments(Spec, Arguments, #{check => false}),
    case Options of
        #{check := true, refresh_from := _} ->
            usage_error(Spec, "refresh and drift checking are separate operations");
        _ -> Options
    end.

parse_arguments(_, [], Options) -> Options;
parse_arguments(Spec, ["--check" | Rest], Options) ->
    parse_arguments(Spec, Rest, Options#{check := true});
parse_arguments(Spec, ["--refresh-from", Tree | Rest], Options) ->
    parse_arguments(Spec, Rest, Options#{refresh_from => filename:absname(Tree)});
parse_arguments(Spec, ["--refresh-from"], _) ->
    usage_error(Spec, "argument --refresh-from: expected one argument");
parse_arguments(Spec, ["--refresh-from=" ++ Tree | Rest], Options) ->
    parse_arguments(Spec, ["--refresh-from", Tree | Rest], Options);
parse_arguments(Spec, [Help | _], _) when Help =:= "-h"; Help =:= "--help" ->
    io:format("~ts~n", [usage(Spec)]),
    erlang:halt(0);
parse_arguments(Spec, [Argument | _], _) ->
    usage_error(Spec, io_lib:format("unrecognized argument: ~ts", [Argument])).

usage(Spec) ->
    ["usage: escript scripts/generate/", maps:get(name, Spec),
     ".erl [-h] [--refresh-from TREE] [--check]"].

-spec usage_error(spec(), term()) -> no_return().
usage_error(Spec, Message) ->
    io:format(standard_error, "~ts~n~ts: error: ~ts~n", [usage(Spec), maps:get(name, Spec),
                                                          Message]),
    erlang:halt(2).

-doc """
Read the pinned source manifest: version 1 with one `commit` per tmux version,
each a 40-digit lowercase hexadecimal Git object name.
""".
-spec parse_pins(binary()) -> pins().
parse_pins(Text) ->
    case generate_json:decode(Text) of
        [{<<"version">>, 1}, {<<"versions">>, [_ | _] = Versions}] ->
            Pins = [pin(Version, Pin) || {Version, Pin} <- Versions],
            case length(lists:usort([V || {V, _} <- Pins])) =:= length(Pins) of
                true -> Pins;
                false -> value_error("duplicate version in ~ts", [?MANIFEST])
            end;
        _ ->
            value_error("~ts must hold only a version and a versions object", [?MANIFEST])
    end.

pin(Version, [{<<"commit">>, Commit}]) ->
    ok = ensure(is_hex(Commit, 40), "invalid commit for tmux ~ts", [Version]),
    {Version, Commit};
pin(Version, _) ->
    value_error("tmux ~ts must pin only a commit", [Version]).

-doc """
Read sources from a local tmux clone with `git show` and `git ls-tree`, and
expand C macros with `cc -E -P`. Run `script_util:boot/1` first.
""".
-spec git_source(file:filename()) -> source().
git_source(Tree) ->
    Git = fun(Arguments) -> script_util:run_ok("git", ["-C", Tree | Arguments], #{}) end,
    #{read => fun(Commit, Path) -> Git(["show", <<Commit/binary, ":", Path/binary>>]) end,
      list => fun(Commit) ->
                  Names = binary:split(Git(["ls-tree", "-z", "--name-only", Commit]),
                                       <<0>>, [global]),
                  [Name || Name <- Names, Name =/= <<>>]
              end,
      preprocess => fun(Text) ->
                        script_util:run_ok("cc", ["-E", "-P", "-x", "c", "-"],
                                           #{stdin => Text})
                    end}.

-doc """
Decode a quoted C string literal. Escapes for backslash, quotes, newline,
carriage return and tab decode; any other escape raises.
""".
-spec literal(binary()) -> binary().
literal(<<$", Body/binary>>) ->
    Size = byte_size(Body) - 1,
    <<Inner:Size/binary, $">> = Body,
    unescape(Inner);
literal(Other) ->
    value_error("not a string literal: ~ts", [Other]).

unescape(<<>>) -> <<>>;
unescape(<<$\\, Char, Rest/binary>>) ->
    Decoded = case Char of
        $n -> $\n;
        $r -> $\r;
        $t -> $\t;
        _ when Char =:= $\\; Char =:= $"; Char =:= $' -> Char;
        _ -> value_error("unsupported escape in string literal: \\~c", [Char])
    end,
    <<Decoded, (unescape(Rest))/binary>>;
unescape(<<Char, Rest/binary>>) ->
    <<Char, (unescape(Rest))/binary>>.

-doc "The capture groups of the first match of `Regex` in `Text`, or `nomatch`.".
-spec search(binary(), iodata() | {iodata(), [atom()]}) -> nomatch | [binary()].
search(Text, {Regex, Options}) ->
    case re:run(Text, Regex, [{capture, all_but_first, binary} | Options]) of
        nomatch -> nomatch;
        {match, Groups} -> Groups
    end;
search(Text, Regex) ->
    search(Text, {Regex, []}).

-doc "Whether `Regex` matches anywhere in `Text`.".
-spec matches(binary(), iodata() | {iodata(), [atom()]}) -> boolean().
matches(Text, {Regex, Options}) ->
    re:run(Text, Regex, [{capture, none} | Options]) =:= match;
matches(Text, Regex) ->
    matches(Text, {Regex, []}).

-doc "The capture groups of every non-overlapping match of `Regex` in `Text`.".
-spec find(binary(), iodata() | {iodata(), [atom()]}) -> [[binary()]].
find(Text, {Regex, Options}) ->
    case re:run(Text, Regex, [global, {capture, all_but_first, binary} | Options]) of
        nomatch -> [];
        {match, Matches} -> Matches
    end;
find(Text, Regex) ->
    find(Text, {Regex, []}).

-doc "Raise the error the generators use for rejected input.".
-spec value_error(io:format(), [term()]) -> no_return().
value_error(Format, Arguments) ->
    error({value_error, iolist_to_binary(io_lib:format(Format, Arguments))}).

-doc "Return `ok` when `Condition` holds, otherwise raise the error for `Format`.".
-spec ensure(boolean(), io:format(), [term()]) -> ok.
ensure(true, _, _) -> ok;
ensure(false, Format, Arguments) -> value_error(Format, Arguments).

-doc "The value of `Key` in a decoded JSON object. Raises when it is absent.".
-spec field(binary(), generate_json:json()) -> generate_json:json().
field(Key, Object) ->
    case lists:keyfind(Key, 1, members(Object)) of
        {Key, Value} -> Value;
        false -> value_error("missing key: ~ts", [Key])
    end.

-doc "The `{Key, Value}` pairs of a decoded JSON object, in file order.".
-spec members(generate_json:json()) -> [{binary(), generate_json:json()}].
members(Empty) when is_map(Empty) -> [];
members([{_, _} | _] = Members) -> Members;
members(Other) -> value_error("expected a JSON object: ~tp", [Other]).

-doc "Whether `Text` is exactly `Length` lowercase hexadecimal digits.".
-spec is_hex(term(), pos_integer()) -> boolean().
is_hex(Text, Length) when is_binary(Text), byte_size(Text) =:= Length ->
    lists:all(fun(Char) -> (Char >= $0 andalso Char =< $9)
                           orelse (Char >= $a andalso Char =< $f) end,
              binary_to_list(Text));
is_hex(_, _) -> false.
