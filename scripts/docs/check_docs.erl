% Check guide links, source excerpts, configuration terms and example output.
-module(check_docs).
-mode(compile).
-moduledoc """
Checks the guide corpus (README.md, docs/*.md, apps/*/README.md) and, with
`--html-directory`, a rendered documentation tree.

```console
$ escript scripts/docs/check_docs.erl
```

Run it from the repository root. It verifies relative links and heading
anchors, `<!-- example: path -->` excerpts against their source files or
named regions selected with `path#region`,
`example-input` and `example-output` JSON blocks, one command per `console`
block, Erlang term blocks with `file:consult/1`, and the width of numbered
prompts in native `-moduledoc` examples. `--examples-receipt FILE` also
compares displayed output with the runtime example receipt. `--html-directory
DIR` checks links, anchors, resources and source links of a rendered tree.

The receipt goes to `_build/checks/docs-corpus.json`,
`docs-corpus-runtime.json` or `docs-rendered.json` and to standard output.
The exit status is 1 when a check fails.
""".
-export([main/1, check/2, columns/1]).
-export_type([options/0]).
-include_lib("kernel/include/file.hrl").

-type options() :: #{examples_receipt => file:filename_all(),
                     html_directory => file:filename_all()}.

-doc "Entry point: `[--examples-receipt FILE] [--html-directory DIR]`.".
-spec main([string()]) -> no_return().
main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    case parse(Arguments, #{}) of
        {ok, Options} ->
            ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
            case maps:is_key(html_directory, Options) of
                true ->
                    ok = require([docs_util, script_util, check_rendered_docs]),
                    ok = script_util:boot(Root);
                false -> ok = require([docs_util])
            end,
            try check(Root, Options) of
                Receipt ->
                    io:format("~ts~n", [docs_util:json_text(Receipt)]),
                    halt(0)
            catch
                error:{docs_check, Where, Reason} ->
                    io:format(standard_error, "check_docs: ~ts: ~tw~n", [Where, Reason]),
                    halt(1);
                Class:Reason:Stack ->
                    io:format(standard_error, "check_docs: ~p:~p~n~p~n", [Class, Reason, Stack]),
                    halt(1)
            end;
        error ->
            io:format(standard_error, "usage: check_docs.erl "
                      "[--examples-receipt FILE] [--html-directory DIR]~n", []),
            halt(2)
    end.

% The helpers are built by `rebar3 compile`; say so instead of failing with undef.
require(Modules) ->
    case [Module || Module <- Modules, code:ensure_loaded(Module) =/= {module, Module}] of
        [] -> ok;
        Missing ->
            io:format(standard_error, "check_docs: ~p not found; run rebar3 compile first~n",
                      [Missing]),
            halt(2)
    end.

parse([], Options) -> {ok, Options};
parse(["--examples-receipt", Path | Rest], Options) ->
    parse(Rest, Options#{examples_receipt => Path});
parse(["--html-directory", Path | Rest], Options) ->
    parse(Rest, Options#{html_directory => Path});
parse(_, _) -> error.

-doc """
Check the corpus below `Root` and write and return its receipt. Raises
`{docs_check, Where, Reason}` for the first failed check.
""".
-spec check(file:filename_all(), options()) -> docs_util:json().
check(Root0, Options) ->
    Started = erlang:monotonic_time(microsecond),
    Root = docs_util:resolve(Root0),
    Files = [<<"README.md">> | docs_util:wildcard(Root, "docs/*.md")
                               ++ docs_util:wildcard(Root, "apps/*/README.md")],
    Outputs = examples_receipt(Root, Options),
    Native = native_lines(Root),
    State0 = #{programs => [], terms => [], displayed => [], inputs => [], console => 0,
               slugs => #{}},
    State = lists:foldl(fun(File, Acc) -> check_file(Root, File, Outputs, Acc) end,
                        State0, Files),
    Terms = lists:reverse(maps:get(terms, State)),
    TermsFile = filename:join(Root, "_build/checks/doc-terms.config"),
    docs_util:write_file(TermsFile, lists:join(<<"\n">>, Terms)),
    case file:consult(TermsFile) of
        {ok, _} -> ok;
        {error, Error} -> docs_util:fail(<<"doc-terms.config">>, {invalid_erlang_terms, Error})
    end,
    Receipt = [{<<"result">>, <<"PASS">>},
               {<<"files">>, length(Files)},
               {<<"programs">>, lists:usort(maps:get(programs, State))},
               {<<"configuration_blocks">>, length(Terms)},
               {<<"console_units">>, maps:get(console, State)},
               {<<"native_code_lines">>, Native},
               {<<"input_files">>, lists:usort(maps:get(inputs, State))},
               {<<"displayed_outputs">>, lists:reverse(maps:get(displayed, State))},
               {<<"runtime_output">>, case Outputs of
                   none -> <<"UNVERIFIED in this static check">>;
                   _ -> <<"PASS">>
               end},
               {<<"seconds">>, seconds(Started)}],
    {Name, Final} = case maps:find(html_directory, Options) of
        {ok, Directory} ->
            Rendered = check_rendered_docs:check(filename:absname(Directory, Root), Root),
            {<<"docs-rendered.json">>,
             lists:keystore(<<"seconds">>, 1, Receipt, {<<"seconds">>, seconds(Started)})
                 ++ [{<<"rendered">>, Rendered}]};
        error when Outputs =:= none -> {<<"docs-corpus.json">>, Receipt};
        error -> {<<"docs-corpus-runtime.json">>, Receipt}
    end,
    Result = {object, Final},
    docs_util:write_file(filename:join([Root, "_build/checks", Name]),
                         [docs_util:json_text(Result), $\n]),
    Result.

seconds(Started) ->
    (erlang:monotonic_time(microsecond) - Started) / 1.0e6.

read(Root, Path) ->
    {ok, Binary} = file:read_file(filename:join(Root, Path)),
    Binary.

examples_receipt(Root, #{examples_receipt := Path}) ->
    {ok, Binary} = file:read_file(filename:absname(Path, Root)),
    Receipt = json:decode(Binary),
    Result = maps:get(<<"result">>, Receipt, missing),
    Result =:= <<"PASS">> orelse docs_util:fail(<<"examples receipt">>, {result_not_pass, Result}),
    lists:foldl(fun(#{<<"module">> := Module, <<"output">> := Output} = Example, Acc) ->
        complete(Example) orelse docs_util:fail(<<"examples receipt">>, {incomplete_cleanup, Module}),
        Acc#{Module => Output}
    end, #{}, maps:get(<<"examples">>, Receipt));
examples_receipt(_, _) -> none.

complete(#{<<"owned_cleanup">> := <<"complete">>, <<"sessions_removed">> := Removed}) ->
    truthy(Removed);
complete(_) -> false.

truthy(false) -> false;
truthy(null) -> false;
truthy(Number) when is_number(Number) -> Number /= 0;
truthy([]) -> false;
truthy(<<>>) -> false;
truthy(Map) when is_map(Map) -> map_size(Map) > 0;
truthy(_) -> true.

native_lines(Root) ->
    lists:foldl(fun(Source, Count) ->
        Text = read(Root, Source),
        lists:foldl(fun({_, _, Body}, Inner) ->
            lists:foldl(fun(Line, Lines) ->
                case prompt(Line) of
                    true ->
                        columns(Line) =< 80
                            orelse docs_util:fail(Source, {native_example_wider_than_80, Line}),
                        Lines + 1;
                    false -> Lines
                end
            end, Inner, docs_util:splitlines(Body))
        end, Count, fenced(Text, fun(Language) -> Language =:= <<"erlang">> end))
    end, 0, docs_util:wildcard(Root, "apps/*/src/*.erl")).

% ct_doctest numbers its prompts; replies are compared output, not code.
prompt(Line) -> prompt_body(string:trim(Line, leading)).

prompt_body(<<"...> ", _/binary>>) -> true;
prompt_body(Line) -> numbered(Line, 0).

numbered(<<Digit, Rest/binary>>, Count) when Digit >= $0, Digit =< $9 ->
    numbered(Rest, Count + 1);
numbered(<<"> ", _/binary>>, Count) -> Count > 0;
numbered(_, _) -> false.

-doc """
Number of terminal columns `Text` occupies: East Asian Wide and Fullwidth
code points take two and every other code point one. This is the measure of
the `check-example-width` action of libtmux/.github.
""".
-spec columns(unicode:unicode_binary()) -> non_neg_integer().
columns(Text) -> columns(Text, 0).

columns(<<>>, Count) -> Count;
columns(<<C/utf8, Rest/binary>>, Count) -> columns(Rest, Count + width(C)).

width(C) when C < 16#1100 -> 1;
width(C) -> case wide(C, ranges()) of true -> 2; false -> 1 end.

wide(_, []) -> false;
wide(C, [{Low, _} | _]) when C < Low -> false;
wide(C, [{_, High} | _]) when C =< High -> true;
wide(C, [_ | Rest]) -> wide(C, Rest).

% East Asian Width W and F ranges, Unicode 16.0.0 (EastAsianWidth.txt).
ranges() ->
    [{16#1100, 16#115F}, {16#231A, 16#231B}, {16#2329, 16#232A}, {16#23E9, 16#23EC},
     {16#23F0, 16#23F0}, {16#23F3, 16#23F3}, {16#25FD, 16#25FE}, {16#2614, 16#2615},
     {16#2630, 16#2637}, {16#2648, 16#2653}, {16#267F, 16#267F}, {16#268A, 16#268F},
     {16#2693, 16#2693}, {16#26A1, 16#26A1}, {16#26AA, 16#26AB}, {16#26BD, 16#26BE},
     {16#26C4, 16#26C5}, {16#26CE, 16#26CE}, {16#26D4, 16#26D4}, {16#26EA, 16#26EA},
     {16#26F2, 16#26F3}, {16#26F5, 16#26F5}, {16#26FA, 16#26FA}, {16#26FD, 16#26FD},
     {16#2705, 16#2705}, {16#270A, 16#270B}, {16#2728, 16#2728}, {16#274C, 16#274C},
     {16#274E, 16#274E}, {16#2753, 16#2755}, {16#2757, 16#2757}, {16#2795, 16#2797},
     {16#27B0, 16#27B0}, {16#27BF, 16#27BF}, {16#2B1B, 16#2B1C}, {16#2B50, 16#2B50},
     {16#2B55, 16#2B55}, {16#2E80, 16#2E99}, {16#2E9B, 16#2EF3}, {16#2F00, 16#2FD5},
     {16#2FF0, 16#303E}, {16#3041, 16#3096}, {16#3099, 16#30FF}, {16#3105, 16#312F},
     {16#3131, 16#318E}, {16#3190, 16#31E5}, {16#31EF, 16#321E}, {16#3220, 16#3247},
     {16#3250, 16#A48C}, {16#A490, 16#A4C6}, {16#A960, 16#A97C}, {16#AC00, 16#D7A3},
     {16#F900, 16#FAFF}, {16#FE10, 16#FE19}, {16#FE30, 16#FE52}, {16#FE54, 16#FE66},
     {16#FE68, 16#FE6B}, {16#FF01, 16#FF60}, {16#FFE0, 16#FFE6}, {16#16FE0, 16#16FE4},
     {16#16FF0, 16#16FF1}, {16#17000, 16#187F7}, {16#18800, 16#18CD5},
     {16#18CFF, 16#18D08}, {16#1AFF0, 16#1AFF3}, {16#1AFF5, 16#1AFFB},
     {16#1AFFD, 16#1AFFE}, {16#1B000, 16#1B122}, {16#1B132, 16#1B132},
     {16#1B150, 16#1B152}, {16#1B155, 16#1B155}, {16#1B164, 16#1B167},
     {16#1B170, 16#1B2FB}, {16#1D300, 16#1D356}, {16#1D360, 16#1D376},
     {16#1F004, 16#1F004}, {16#1F0CF, 16#1F0CF}, {16#1F18E, 16#1F18E},
     {16#1F191, 16#1F19A}, {16#1F200, 16#1F202}, {16#1F210, 16#1F23B},
     {16#1F240, 16#1F248}, {16#1F250, 16#1F251}, {16#1F260, 16#1F265},
     {16#1F300, 16#1F320}, {16#1F32D, 16#1F335}, {16#1F337, 16#1F37C},
     {16#1F37E, 16#1F393}, {16#1F3A0, 16#1F3CA}, {16#1F3CF, 16#1F3D3},
     {16#1F3E0, 16#1F3F0}, {16#1F3F4, 16#1F3F4}, {16#1F3F8, 16#1F43E},
     {16#1F440, 16#1F440}, {16#1F442, 16#1F4FC}, {16#1F4FF, 16#1F53D},
     {16#1F54B, 16#1F54E}, {16#1F550, 16#1F567}, {16#1F57A, 16#1F57A},
     {16#1F595, 16#1F596}, {16#1F5A4, 16#1F5A4}, {16#1F5FB, 16#1F64F},
     {16#1F680, 16#1F6C5}, {16#1F6CC, 16#1F6CC}, {16#1F6D0, 16#1F6D2},
     {16#1F6D5, 16#1F6D7}, {16#1F6DC, 16#1F6DF}, {16#1F6EB, 16#1F6EC},
     {16#1F6F4, 16#1F6FC}, {16#1F7E0, 16#1F7EB}, {16#1F7F0, 16#1F7F0},
     {16#1F90C, 16#1F93A}, {16#1F93C, 16#1F945}, {16#1F947, 16#1F9FF},
     {16#1FA70, 16#1FA7C}, {16#1FA80, 16#1FA89}, {16#1FA8F, 16#1FAC6},
     {16#1FACE, 16#1FADC}, {16#1FADF, 16#1FAE9}, {16#1FAF0, 16#1FAF8},
     {16#20000, 16#2FFFD}, {16#30000, 16#3FFFD}].

% Fenced code blocks as {offset of the opening fence, language, body}. A fence
% is a line that starts with three backticks; an indented one is not.
fenced(Text, Accept) ->
    Starts = case Text of
        <<"```", _/binary>> -> [0];
        _ -> []
    end ++ [Position + 1 || {Position, _} <- binary:matches(Text, <<"\n```">>)],
    fenced(Starts, Text, Accept, closed, []).

fenced([], _, _, _, Blocks) -> lists:reverse(Blocks);
fenced([Start | Rest], Text, Accept, closed, Blocks) ->
    case binary:match(Text, <<"\n">>, [{scope, {Start, byte_size(Text) - Start}}]) of
        {Eol, _} ->
            Language = binary:part(Text, Start + 3, Eol - Start - 3),
            case Accept(Language) of
                true -> fenced(Rest, Text, Accept, {Start, Language, Eol + 1}, Blocks);
                false -> fenced(Rest, Text, Accept, closed, Blocks)
            end;
        nomatch -> lists:reverse(Blocks)
    end;
fenced([Start | Rest], Text, Accept, {Opened, Language, BodyStart}, Blocks) ->
    Body = binary:part(Text, BodyStart, Start - BodyStart),
    fenced(Rest, Text, Accept, closed, [{Opened, Language, Body} | Blocks]).

check_file(Root, File, Outputs, State0) ->
    Text = read(Root, File),
    State = lists:foldl(fun(Target, Acc) -> check_link(Root, File, Target, Acc) end,
                        State0, link_targets(Text)),
    lists:foldl(fun({Start, Language, Body}, Acc) ->
        check_block(Root, File, Text, Start, Language, Body, Outputs, Acc)
    end, State, fenced(Text, fun(_) -> true end)).

link_targets(Text) ->
    case re:run(Text, "(?<!!)\\[[^\\]]+\\]\\(([^)]+)\\)", [global, {capture, [1], binary}]) of
        {match, Found} -> [Target || [Target] <- Found];
        nomatch -> []
    end.

check_link(Root, File, Target, State) ->
    case Target of
        <<"https:", _/binary>> -> State;
        <<"http:", _/binary>> -> State;
        <<"mailto:", _/binary>> -> State;
        <<"#", _/binary>> -> State;
        _ ->
            {Name, Fragment} = case binary:split(Target, <<"#">>) of
                [N, F] -> {N, F};
                [N] -> {N, <<>>}
            end,
            Resolved = docs_util:resolve(filename:join([Root, filename:dirname(File), Name])),
            (docs_util:is_within(Root, Resolved) andalso
                 element(1, file:read_file_info(Resolved)) =:= ok)
                orelse docs_util:fail(File, {missing_link_target, Target}),
            case Fragment =/= <<>> andalso filename:extension(Resolved) =:= <<".md">> of
                true -> check_fragment(File, Target, Fragment, Resolved, State);
                false -> State
            end
    end.

check_fragment(File, Target, Fragment, Resolved, #{slugs := Cache} = State) ->
    {Slugs, Cached} = case Cache of
        #{Resolved := Known} -> {Known, Cache};
        _ ->
            {ok, Text} = file:read_file(Resolved),
            Computed = slugs(Text),
            {Computed, Cache#{Resolved => Computed}}
    end,
    lists:member(Fragment, Slugs) orelse docs_util:fail(File, {missing_fragment, Target}),
    State#{slugs := Cached}.

slugs(Text) ->
    case re:run(Text, "^#{1,6}\\s+(.+)$", [multiline, unicode, global, {capture, [1], binary}]) of
        {match, Headings} -> [slug(Heading) || [Heading] <- Headings];
        nomatch -> []
    end.

slug(Heading) ->
    Kept = re:replace(string:lowercase(Heading), "[^\\w\\- ]", "",
                      [global, unicode, ucp, {return, binary}]),
    binary:replace(Kept, <<" ">>, <<"-">>, [global]).

check_block(Root, File, Text, Start, Language, Body, Outputs, State) ->
    Before = before(Text, Start),
    case Language of
        <<"erlang">> -> erlang_block(Root, File, Before, Body, State);
        <<"json">> -> json_block(Root, File, Before, Body, Outputs, State);
        <<"console">> ->
            console_unit(Body) orelse docs_util:fail(File, {console_unit, Body}),
            State#{console := maps:get(console, State) + 1};
        _ -> docs_util:fail(File, {unclassified_code_block, Language})
    end.

% One shell command per block: the block starts with a prompt and no line after
% the first does.
console_unit(<<"$ ", _/binary>> = Body) -> binary:match(Body, <<"\n$ ">>) =:= nomatch;
console_unit(_) -> false.

% The text before a block without trailing whitespace, reduced to its last line.
before(Text, Start) ->
    End = trim_end(Text, Start),
    LineStart = line_start(Text, End),
    binary:part(Text, LineStart, End - LineStart).

trim_end(Text, End) when End > 0 ->
    case binary:at(Text, End - 1) of
        C when C =:= $\s; C =:= $\n; C =:= $\t; C =:= $\r; C =:= $\f; C =:= $\v ->
            trim_end(Text, End - 1);
        _ -> End
    end;
trim_end(_, End) -> End.

line_start(Text, End) when End > 0 ->
    case binary:at(Text, End - 1) of
        $\n -> End;
        _ -> line_start(Text, End - 1)
    end;
line_start(_, End) -> End.

marker(Before, Kind) ->
    Pattern = ["<!-- ", Kind, ": ([^ ]+) -->$"],
    case re:run(Before, Pattern, [{capture, all_but_first, binary}]) of
        {match, [Value]} -> {ok, Value};
        nomatch -> error
    end.

erlang_block(Root, File, Before, Body, #{programs := Programs, terms := Terms} = State) ->
    case marker(Before, "example") of
        {ok, Source} ->
            Current = example_source(Root, Source),
            (Current =/= missing andalso trim(Body) =:= trim(Current))
                orelse docs_util:fail(File, {example_drift, Source}),
            State#{programs := [Source | Programs]};
        error ->
            ends_with(Before, <<"<!-- erlang-term -->">>)
                orelse docs_util:fail(File, unclassified_erlang_block),
            State#{terms := [Body | Terms]}
    end.

example_source(Root, Reference) ->
    [Source | Region] = binary:split(Reference, <<"#">>, [global]),
    Path = filename:join(Root, Source),
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular}} ->
            {ok, Bytes} = file:read_file(Path),
            example_region(Bytes, Region);
        _ -> missing
    end.

example_region(Bytes, []) -> Bytes;
example_region(Bytes, [Name]) when Name =/= <<>> ->
    Begin = <<"% docs:begin ", Name/binary>>,
    End = <<"% docs:end ", Name/binary>>,
    Lines = docs_util:splitlines(Bytes),
    Markers = [{Number, Text} || {Number, Line} <- lists:enumerate(Lines),
                                Text <- [string:trim(Line)],
                                Text =:= Begin orelse Text =:= End],
    case Markers of
        [{First, Begin}, {Last, End}] when Last > First + 1 ->
            dedent(lists:sublist(Lines, First + 1, Last - First - 1));
        _ -> missing
    end;
example_region(_, _) -> missing.

dedent(Lines) ->
    Indents = [Indent || Line <- Lines,
        {match, [Indent]} <- [re:run(Line, "^(\\h*)\\S", [{capture, [1], binary}])]],
    Width = binary:longest_common_prefix(Indents),
    iolist_to_binary(lists:join($\n, [dedent_line(Line, Width) || Line <- Lines])).

dedent_line(Line, Width) ->
    case string:trim(Line) of
        <<>> -> <<>>;
        _ ->
            <<_:Width/binary, Content/binary>> = Line,
            Content
    end.

ends_with(Binary, Suffix) ->
    Size = byte_size(Suffix),
    byte_size(Binary) >= Size andalso
        binary:part(Binary, byte_size(Binary) - Size, Size) =:= Suffix.

trim(Binary) -> string:trim(Binary, trailing).

json_block(Root, File, Before, Body, Outputs, State) ->
    case marker(Before, "example-input") of
        {ok, Source} ->
            Input = case file:read_file(filename:join(Root, Source)) of
                {ok, Bytes} -> Bytes;
                {error, Error} -> docs_util:fail(File, {input_unreadable, Source, Error})
            end,
            trim(Body) =:= trim(Input) orelse docs_util:fail(File, {input_drift, Source}),
            _ = decode(File, Body),
            State#{inputs := [Source | maps:get(inputs, State)]};
        error ->
            case marker(Before, "example-output") of
                {ok, Module} ->
                    Expected = decode(File, Body),
                    case Outputs of
                        none -> ok;
                        #{Module := Actual} ->
                            Actual == Expected orelse docs_util:fail(File, {output_drift, Module});
                        _ -> docs_util:fail(File, {output_not_recorded, Module})
                    end,
                    State#{displayed := [Module | maps:get(displayed, State)]};
                error -> docs_util:fail(File, unclassified_json_block)
            end
    end.

decode(File, Body) ->
    try json:decode(Body)
    catch error:Reason -> docs_util:fail(File, {invalid_json, Reason})
    end.
