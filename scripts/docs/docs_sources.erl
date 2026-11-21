-module(docs_sources).
-moduledoc "Stage guides and bundle the source and media their links reference.".
-export([context/2, new_state/0, stage_page/3, source_link/4, source_page/3,
         copy_media/3, rewrite_source_links/2]).

-type context() :: #{root := binary(), output := binary(), head := binary(),
                     committed := #{binary() => binary()}, hash := sha | sha256,
                     extras := [binary()]}.
-type state() :: #{sources := #{binary() => #{binary() => docs_util:json()}},
                   media := #{binary() => #{binary() => binary()}}}.

-define(REPOSITORY, "https://github.com/libtmux/libtmux-erlang/blob/").

-doc "Build context for `Root`: output directory, HEAD, committed blob ids and staged pages.".
-spec context(file:filename_all(), [binary()]) -> context().
context(Root0, Extras) ->
    Root = docs_util:resolve(Root0),
    Head = script_util:git(["rev-parse", "HEAD"], Root),
    Tree = script_util:run_ok("git", ["ls-tree", "-r", "-z", "HEAD"], #{cwd => Root}),
    Committed = maps:from_list([{Path, Oid} || Entry <- binary:split(Tree, <<0>>, [global]),
        [<<_Mode:6/binary, " blob ", Oid/binary>>, Path] <- [binary:split(Entry, <<"\t">>)]]),
    #{root => Root, output => filename:join(Root, "_build/docs/core"), head => Head,
      committed => Committed,
      hash => case byte_size(Head) of 40 -> sha; 64 -> sha256 end,
      extras => [docs_util:resolve(filename:join(Root, Extra)) || Extra <- Extras]}.

-doc "State of a build: generated source pages and copied media.".
-spec new_state() -> state().
new_state() -> #{sources => #{}, media => #{}}.

-doc """
Stage the guide `Page` (a path below the root): rewrite relative links to
generated source pages and image sources to `media/` paths. Returns the staged
text and the updated state; raises `{build_docs, Message}` for a broken link or
missing image.
""".
-spec stage_page(context(), binary(), state()) -> {binary(), state()}.
stage_page(#{root := Root} = Context, Page, State) ->
    {ok, Text} = file:read_file(filename:join(Root, Page)),
    {Linked, Linking} = docs_util:replace("(?<!!)\\[([^\\]]+)\\]\\(([^)]+)\\)", Text,
        fun([Whole, Label, Target], Acc) ->
            rewrite_link(Context, Page, Whole, Label, Target, Acc)
        end, State),
    docs_util:replace("<(?:img|source)\\b[^>]*>", Linked,
        fun([Tag], Acc) -> rewrite_tag(Context, Page, Tag, Acc) end, Linking).

rewrite_link(#{root := Root, extras := Extras} = Context, Page, Whole, Label, Target, State) ->
    case Target of
        <<"http:", _/binary>> -> {Whole, State};
        <<"https:", _/binary>> -> {Whole, State};
        <<"mailto:", _/binary>> -> {Whole, State};
        <<"#", _/binary>> -> {Whole, State};
        _ ->
            {Filename, Fragment} = case binary:split(Target, <<"#">>) of
                [Name, After] -> {Name, After};
                [Name] -> {Name, <<>>}
            end,
            Resolved = docs_util:resolve(filename:join([Root, filename:dirname(Page), Filename])),
            (docs_util:is_within(Root, Resolved) andalso exists(Resolved))
                orelse fail(<<"Broken documentation link: ", Page/binary, " -> ", Target/binary>>),
            case lists:member(Resolved, Extras) of
                true -> {Whole, State};
                false ->
                    {Url, Next} = source_page(Context, Resolved, State),
                    Linked = case Fragment of
                        <<"L", _/binary>> -> <<Url/binary, "#", Fragment/binary>>;
                        _ -> Url
                    end,
                    {[<<"[">>, Label, <<"](">>, Linked, <<")">>], Next}
            end
    end.

exists(Path) -> element(1, file:read_file_info(Path)) =:= ok.

-doc """
The generated source page and line anchor that replace an ExDoc source link:
`Encoded` is a percent-encoded path below `apps/*/src` or of a staged guide.
""".
-spec source_link(context(), binary(), binary(), state()) -> {iodata(), state()}.
source_link(#{root := Root} = Context, Encoded, Line, State) ->
    Path = docs_util:unquote(Encoded),
    Original = case Path of
        <<"_build/docs/pages/", Page/binary>> -> Page;
        _ ->
            case [Candidate || Source <- docs_util:wildcard(Root, "apps/*/src"),
                               Candidate <- [filename:join(Source, Path)],
                               exists(filename:join(Root, Candidate))] of
                [Only] -> Only;
                _ -> fail(<<"Ambiguous documentation source: ", Path/binary>>)
            end
    end,
    {Url, Next} = source_page(Context, filename:join(Root, Original), State),
    {[Url, <<"#L">>, Line], Next}.

rewrite_tag(Context, Page, Tag, State) ->
    docs_util:replace("\\b(src|srcset)\\s*=\\s*(['\"])(.*?)\\2", Tag,
        fun([_, Name, Quote, Value], Acc) ->
            {Rendered, Next} = rewrite_attribute(Context, Page, Name, Value, Acc),
            {[Name, <<"=">>, Quote, docs_util:escape(Rendered), Quote], Next}
        end, State).

rewrite_attribute(Context, Page, <<"srcset">>, Value, State) ->
    case string:trim(Value, leading) of
        <<"data:", _/binary>> -> image_url(Context, Page, Value, State);
        _ ->
            Candidates = [string:lexemes(Part, " \t\n\r\f\v")
                          || Part <- binary:split(Value, <<",">>, [global])],
            {Rendered, Next} = lists:mapfoldl(fun([Url | Descriptors], Acc) ->
                {Rewritten, Updated} = image_url(Context, Page, Url, Acc),
                {lists:join(<<" ">>, [Rewritten | Descriptors]), Updated}
            end, State, [Parts || Parts <- Candidates, Parts =/= []]),
            {iolist_to_binary(lists:join(<<", ">>, Rendered)), Next}
    end;
rewrite_attribute(Context, Page, _, Value, State) -> image_url(Context, Page, Value, State).

image_url(#{root := Root}, Page, Target, #{media := Media} = State) ->
    Unescaped = docs_util:unescape(Target),
    case docs_util:urlsplit(Unescaped) of
        #{scheme := Scheme, netloc := Netloc, path := Path}
          when Scheme =/= <<>>; Netloc =/= <<>>; Path =:= <<>> ->
            {Unescaped, State};
        #{path := Path, query := Query, fragment := Fragment} ->
            Image = docs_util:resolve(filename:join([Root, filename:dirname(Page),
                                                     docs_util:unquote(Path)])),
            (docs_util:is_within(Root, Image) andalso filelib:is_regular(Image)) orelse
                fail(<<"Missing documentation image: ", Page/binary, " -> ", Target/binary>>),
            Relative = docs_util:relative_to(Image, Root),
            Destination = <<"media/", Relative/binary>>,
            Info = #{<<"source">> => Relative, <<"sha256">> => docs_util:sha256_file(Image)},
            {<<(docs_util:quote(Destination, <<"/">>))/binary,
               (suffix("?", Query))/binary, (suffix("#", Fragment))/binary>>,
             State#{media := Media#{Destination => Info}}}
    end.

suffix(_, <<>>) -> <<>>;
suffix(Mark, Text) -> <<(list_to_binary(Mark))/binary, Text/binary>>.

-doc """
Write the generated page for a file or directory of the checkout and return
its path below the output directory. A file page shows numbered lines and
links to the commit when it matches `HEAD`; otherwise it is labelled a
working-tree preview.
""".
-spec source_page(context(), file:filename_all(), state()) -> {binary(), state()}.
source_page(#{root := Root, output := Output} = Context, Path0, State) ->
    Path = docs_util:resolve(Path0),
    (docs_util:is_within(Root, Path) andalso exists(Path))
        orelse fail(<<"Source outside checkout or missing: ", Path/binary>>),
    Relative = docs_util:relative_to(Path, Root),
    IsDirectory = filelib:is_dir(Path),
    Target = case {Relative, IsDirectory} of
        {<<".">>, true} -> <<"source/index.html">>;
        {_, true} -> <<"source/", Relative/binary, "/index.html">>;
        {_, false} -> <<"source/", Relative/binary, ".html">>
    end,
    case State of
        #{sources := #{Relative := _}} -> {Target, State};
        #{sources := Sources} ->
            Destination = filename:join(Output, Target),
            Started = State#{sources := Sources#{Relative => #{}}},
            case IsDirectory of
                true -> directory_page(Context, Path, Destination, Relative, Target, Started);
                false -> file_page(Context, Path, Destination, Relative, Target, Started)
            end
    end.

directory_page(#{output := Output} = Context, Path, Destination, Relative, Target, State) ->
    {ok, Names} = file:list_dir_all(Path),
    Children = lists:sort([unicode:characters_to_binary(Name) || Name <- Names]),
    {Entries, Done} = lists:mapfoldl(fun(Child, Acc) ->
        {ChildTarget, Next} = source_page(Context, filename:join(Path, Child), Acc),
        Href = docs_util:relative_path(filename:join(Output, ChildTarget),
                                       filename:dirname(Destination)),
        {[<<"<li><a href=\"">>, docs_util:escape(Href), <<"\">">>, docs_util:escape(Child),
          <<"</a></li>">>], Next}
    end, State, Children),
    docs_util:write_file(Destination, [prefix(Relative), <<"<ul>">>, Entries, <<"</ul>">>]),
    {Target, Done}.

file_page(#{head := Head, committed := Committed, hash := Hash}, Path, Destination, Relative,
          Target, #{sources := Sources} = State) ->
    {ok, Data} = file:read_file(Path),
    Text = case unicode:characters_to_binary(Data) of
        Valid when is_binary(Valid) -> Valid;
        _ -> fail(<<"Source is not UTF-8: ", Relative/binary>>)
    end,
    Digest = script_util:sha256_hex(Data),
    Same = maps:get(Relative, Committed, none) =:= blob_id(Hash, Data),
    Provenance = case Same of
        true -> [<<"<p><a href=\"">>, ?REPOSITORY, Head, $/, Relative, <<"\">Source at ">>,
                 Head, <<"</a></p>">>];
        false -> <<"<p>Working tree preview. This content is not the source at HEAD.</p>">>
    end,
    Lines = lists:join($\n, [[<<"<span id=\"L">>, integer_to_binary(Number), <<"\">">>,
                              docs_util:escape(Line), <<"</span>">>]
                             || {Number, Line} <- lists:enumerate(docs_util:splitlines(Text))]),
    docs_util:write_file(Destination, [prefix(Relative), Provenance, <<"<p>SHA-256: ">>, Digest,
                                       <<"</p><pre>">>, Lines, <<"</pre>">>]),
    Info = #{<<"sha256">> => Digest, <<"matches_head">> => Same},
    {Target, State#{sources := Sources#{Relative => Info}}}.

blob_id(Algorithm, Data) ->
    Header = [<<"blob ">>, integer_to_binary(byte_size(Data)), 0],
    binary:encode_hex(crypto:hash(Algorithm, [Header, Data]), lowercase).

prefix(Relative) ->
    Title = docs_util:escape(Relative),
    [<<"<!doctype html><meta charset=\"utf-8\">"
       "<meta name=\"viewport\" content=\"width=device-width\">"
       "<link rel=\"icon\" href=\"data:,\"><title>">>, Title, <<"</title>"
       "<style>body{font:16px system-ui;max-width:100ch;margin:2rem auto;padding:0 1rem;"
       "overflow-wrap:anywhere}h1{font-size:1.3rem}"
       "pre{font-size:14px;line-height:1.5;white-space:pre-wrap;overflow-wrap:anywhere;"
       "counter-reset:line}"
       "pre span::before{counter-increment:line;content:counter(line);display:inline-block;"
       "width:4em;color:#666}:target{background:#fff4c2}</style><h1>">>, Title, <<"</h1>">>].

-doc "Copy bundled media and create the browser configuration file.".
-spec copy_media(binary(), binary(), #{binary() => map()}) -> ok.
copy_media(Root, Output, Media) ->
    maps:foreach(fun(Destination, #{<<"source">> := Source}) ->
        Target = filename:join(Output, Destination),
        ok = filelib:ensure_dir(Target),
        {ok, _} = file:copy(filename:join(Root, Source), Target)
    end, Media),
    % ExDoc requests this optional configuration even when no overrides exist.
    docs_util:write_file(filename:join(Output, "docs_config.js"),
                         <<"// No runtime documentation overrides.\n">>).

-doc "Replace compiler source placeholders with links to bundled source pages.".
-spec rewrite_source_links(context(), state()) -> state().
rewrite_source_links(#{output := Output} = Context, State) ->
    lists:foldl(fun(Name, Acc) ->
        File = filename:join(Output, Name),
        {ok, Html} = file:read_file(File),
        {Rendered, Next} = docs_util:replace("https://source\\.invalid/([^\"#]+)#L([0-9]+)", Html,
            fun([_, Path, Line], Links) -> source_link(Context, Path, Line, Links) end, Acc),
        Icon = <<"<link rel=\"icon\" href=\"data:,\">\n</head>">>,
        ok = file:write_file(File, binary:replace(Rendered, <<"</head>">>, Icon, [global])),
        Next
    end, State, docs_util:wildcard(Output, "*.html")).

-spec fail(binary()) -> no_return().
fail(Message) -> error({build_docs, Message}).
