% Verify Hex workload identity from release.yml without uploading anything.
-module(check_hex_identity).
-moduledoc """
Check the GitHub Actions identity with the pinned publisher's Hex client.

Run `rebar3 as release version` first to load its dependencies, then run:

```console
$ escript scripts/release/check_hex_identity.erl
```

Requires the `hexpm` GitHub environment and `id-token: write`. Rejects a
configured `HEX_API_KEY` environment variable, exchanges the GitHub identity
for a token scoped to `libtmux_erlang`. A read-only API request must deny its
read permission (HTTP 403); after revocation it must reject the credential
(HTTP 401). Uploads no package or documentation. Tokens are neither printed
nor written to disk.
HTTP requests have a 15-second deadline. Exit status 0 confirms exchange and
revocation; status 1 indicates failure, including running outside Actions.
""".
-mode(compile).
-export([main/1, verify_revocation/4]).

-spec main([string()]) -> no_return().
main([]) ->
    case os:getenv("HEX_API_KEY") of
        false -> ok;
        "" -> ok;
        _ -> fail("Unset HEX_API_KEY before checking Workload Identity.")
    end,
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    Paths = filelib:wildcard(filename:join(
        Root, "_build/release/plugins/*/ebin")),
    ok = code:add_pathsa(Paths),
    {ok, _} = application:ensure_all_started(hex_core),
    Core = client(hex_core),
    Auth = client(hex_cli_auth),
    Api = client(hex_api),
    Config = (Core:default_config())#{
        workload_identity_audience => <<"hexpm">>,
        cli_auth_callbacks => #{
            get_auth_config => fun(_) -> undefined end,
            get_oauth_tokens => fun() -> error end
        },
        http_adapter => {hex_http_httpc, #{http_options => [
            {timeout, 15000}, {connect_timeout, 5000}]}}
    },
    Scope = <<"package:hexpm/libtmux_erlang">>,
    case Auth:workload_identity_auth(Config, Scope) of
        {ok, <<"Bearer ", Token/binary>> = Bearer} ->
            case verify_revocation(Api, Config, Bearer, Token) of
                ok -> ok;
                {error, Reason} -> fail(atom_to_list(Reason))
            end,
            io:format("Authenticated with Workload Identity for ~s.~n"
                      "Hex rejected the revoked token; nothing uploaded.~n",
                      [Scope]),
            halt(0);
        none -> fail("No GitHub Workload Identity is available.");
        {error, _} -> fail("Workload Identity exchange failed; check the Hex "
                           "repository, workflow and environment settings.")
    end;
main(_) ->
    io:format(standard_error, "usage: check_hex_identity.erl~n", []),
    halt(2).

-spec client(module()) -> module().
client(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    Module.

-doc "Require a publish-only token's HTTP 403 to become HTTP 401 on revocation.".
-spec verify_revocation(module(), map(), binary(), binary()) ->
    ok | {error, token_verification_failed | token_revocation_failed}.
verify_revocation(Api, Config, Bearer, Token) ->
    Authenticated = Config#{api_key => Bearer},
    Path = <<"packages/libtmux_erlang">>,
    try
        Before = try Api:get(Authenticated, Path)
        after
            case Api:post(Config, <<"oauth/revoke">>,
                          #{<<"token">> => Token}) of
                {ok, {200, _, _}} -> ok;
                _ -> throw(token_revocation_failed)
            end
        end,
        After = Api:get(Authenticated, Path),
        io:format("Read-only API check: HTTP ~p before revocation, ~p after.~n",
                  [http_status(Before), http_status(After)]),
        % Package reads require api:read; publish-only tokens lack that scope.
        case {Before, After} of
            {{ok, {403, _, _}}, {ok, {401, _, _}}} -> ok;
            _ -> {error, token_verification_failed}
        end
    catch
        throw:token_revocation_failed -> {error, token_revocation_failed}
    end.

http_status({ok, {Status, _, _}}) -> Status;
http_status(_) -> request_failed.

-spec fail(string()) -> no_return().
fail(Message) ->
    io:format(standard_error, "~s~n", [Message]),
    halt(1).
