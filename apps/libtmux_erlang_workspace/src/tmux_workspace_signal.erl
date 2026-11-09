-module(tmux_workspace_signal).
-moduledoc false.
-behaviour(gen_event).
-export([init/1, handle_event/2, handle_call/2, handle_info/2,
         terminate/2, code_change/3]).

%% Installed only in the CLI's fresh VM; a library never replaces host handlers.
-spec init({pid(), reference()}) -> {ok, {pid(), reference()}}.
init(State) -> {ok, State}.
-spec handle_event(term(), {pid(), reference()}) -> {ok, {pid(), reference()}}.
handle_event(sigterm, {Pid, Ref} = State) ->
    Pid ! {tmux_workspace_cancel, Ref}, {ok, State};
handle_event(_, State) -> {ok, State}.
-spec handle_call(term(), term()) -> {ok, ok, term()}.
handle_call(_, State) -> {ok, ok, State}.
-spec handle_info(term(), term()) -> {ok, term()}.
handle_info(_, State) -> {ok, State}.
-spec terminate(term(), term()) -> ok.
terminate(_, _) -> ok.
-spec code_change(term(), term(), term()) -> {ok, term()}.
code_change(_, State, _) -> {ok, State}.
