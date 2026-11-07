-module(tmux_sup).
-moduledoc false.
-behaviour(supervisor).
-export([start_link/0, init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Registry = #{id => tmux_registry, start => {tmux_registry, start_link, []},
                 restart => permanent, shutdown => 1000},
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Registry]}}.
