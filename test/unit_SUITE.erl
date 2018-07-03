-module(unit_SUITE).

-compile(export_all).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
        test_own_scope,
        test_validate_payload_resource_server_id_mismatch,
        test_validate_payload,
        test_successful_access_with_a_token,
        test_unsuccessful_access_with_a_token,
        test_command_json,
        test_command_pem,
        test_command_pem_no_kid
    ].

init_per_suite(Config) ->
    application:load(rabbitmq_auth_backend_uaa),
    Env = application:get_all_env(rabbitmq_auth_backend_uaa),
    Config1 = rabbit_ct_helpers:set_config(Config, {env, Env}),
    rabbit_ct_helpers:run_setup_steps(Config1, []).

end_per_suite(Config) ->
    Env = ?config(env, Config),
    lists:foreach(
        fun({K, V}) ->
            application:set_env(rabbitmq_auth_backend_uaa, K, V)
        end,
        Env),
    rabbit_ct_helpers:run_teardown_steps(Config).


%%
%% Test Cases
%%

-define(EXPIRATION_TIME, 2000).
-define(RESOURCE_SERVER_ID, <<"rabbitmq">>).

test_successful_access_with_a_token(_) ->
    %% Generate a token with JOSE
    %% Check authorization with the token
    %% Check user access granted by token
    Jwk = fixture_jwk(),
    application:set_env(uaa_jwt, signing_keys, #{<<"token-key">> => {map, Jwk}}),
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),
    Token = sign_token_hs(fixture_token(), Jwk),


    {ok, #auth_user{username = Token} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any),
    {ok, #{}} =
        rabbit_auth_backend_uaa:user_login_authorization(Token),

    ?assertEqual(true, rabbit_auth_backend_uaa:check_vhost_access(User, <<"vhost">>, none)),

    ?assertEqual(true, rabbit_auth_backend_uaa:check_resource_access(
             User,
             #resource{virtual_host = <<"vhost">>,
                       kind = queue,
                       name = <<"foo">>},
             configure)),
    ?assertEqual(true, rabbit_auth_backend_uaa:check_resource_access(
                         User,
                         #resource{virtual_host = <<"vhost">>,
                                   kind = exchange,
                                   name = <<"foo">>},
                         write)),

    ?assertEqual(true, rabbit_auth_backend_uaa:check_resource_access(
                         User,
                         #resource{virtual_host = <<"vhost">>,
                                   kind = custom,
                                   name = <<"bar">>},
                         read)),

    ?assertEqual(true, rabbit_auth_backend_uaa:check_topic_access(
                         User,
                         #resource{virtual_host = <<"vhost">>,
                                   kind = topic,
                                   name = <<"bar">>},
                         read,
                         #{routing_key => <<"#/foo">>})).

test_unsuccessful_access_with_a_token(_) ->
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),

    Jwk0   = fixture_jwk(),
    Token0 = sign_token_hs(fixture_token(), Jwk0),

    Jwk  = Jwk0#{<<"k">> => <<"bm90b2tlbmtleQ">>},
    application:set_env(uaa_jwt, signing_keys, #{<<"token-key">> => {map, Jwk}}),
    
    Token = sign_token_hs(fixture_token(), Jwk),

    ?assertMatch({refused, _, _},
                 rabbit_auth_backend_uaa:user_login_authentication(<<"not a token">>, any)),

    %% temporarily switch to the "correct" signing key
    application:set_env(uaa_jwt, signing_keys, #{<<"token-key">> => {map, Jwk0}}),
    %% this user can authenticate successfully and access certain vhosts
    {ok, #auth_user{username = Token0} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token0, any),
    application:set_env(uaa_jwt, signing_keys, #{<<"token-key">> => {map, Jwk}}),

    %% access to a different vhost
    ?assertEqual(false, rabbit_auth_backend_uaa:check_vhost_access(User, <<"different vhost">>, none)),

    %% access to these resources is not granted
    ?assertEqual(false, rabbit_auth_backend_uaa:check_resource_access(
              User,
              #resource{virtual_host = <<"vhost">>,
                        kind = queue,
                        name = <<"foo1">>},
              configure)),
    ?assertEqual(false, rabbit_auth_backend_uaa:check_resource_access(
              User,
              #resource{virtual_host = <<"vhost">>,
                        kind = custom,
                        name = <<"bar">>},
              write)),
    ?assertEqual(false, rabbit_auth_backend_uaa:check_topic_access(
              User,
              #resource{virtual_host = <<"vhost">>,
                        kind = topic,
                        name = <<"bar">>},
              read,
              #{routing_key => <<"foo/#">>})).

test_token_expiration(_) ->
    Jwk = fixture_jwk(),
    application:set_env(uaa_jwt, signing_keys, #{<<"token-key">> => {map, Jwk}}),
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),
    TokenData = expirable_token(),
    Token = sign_token_hs(TokenData, Jwk),
    {ok, #auth_user{username = Token} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any),
    true = rabbit_auth_backend_uaa:check_resource_access(
             User,
             #resource{virtual_host = <<"vhost">>,
                       kind = queue,
                       name = <<"foo">>},
             configure),
    true = rabbit_auth_backend_uaa:check_resource_access(
             User,
             #resource{virtual_host = <<"vhost">>,
                       kind = exchange,
                       name = <<"foo">>},
             write),

    wait_for_token_to_expire(),
    #{<<"exp">> := Exp} = TokenData,
    ExpectedError = "Auth token expired at unix time: " ++ integer_to_list(Exp),
    {error, ExpectedError} =
        rabbit_auth_backend_uaa:check_resource_access(
             User,
             #resource{virtual_host = <<"vhost">>,
                       kind = queue,
                       name = <<"foo">>},
             configure),

    {refused, _, _} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any).

test_command_json(_) ->
    Jwk = fixture_jwk(),
    Json = rabbit_json:encode(Jwk),
    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), json => Json}),
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),
    Token = sign_token_hs(fixture_token(), Jwk),
    {ok, #auth_user{username = Token} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any),

    true = rabbit_auth_backend_uaa:check_vhost_access(User, <<"vhost">>, none).

test_command_pem_file(Config) ->
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    PublicJwk  = jose_jwk:to_public(Jwk),
    PublicKeyFile = filename:join([CertsDir, "client", "public.pem"]),
    jose_jwk:to_pem_file(PublicKeyFile, PublicJwk),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem_file => PublicKeyFile}),

    Token = sign_token_rsa(fixture_token(), Jwk, <<"token-key">>),
    {ok, #auth_user{username = Token} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any),

    true = rabbit_auth_backend_uaa:check_vhost_access(User, <<"vhost">>, none).


test_command_pem_file_no_kid(Config) ->
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    PublicJwk  = jose_jwk:to_public(Jwk),
    PublicKeyFile = filename:join([CertsDir, "client", "public.pem"]),
    jose_jwk:to_pem_file(PublicKeyFile, PublicJwk),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem_file => PublicKeyFile}),

    %% Set default kid

    application:set_env(uaa_jwt, default_key, <<"token-key">>),

    Token = sign_token_no_kid(fixture_token(), Jwk),
    {ok, #auth_user{username = Token} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any),

    true = rabbit_auth_backend_uaa:check_vhost_access(User, <<"vhost">>, none).

test_command_pem(Config) ->
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    PublicJwk  = jose_jwk:to_public(Jwk),
    Pem = jose_jwk:to_pem(PublicJwk),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem => Pem}),

    Token = sign_token_rsa(fixture_token(), Jwk, <<"token-key">>),
    {ok, #auth_user{username = Token} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any),

    true = rabbit_auth_backend_uaa:check_vhost_access(User, <<"vhost">>, none).


test_command_pem_no_kid(Config) ->
    application:set_env(rabbitmq_auth_backend_uaa, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    PublicJwk  = jose_jwk:to_public(Jwk),
    Pem = jose_jwk:to_pem(PublicJwk),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem => Pem}),

    %% Set default kid

    application:set_env(uaa_jwt, default_key, <<"token-key">>),

    Token = sign_token_no_kid(fixture_token(), Jwk),
    {ok, #auth_user{username = Token} = User} =
        rabbit_auth_backend_uaa:user_login_authentication(Token, any),

    true = rabbit_auth_backend_uaa:check_vhost_access(User, <<"vhost">>, none).


test_own_scope(_) ->
    Examples = [
        {<<"foo">>, [<<"foo">>, <<"foo.bar">>, <<"bar.foo">>,
                     <<"one.two">>, <<"foobar">>, <<"foo.other.third">>],
                    [<<"bar">>, <<"other.third">>]},
        {<<"foo">>, [], []},
        {<<"foo">>, [<<"foo">>, <<"other.foo.bar">>], []},
        {<<"">>, [<<"foo">>, <<"bar">>], [<<"foo">>, <<"bar">>]}
    ],
    lists:map(
        fun({ResId, Src, Dest}) ->
            Dest = rabbit_auth_backend_uaa:filter_scope(Src, ResId)
        end,
        Examples).

test_validate_payload_resource_server_id_mismatch(_) ->
    NoKnownResourceServerId = #{<<"aud">>   => [<<"foo">>, <<"bar">>],
                                <<"scope">> => [<<"foo">>, <<"foo.bar">>,
                                                <<"bar.foo">>, <<"one.two">>,
                                                <<"foobar">>, <<"foo.other.third">>]},
    EmptyAud = #{<<"aud">>   => [],
                 <<"scope">> => [<<"foo.bar">>, <<"bar.foo">>]},

    ?assertEqual({refused, {invalid_aud, {resource_id_not_found_in_aud, ?RESOURCE_SERVER_ID,
                                          [<<"foo">>,<<"bar">>]}}},
                 rabbit_auth_backend_uaa:validate_payload(NoKnownResourceServerId, ?RESOURCE_SERVER_ID)),

    ?assertEqual({refused, {invalid_aud, {resource_id_not_found_in_aud, ?RESOURCE_SERVER_ID, []}}},
                 rabbit_auth_backend_uaa:validate_payload(EmptyAud, ?RESOURCE_SERVER_ID)).

test_validate_payload(_) ->
    KnownResourceServerId = #{<<"aud">>   => [?RESOURCE_SERVER_ID],
                              <<"scope">> => [<<"foo">>, <<"rabbitmq.bar">>,
                                              <<"bar.foo">>, <<"one.two">>,
                                              <<"foobar">>, <<"rabbitmq.other.third">>]},
    ?assertEqual({ok, #{<<"aud">>   => [?RESOURCE_SERVER_ID],
                        <<"scope">> => [<<"bar">>, <<"other.third">>]}},
                 rabbit_auth_backend_uaa:validate_payload(KnownResourceServerId, ?RESOURCE_SERVER_ID)).

expirable_token() ->
    TokenPayload = fixture_token(),
    TokenPayload#{<<"exp">> := os:system_time(seconds) + timer:seconds(?EXPIRATION_TIME)}.

wait_for_token_to_expire() ->
    timer:sleep(?EXPIRATION_TIME).

sign_token_hs(Token, #{<<"kid">> := TokenKey} = Jwk) ->
    sign_token_hs(Token, Jwk, TokenKey).

sign_token_hs(Token, Jwk, TokenKey) ->
    Jws = #{
      <<"alg">> => <<"HS256">>,
      <<"kid">> => TokenKey
    },
    sign_token(Token, Jwk, Jws).

sign_token_rsa(Token, Jwk, TokenKey) ->
    Jws = #{
      <<"alg">> => <<"RS256">>,
      <<"kid">> => TokenKey
    },
    sign_token(Token, Jwk, Jws).

sign_token_no_kid(Token, Jwk) ->
    Signed = jose_jwt:sign(Jwk, Token),
    jose_jws:compact(Signed).

sign_token(Token, Jwk, Jws) ->
    Signed = jose_jwt:sign(Jwk, Jws, Token),
    jose_jws:compact(Signed).

fixture_jwk() ->
    #{<<"alg">> => <<"HS256">>,
      <<"k">> => <<"dG9rZW5rZXk">>,
      <<"kid">> => <<"token-key">>,
      <<"kty">> => <<"oct">>,
      <<"use">> => <<"sig">>,
      <<"value">> => <<"tokenkey">>}.

fixture_token() ->
    Scope = [<<"rabbitmq.configure:vhost/foo">>,
             <<"rabbitmq.write:vhost/foo">>,
             <<"rabbitmq.read:vhost/foo">>,
             <<"rabbitmq.read:vhost/bar">>,
             <<"rabbitmq.read:vhost/bar/%23%2Ffoo">>],

    #{<<"exp">> => os:system_time(seconds) + 3000,
      <<"kid">> => <<"token-key">>,
      <<"iss">> => <<"unit_test">>,
      <<"foo">> => <<"bar">>,
      <<"aud">> => [<<"rabbitmq">>],
      <<"scope">> => Scope}.
