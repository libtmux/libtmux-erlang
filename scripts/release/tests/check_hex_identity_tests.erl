-module(check_hex_identity_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").
-export([get/2, post/3]).

revocation_omits_client_id_and_confirms_token_rejection_test() ->
    erase(revoked),
    ?assertEqual(ok, check_hex_identity:verify_revocation(
        ?MODULE, #{}, <<"Bearer fixture">>, <<"fixture">>)),
    ?assertEqual(#{<<"token">> => <<"fixture">>}, erase(revoked)).

a_successful_revoke_response_alone_does_not_prove_revocation_test() ->
    erase(revoked),
    ?assertEqual({error, token_verification_failed},
        check_hex_identity:verify_revocation(
            ?MODULE, #{ineffective_revoke => true},
            <<"Bearer fixture">>, <<"fixture">>)),
    erase(revoked).

get(#{api_key := <<"Bearer fixture">>} = Config,
    <<"packages/libtmux_erlang">>) ->
    Effective = not maps:get(ineffective_revoke, Config, false),
    case {get(revoked), Effective} of
        {undefined, _} -> {ok, {403, #{}, #{}}};
        {_, false} -> {ok, {403, #{}, #{}}};
        {_, true} -> {ok, {401, #{}, #{}}}
    end.

post(_Config, <<"oauth/revoke">>, Params) ->
    put(revoked, Params),
    {ok, {200, #{}, nil}}.
