-module(libtmux_erlang_app).
-moduledoc false.
-behaviour(application).
-export([start/2, prep_stop/1, stop/1]).

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case erlang:system_info(otp_release) of
        "29" ->
            {module, tmux_model} = code:ensure_loaded(tmux_model),
            tmux_sup:start_link();
        Version -> {error, {unsupported_otp_release, Version}}
    end.

-spec stop(term()) -> ok.
stop(_State) -> ok.

-spec prep_stop(term()) -> term().
prep_stop(State) ->
    case tmux_owned_server:prepare_stop() of
        ok -> ok;
        {error, Report} -> tmux_log:shutdown(Report)
    end,
    State.
