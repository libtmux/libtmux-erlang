#!/usr/bin/env escript
-mode(compile).
-include_lib("public_key/include/public_key.hrl").

%% Test-only signed registry. Tarballs stay byte-identical to Hex build output.
main(["installed", Directory]) ->
    {ok, [{LockVersion, Entries} | _]} =
        file:consult(filename:join(Directory, "rebar.lock")),
    Locked = [#{app => App, package => element(2, Resource),
        version => element(3, Resource), depth => Depth}
        || {App, Resource, Depth} <- Entries],
    Apps = [libtmux_erlang],
    Expected = lists:sort([atom_to_binary(A) || A <- Apps]),
    Expected = lists:sort([maps:get(app, E) || E <- Locked]),
    Loaded = [installed(Directory, App) || App <- Apps],
    io:format("~s~n", [json:encode(#{lock_version => list_to_binary(LockVersion),
        locked => Locked, applications => Loaded})]);
main([HexCore, Directory]) ->
    true = code:add_patha(HexCore),
    {ok, _} = application:ensure_all_started(public_key),
    KeyFile = filename:join(Directory, "fixture-key.pem"),
    Key = case file:read_file(KeyFile) of
        {ok, Existing} ->
            [Entry] = public_key:pem_decode(Existing),
            public_key:pem_entry_decode(Entry);
        {error, enoent} ->
            Created = public_key:generate_key({rsa, 2048, 65537}),
            Encoded = public_key:pem_encode([
                public_key:pem_entry_encode('RSAPrivateKey', Created)]),
            ok = file:write_file(KeyFile, Encoded),
            ok = file:change_mode(KeyFile, 8#600),
            Created
    end,
    Public = #'RSAPublicKey'{modulus = Key#'RSAPrivateKey'.modulus,
        publicExponent = Key#'RSAPrivateKey'.publicExponent},
    Pem = public_key:pem_encode([
        public_key:pem_entry_encode('RSAPublicKey', Public)]),
    PublicRoot = filename:join(Directory, "public"),
    ok = filelib:ensure_dir(filename:join([PublicRoot, "packages", "placeholder"])),
    ok = file:write_file(filename:join(PublicRoot, "public_key"), Pem),
    Paths = filelib:wildcard(filename:join([PublicRoot, "tarballs", "*.tar"])),
    Packages = [package(Path, PublicRoot, Key) || Path <- Paths],
    Names = [#{name => maps:get(<<"name">>, M)} || M <- Packages],
    Versions = [#{name => maps:get(<<"name">>, M),
        versions => [maps:get(<<"version">>, M)]} || M <- Packages],
    ok = file:write_file(filename:join(PublicRoot, "names"),
        hex_registry:build_names(#{repository => <<"hexpm">>, packages => Names}, Key)),
    ok = file:write_file(filename:join(PublicRoot, "versions"),
        hex_registry:build_versions(#{repository => <<"hexpm">>, packages => Versions}, Key)),
    io:format("~s~n", [json:encode(Packages)]).

installed(Directory, App) ->
    Ebin = filename:join([Directory, "_build", "default", "lib", App, "ebin"]),
    true = code:add_patha(Ebin),
    ok = application:load(App),
    {ok, Modules} = application:get_key(App, modules),
    true = Modules =/= [],
    lists:foreach(fun(Module) ->
        {module, Module} = code:ensure_loaded(Module),
        Ebin = filename:dirname(code:which(Module))
    end, Modules),
    {ok, Dependencies} = application:get_key(App, applications),
    Expected = [kernel, stdlib, crypto],
    Expected = Dependencies,
    #{name => App, modules => length(Modules), dependencies => Dependencies}.

package(Path, PublicRoot, Key) ->
    {ok, #{metadata := Metadata, inner_checksum := Inner,
           outer_checksum := Outer}} = hex_tarball:unpack({file, Path}, memory),
    Name = maps:get(<<"name">>, Metadata),
    Dependencies = [#{package => N, app => maps:get(<<"app">>, D, N),
        requirement => maps:get(<<"requirement">>, D),
        optional => maps:get(<<"optional">>, D, false)}
        || N := D <- maps:get(<<"requirements">>, Metadata, #{})],
    Release = #{version => maps:get(<<"version">>, Metadata),
        inner_checksum => Inner, outer_checksum => Outer,
        dependencies => Dependencies},
    Binary = hex_registry:build_package(#{repository => <<"hexpm">>,
        name => Name, releases => [Release]}, Key),
    ok = file:write_file(filename:join([PublicRoot, "packages", Name]), Binary),
    maps:with([<<"name">>, <<"version">>, <<"requirements">>,
        <<"files">>, <<"licenses">>, <<"links">>, <<"build_tools">>], Metadata).
