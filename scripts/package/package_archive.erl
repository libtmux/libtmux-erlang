-module(package_archive).
-moduledoc "Build and unpack deterministic compiled OTP archives for qualification.".
-include_lib("kernel/include/file.hrl").
-export([assemble/3, members/2, extract/2]).

-doc """
Assemble `App` from its compiled build output as a gzip-compressed tar archive in
`ArtifactDir` and return its path and the top-level directory name. The bytes
depend only on the input files and their executable bits.
""".
-spec assemble(file:filename(), string(), file:filename()) ->
    {file:filename(), string()}.
assemble(Root, App, ArtifactDir) ->
    Members = members(Root, App),
    Prefix = App ++ "-0.0.0+development",
    Archive = filename:join(ArtifactDir, App ++ "-otp.tar.gz"),
    Tar = script_util:with_tmp_dir("package-archive", fun(Directory) ->
        Path = filename:join(Directory, "archive.tar"),
        {ok, Descriptor} = erl_tar:open(Path, [write]),
        Fixed = [{atime, 0}, {mtime, 0}, {ctime, 0}, {uid, 0}, {gid, 0}],
        lists:foreach(fun({Name, Source, Mode}) ->
            ok = erl_tar:add(Descriptor, {Prefix ++ "/" ++ Name, read(Source)},
                             [{mode, Mode} | Fixed])
        end, Members),
        ok = erl_tar:close(Descriptor),
        read(Path)
    end),
    ok = file:write_file(Archive, zlib:gzip(Tar)),
    {Archive, Prefix}.

-doc """
List the archive members as `{NameInArchive, SourcePath, Mode}`: the compiled
`ebin` files, `LICENSE`, `CHANGELOG.md` and everything under `priv`. Fails when
the application is not compiled.
""".
-spec members(file:filename(), string()) ->
    [{string(), file:filename(), 8#644 | 8#755}].
members(Root, App) ->
    Application = filename:join([Root, "_build", "default", "lib", App]),
    Ebin = filename:join(Application, "ebin"),
    Beams = [Name || Name <- list_sorted(Ebin), filelib:is_regular(filename:join(Ebin, Name))],
    case Beams =/= [] andalso filelib:is_regular(filename:join(Ebin, App ++ ".app")) of
        true -> ok;
        false -> fail("Run mise exec -- rebar3 compile first", [])
    end,
    Compiled = [{"ebin/" ++ Name, filename:join(Ebin, Name)} || Name <- Beams],
    Texts = [{Name, filename:join([Root, "apps", App, Name])}
             || Name <- ["LICENSE", "CHANGELOG.md"]],
    Priv = [{filename:join(["priv" | Relative]), Path}
            || {Relative, Path} <- walk(filename:join(Application, "priv"), [])],
    [{Name, Path, mode(Path)} || {Name, Path} <- Compiled ++ Texts ++ Priv].

-spec extract(file:filename(), file:filename()) -> ok.
extract(Archive, Directory) ->
    case erl_tar:extract(Archive, [compressed, {cwd, Directory}]) of
        ok -> ok;
        {error, Reason} -> fail("cannot unpack ~ts: ~p", [Archive, Reason])
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> Data;
        {error, Reason} -> fail("cannot read ~ts: ~p", [Path, Reason])
    end.

list_sorted(Directory) ->
    case file:list_dir(Directory) of
        {ok, Names} -> lists:sort(Names);
        {error, _} -> []
    end.

walk(Directory, Relative) ->
    lists:flatmap(fun(Name) ->
        Path = filename:join(Directory, Name),
        case file:read_link_info(Path) of
            {ok, #file_info{type = directory}} -> walk(Path, Relative ++ [Name]);
            _ -> [{Relative ++ [Name], Path} || filelib:is_regular(Path)]
        end
    end, list_sorted(Directory)).

mode(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{mode = Mode}} when Mode band 8#100 =/= 0 -> 8#755;
        _ -> 8#644
    end.

fail(Format, Arguments) ->
    error({check_failed, unicode:characters_to_binary(io_lib:format(Format, Arguments))}).
