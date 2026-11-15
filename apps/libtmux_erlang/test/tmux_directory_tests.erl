-module(tmux_directory_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/eep48.hrl").

%% libtmux.org folds a "What is on here" directory into a table of rows only
%% when at least three bold-led paragraphs run in a row, each followed by a
%% paragraph or a labelled list that holds nothing but references. A directory
%% below that floor, or a row with prose among its references, renders as plain
%% text and raises no error. This check applies the same rule to the module
%% docs of the owner modules and requires the directory to name each public
%% function and type of its module and to link only documented targets.

-define(MIN_ROWS, 3).
-define(OWNERS, [tmux_server, tmux_session, tmux_window, tmux_pane]).
-define(REFERENCE,
        "`(?:m:[a-z_]\\w*|(?:[tc]:)?(?:[a-z_]\\w*:)?[a-z_]\\w*/\\d+)`").

owner_directories_test_() ->
    [{atom_to_list(Owner) ++ " directory",
      fun() -> ?assertEqual([], problems(Owner)) end}
     || Owner <- ?OWNERS].

complete_directory_test() ->
    ?assertEqual([], check(sample, fixture(), members(), fun resolves/3)).

too_few_rows_test() ->
    Text = doc([intro(), section(<<"Making">>, <<"`make/1`, `t:opts/0`">>),
                section(<<"Reading">>, <<"`read/1` and `remove/1`">>)]),
    ?assertEqual([{rows, 2}], check(sample, Text, members(), fun resolves/3)).

no_directory_test() ->
    ?assertEqual([{rows, 0}, {unnamed, <<"make/1">>}, {unnamed, <<"read/1">>},
                  {unnamed, <<"t:opts/0">>}, {unnamed, <<"remove/1">>}],
                 check(sample, <<"Only prose.">>, members(), fun resolves/3)).

unnamed_member_test() ->
    Text = doc([intro(), section(<<"Making">>, <<"`make/1`, `t:opts/0`">>),
                section(<<"Reading">>, <<"`other:read/0`">>),
                section(<<"Removing">>, <<"- Remove: `remove/1`">>)]),
    ?assertEqual([{unnamed, <<"read/1">>}],
                 check(sample, Text, members(), fun resolves/3)).

prose_among_references_ends_the_run_test() ->
    Text = doc([intro(), section(<<"Making">>, <<"`make/1`, `t:opts/0`">>),
                section(<<"Reading">>, <<"`read/1`">>),
                section(<<"Removing">>, <<"Call `remove/1` to remove it.">>)]),
    ?assertEqual([{rows, 2}, {unnamed, <<"remove/1">>}],
                 check(sample, Text, members(), fun resolves/3)).

unresolved_reference_test() ->
    Text = doc([fixture(), section(<<"Elsewhere">>, <<"`other:gone/0`, `m:nowhere`">>)]),
    ?assertEqual([{unresolved, <<"other:gone/0">>}, {unresolved, <<"m:nowhere">>}],
                 check(sample, Text, members(), fun resolves/3)).

fixture() ->
    doc([intro(), section(<<"Making">>, <<"`make/1`, `t:opts/0`">>),
         section(<<"Reading">>, <<"`read/1` and `other:read/0`">>),
         section(<<"Removing">>, <<"- Remove: `remove/1` and `m:other`">>)]).

members() ->
    [{function, make, 1}, {function, read, 1}, {type, opts, 0},
     {function, remove, 1}].

resolves(other, module, none) -> true;
resolves(other, function, {read, 0}) -> true;
resolves(_, _, _) -> false.

intro() -> <<"Purpose.\n\n## What is on here\n\nIntroduction.">>.

section(Title, Names) ->
    <<"**", Title/binary, ".** Guidance for ", Title/binary, ".\n\n",
      Names/binary>>.

doc(Blocks) -> iolist_to_binary(lists:join("\n\n", Blocks)).

problems(Owner) ->
    {ok, #docs_v1{module_doc = #{<<"en">> := Text}, docs = Docs}} =
        code:get_doc(Owner),
    Members = [{Kind, Name, Arity}
               || {{Kind, Name, Arity}, _, _, Doc, Meta} <- Docs,
                  public(Kind, Doc, Meta)],
    check(Owner, Text, Members, fun documented/3).

public(function, Doc, _) -> is_map(Doc);
public(type, Doc, Meta) -> is_map(Doc) andalso maps:get(exported, Meta, false);
public(callback, _, _) -> false.

%% A reference to another module resolves when that module documents the target.
documented(Module, module, none) ->
    case code:get_doc(Module) of
        {ok, #docs_v1{module_doc = Doc}} -> Doc =/= hidden;
        {error, _} -> false
    end;
documented(Module, Kind, {Name, Arity}) ->
    case code:get_doc(Module) of
        {ok, #docs_v1{docs = Docs}} ->
            lists:any(fun({{K, N, A}, _, _, Doc, _}) ->
                {K, N, A} =:= {Kind, Name, Arity} andalso Doc =/= hidden
            end, Docs);
        {error, _} -> false
    end.

%% The problems of an owner's module doc, as Resolves(Module, Kind, Target)
%% sees the references to other modules.
check(Owner, Text, Members, Resolves) ->
    Rows = largest(runs(blocks(Text), [], [])),
    Refs = [{Ref, classify(Owner, Ref)} || {_Title, Names} <- Rows, Ref <- Names],
    Own = [{Kind, Name, Arity} || {_, {own, Kind, Name, Arity}} <- Refs],
    [{rows, length(Rows)} || length(Rows) < ?MIN_ROWS] ++
    [{unnamed, label(Member)} || Member <- Members, not lists:member(Member, Own)] ++
    [{unresolved, Ref} || {Ref, {foreign, Module, Kind, Target}} <- Refs,
                          not Resolves(Module, Kind, Target)].

label({function, Name, Arity}) ->
    iolist_to_binary([atom_to_list(Name), $/, integer_to_list(Arity)]);
label({type, Name, Arity}) ->
    iolist_to_binary(["t:", atom_to_list(Name), $/, integer_to_list(Arity)]).

%% `name/1` and `t:name/0` name the owner's own members, as does a reference
%% qualified with the owner. `other:name/1`, `t:other:name/0` and
%% `c:other:name/0` name another module's, and `m:module` links a whole module.
classify(_, <<"m:", Module/binary>>) ->
    {foreign, binary_to_atom(Module), module, none};
classify(Owner, Ref) ->
    {match, [Prefix, Module, Name, Arity]} = re:run(Ref,
        "^(?:([tc]):)?(?:([a-z_]\\w*):)?([a-z_]\\w*)/(\\d+)$",
        [{capture, all_but_first, binary}]),
    Kind = case Prefix of <<"t">> -> type; <<"c">> -> callback; <<>> -> function end,
    Function = binary_to_atom(Name),
    Count = binary_to_integer(Arity),
    case binary_to_atom(Module) of
        Owner -> {own, Kind, Function, Count};
        '' -> {own, Kind, Function, Count};
        Other -> {foreign, Other, Kind, {Function, Count}}
    end.

blocks(Text) ->
    [Block || Raw <- re:split(Text, "\n[ \t]*\n", [{return, binary}]),
              Block <- [string:trim(Raw)], Block =/= <<>>].

%% Consecutive rows form a run, and any other block ends it, as on the site.
runs([Lead, Next | Rest], Run, Runs) ->
    case row(Lead, Next) of
        {ok, Row} -> runs(Rest, [Row | Run], Runs);
        error -> runs([Next | Rest], [], [lists:reverse(Run) | Runs])
    end;
runs(_, Run, Runs) -> [lists:reverse(Run) | Runs].

largest(Runs) ->
    hd(lists:sort(fun(A, B) -> length(A) >= length(B) end, Runs)).

row(Lead, Next) ->
    case re:run(Lead, "^\\*\\*([^*]+?)\\*\\*", [{capture, all_but_first, binary}]) of
        {match, [Title]} ->
            case references(Next) of
                {ok, Names} -> {ok, {Title, Names}};
                error -> error
            end;
        nomatch -> error
    end.

%% A paragraph of references, or a list of `Label: references` items.
references(<<"- ", _/binary>> = List) ->
    Items = [item(Item) || Item <- re:split(List, "\n(?=- )", [{return, binary}])],
    case lists:member(error, Items) of
        true -> error;
        false -> {ok, lists:append([Names || {ok, Names} <- Items])}
    end;
references(Paragraph) -> only_references(Paragraph).

item(<<"- ", Text/binary>>) ->
    Joined = re:replace(Text, "\\s*\n\\s*", " ", [global, {return, binary}]),
    case re:run(Joined, "^[^:\\[`]{1,40}:\\s+(.*)$", [{capture, all_but_first, binary}]) of
        {match, [Names]} -> only_references(Names);
        nomatch -> error
    end.

only_references(Text) ->
    case re:run(Text, ?REFERENCE, [global, {capture, all, binary}]) of
        nomatch -> error;
        {match, Found} ->
            Left = re:replace(Text, ?REFERENCE, "", [global, {return, binary}]),
            case re:replace(Left, "\\band\\b|[\\s,;.\xB7]", "",
                            [global, {return, binary}, unicode]) of
                <<>> -> {ok, [binary:part(Ref, 1, byte_size(Ref) - 2) || [Ref] <- Found]};
                _ -> error
            end
    end.
