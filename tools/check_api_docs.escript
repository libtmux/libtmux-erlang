#!/usr/bin/env escript
-mode(compile).
-include_lib("kernel/include/eep48.hrl").

main(Arguments) ->
    Profile = case Arguments of [] -> "default"; ["--test"] -> "test" end,
    ok = code:add_pathsa(filelib:wildcard("_build/" ++ Profile ++ "/lib/*/ebin")),
    Modules = lists:append([begin
        ok = application:load(App),
        {ok, Members} = application:get_key(App, modules),
        Members
    end || App <- [libtmux_erlang]]),
    Results = [module(M) || M <- Modules],
    Public = [R || R <- Results, R =/= hidden],
    Missing = lists:append([maps:get(missing,R) || R <- Public]),
    io:format("~s~n", [json:encode(#{modules => Public, missing => Missing})]),
    case Missing of [] -> ok; _ -> halt(1) end.

module(Module) ->
    {ok, #docs_v1{module_doc = ModuleDoc, docs = Docs}} = code:get_doc(Module),
    case ModuleDoc of
        hidden -> hidden;
        _ ->
            {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
                beam_lib:chunks(code:which(Module), [abstract_code]),
            Specs = [FA || {attribute,_,spec,{FA,_}} <- Forms],
            Exports = Module:module_info(exports),
            Types = lists:append([T || {attribute,_,export_type,T} <- Forms]),
            Entries = [entry(Module,D,Exports,Types,Specs) || D <- Docs],
            Missing = [M || {missing,M} <- Entries],
            #{module => Module, documented => length([ok || ok <- Entries]),
              missing => case is_map(ModuleDoc) of
                  true -> Missing;
                  false -> [#{module => Module, reason => missing_module_doc} | Missing]
              end}
    end.

entry(Module, {{Kind,Name,Arity},_,_,Doc,_}, Exports, Types, Specs) ->
    Public = case Kind of
        function -> lists:member({Name,Arity},Exports);
        type -> lists:member({Name,Arity},Types);
        callback -> true
    end,
    HasSpec = Kind =/= function orelse lists:member({Name,Arity},Specs),
    case {Public,Doc,HasSpec} of
        {false,_,_} -> hidden;
        {_,hidden,_} -> hidden;
        {true,Map,true} when is_map(Map), map_size(Map) > 0 -> ok;
        _ -> {missing,#{module => Module, kind => Kind, name => Name,
                        arity => Arity, spec => HasSpec, reason => missing_api_contract}}
    end.
