-module(check_rendered_docs).
-moduledoc "Check rendered links, anchors and resources against the built tree and its sources.".
-export([check/2, scan/1]).

-type page() :: #{links := [binary()], resources := [binary()],
                  anchors := #{binary() => true}}.

-define(COMMIT_REPOSITORY, "/libtmux/libtmux-erlang/blob/").
-define(BATCH, 2000).

-doc """
Check every `.html` page below `Directory`: relative links, resources and
heading anchors must resolve, and `github.com` links into this repository must
name an object that exists in the Git checkout at `Root` (`HEAD` unless the
link names a commit). Returns the page, link and resource counts and raises
`{docs_check, Page, Reason}` for the first failure. Needs the application
started, because it runs `git`.
""".
-spec check(file:filename_all(), file:filename_all()) -> docs_util:json().
check(Directory, Root0) ->
    Root = docs_util:resolve(Root0),
    Found = filelib:fold_files(unicode:characters_to_list(Directory), ".*\\.html$", true,
                               fun(Path, Acc) -> [Path | Acc] end, []),
    Pages = maps:from_list([begin
        Resolved = docs_util:resolve(Path),
        {ok, Html} = file:read_file(Resolved),
        {Resolved, scan(Html)}
    end || Path <- Found]),
    Ordered = lists:sort(maps:to_list(Pages)),
    Targets = [{Path, Target} || {Path, #{links := Links, resources := Resources}} <- Ordered,
                                 Target <- Links ++ Resources],
    Classified = [{Path, Target, classify(Target)} || {Path, Target} <- Targets],
    Exist = existing_sources(Root, [Name || {_, _, {source, Name}} <- Classified]),
    Checked = lists:foldl(fun({Path, Target, Kind}, Count) ->
        check_target(filename:basename(Path), Path, Target, Kind, Pages, Exist, Count)
    end, 0, Classified),
    Resources = lists:sum([length(Resources) || #{resources := Resources} <- maps:values(Pages)]),
    {object, [{<<"pages">>, map_size(Pages)}, {<<"links">>, Checked},
              {<<"resources">>, Resources}]}.

classify(Target) ->
    #{scheme := Scheme, netloc := Netloc, path := Path, fragment := Fragment} =
        docs_util:urlsplit(Target),
    case {Netloc, Path} of
        {<<"github.com">>, <<?COMMIT_REPOSITORY, After/binary>>} ->
            {Revision, Source} = case binary:split(After, <<"/">>) of
                [R, S] -> {R, S};
                [R] -> {R, <<>>}
            end,
            Tree = case re:run(Revision, "^[0-9a-f]{7,40}$", [{capture, none}]) of
                match -> Revision;
                nomatch -> <<"HEAD">>
            end,
            {source, <<Tree/binary, ":", (docs_util:unquote(Source))/binary>>};
        _ when Scheme =:= <<>>, Netloc =:= <<>> -> {local, Path, Fragment};
        _ -> external
    end.

% One `git cat-file --batch-check` per chunk answers `<revision>:<path>` for all
% source links at once; `cat-file -e` would start a process per link.
existing_sources(Root, Names) ->
    maps:from_list(lists:append([batch_check(Root, Chunk)
                                 || Chunk <- chunks(lists:usort(Names), ?BATCH)])).

chunks([], _) -> [];
chunks(List, Size) when length(List) =< Size -> [List];
chunks(List, Size) ->
    {Chunk, Rest} = lists:split(Size, List),
    [Chunk | chunks(Rest, Size)].

batch_check(Root, Names) ->
    Input = [[Name, $\n] || Name <- Names],
    #{status := Status, stdout := Output} = script_util:run("git", ["cat-file", "--batch-check"],
        #{cwd => unicode:characters_to_binary(Root), stdin => iolist_to_binary(Input)}),
    Lines = binary:split(Output, <<"\n">>, [global, trim]),
    (Status =:= 0 andalso length(Lines) =:= length(Names))
        orelse docs_util:fail(<<"git cat-file">>, {batch_check_failed, Status}),
    [{Name, not lists:suffix(" missing", binary_to_list(Line))}
     || {Name, Line} <- lists:zip(Names, Lines)].

check_target(Name, _, Target, {source, Source}, _, Exist, Count) ->
    maps:get(Source, Exist) orelse docs_util:fail(Name, {missing_source_at_revision, Target}),
    Count + 1;
check_target(Name, Page, Target, {local, Path, Fragment}, Pages, _, Count) ->
    Resolved = case Path of
        <<>> -> Page;
        _ -> docs_util:resolve(filename:join(filename:dirname(Page), docs_util:unquote(Path)))
    end,
    element(1, file:read_file_info(Resolved)) =:= ok
        orelse docs_util:fail(Name, {missing_rendered_target, Target}),
    case {Fragment, Pages} of
        {<<>>, _} -> ok;
        {_, #{Resolved := #{anchors := Anchors}}} ->
            maps:is_key(docs_util:unquote(Fragment), Anchors)
                orelse docs_util:fail(Name, {missing_anchor, Target});
        _ -> ok
    end,
    Count + 1;
check_target(_, _, _, external, _, _, Count) -> Count.

-doc """
Collect what the link checker needs from an HTML page: `a` links, resources
(`img` and `script` sources, `link` references, `srcset` candidates) and every
`id`. Script, style, title and textarea contents and comments are skipped.
""".
-spec scan(binary()) -> page().
scan(Html) ->
    #{links := Links, resources := Resources} = Page =
        scan(Html, #{links => [], resources => [], anchors => #{}}),
    Page#{links := lists:reverse(Links), resources := lists:reverse(Resources)}.

scan(Html, Page) ->
    case binary:match(Html, <<"<">>) of
        nomatch -> Page;
        {Position, _} ->
            <<_:Position/binary, Markup/binary>> = Html,
            markup(Markup, Page)
    end.

markup(<<"<!--", Rest/binary>>, Page) -> after_first(Rest, <<"-->">>, Page);
markup(<<"<!", Rest/binary>>, Page) -> after_first(Rest, <<">">>, Page);
markup(<<"<?", Rest/binary>>, Page) -> after_first(Rest, <<">">>, Page);
markup(<<"</", Rest/binary>>, Page) -> after_first(Rest, <<">">>, Page);
markup(<<"<", Letter, _/binary>> = Tag, Page)
  when Letter >= $a, Letter =< $z; Letter >= $A, Letter =< $Z -> start_tag(Tag, Page);
markup(<<"<", Rest/binary>>, Page) -> scan(Rest, Page).

after_first(Html, Delimiter, Page) ->
    case binary:match(Html, Delimiter) of
        nomatch -> Page;
        {Position, Length} ->
            Skip = Position + Length,
            scan(binary:part(Html, Skip, byte_size(Html) - Skip), Page)
    end.

start_tag(<<"<", Html/binary>>, Page) ->
    {Name, Rest} = split_name(Html, 0),
    case attributes(Rest, []) of
        incomplete -> Page;
        {Attributes, SelfClosing, Remaining} ->
            Tag = string:lowercase(Name),
            Next = record_tag(Tag, Attributes, Page),
            case (not SelfClosing) andalso raw_text(Tag) of
                true -> raw_text(Remaining, Tag, Next);
                false -> scan(Remaining, Next)
            end
    end.

split_name(Html, Length) ->
    case Html of
        <<Name:Length/binary, C, _/binary>> when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r;
                                                 C =:= $\f; C =:= $/; C =:= $> ->
            {Name, binary:part(Html, Length, byte_size(Html) - Length)};
        <<_:Length/binary, _, _/binary>> -> split_name(Html, Length + 1);
        _ -> {Html, <<>>}
    end.

attributes(<<>>, _) -> incomplete;
attributes(<<">", Rest/binary>>, Acc) -> {Acc, false, Rest};
attributes(<<"/>", Rest/binary>>, Acc) -> {Acc, true, Rest};
attributes(<<C, Rest/binary>>, Acc) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r;
                                         C =:= $\f; C =:= $/ -> attributes(Rest, Acc);
attributes(<<First, Html/binary>>, Acc) ->
    {Tail, Rest} = split_attribute(Html, 0),
    Name = string:lowercase(<<First, Tail/binary>>),
    case skip_space(Rest) of
        <<"=", Value/binary>> ->
            case attribute_value(skip_space(skip_equals(Value))) of
                incomplete -> incomplete;
                {Text, After} -> attributes(After, [{Name, docs_util:unescape(Text)} | Acc])
            end;
        Other -> attributes(Other, [{Name, none} | Acc])
    end.

split_attribute(Html, Length) ->
    case Html of
        <<Name:Length/binary, C, _/binary>> when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r;
                                                 C =:= $\f; C =:= $/; C =:= $=; C =:= $> ->
            {Name, binary:part(Html, Length, byte_size(Html) - Length)};
        <<_:Length/binary, _, _/binary>> -> split_attribute(Html, Length + 1);
        _ -> {Html, <<>>}
    end.

skip_space(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r; C =:= $\f ->
    skip_space(Rest);
skip_space(Html) -> Html.

skip_equals(<<"=", Rest/binary>>) -> skip_equals(Rest);
skip_equals(Html) -> Html.

attribute_value(<<Quote, Html/binary>>) when Quote =:= $"; Quote =:= $' ->
    case binary:match(Html, <<Quote>>) of
        nomatch -> incomplete;
        {Length, _} -> {binary:part(Html, 0, Length),
                        binary:part(Html, Length + 1, byte_size(Html) - Length - 1)}
    end;
attribute_value(Html) ->
    case re:run(Html, "^[^>\\s]*", [{capture, first, index}]) of
        {match, [{0, Length}]} ->
            {binary:part(Html, 0, Length), binary:part(Html, Length, byte_size(Html) - Length)}
    end.

record_tag(Tag, Attributes, Page) ->
    Value = fun(Name) ->
        case lists:keyfind(Name, 1, Attributes) of
            {_, Text} when is_binary(Text), Text =/= <<>> -> Text;
            _ -> undefined
        end
    end,
    Anchored = case Value(<<"id">>) of
        undefined -> Page;
        Id -> Page#{anchors := (maps:get(anchors, Page))#{Id => true}}
    end,
    Linked = case {Tag, Value(<<"href">>)} of
        {<<"a">>, Href} when Href =/= undefined ->
            Anchored#{links := [Href | maps:get(links, Anchored)]};
        {<<"link">>, Href} when Href =/= undefined -> resource(Href, Anchored);
        _ -> Anchored
    end,
    Sourced = case {Tag, Value(<<"src">>)} of
        {T, Src} when (T =:= <<"img">> orelse T =:= <<"script">>), Src =/= undefined ->
            resource(Src, Linked);
        _ -> Linked
    end,
    case {Tag, Value(<<"srcset">>)} of
        {T2, Set} when (T2 =:= <<"img">> orelse T2 =:= <<"source">>), Set =/= undefined ->
            case Set of
                <<"data:", _/binary>> -> Sourced;
                _ -> lists:foldl(fun resource/2, Sourced, candidates(Set))
            end;
        _ -> Sourced
    end.

resource(Url, Page) -> Page#{resources := [Url | maps:get(resources, Page)]}.

candidates(Set) ->
    [hd(string:lexemes(Part, " \t\n\r\f")) || Part <- binary:split(Set, <<",">>, [global]),
                                              string:trim(Part) =/= <<>>].

raw_text(<<"script">>) -> true;
raw_text(<<"style">>) -> true;
raw_text(<<"title">>) -> true;
raw_text(<<"textarea">>) -> true;
raw_text(_) -> false.

raw_text(Html, Tag, Page) ->
    case re:run(Html, ["</", Tag], [caseless, {capture, first, index}]) of
        nomatch -> Page;
        {match, [{Position, _}]} ->
            scan(binary:part(Html, Position, byte_size(Html) - Position), Page)
    end.
