-module(plan_demo).
-moduledoc "Explain a query, let tmux exclude candidates, then fetch it.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            Cat = #{launch => #{argv => [<<"/bin/cat">>]}},
            Wide = Cat#{name => <<"plan">>, width => 120, height => 30},
            {ok, Session} = tmux_session:create(Server, Wide),
            {ok, Window} = tmux_window:create(Session, Cat),
            {ok, _} = tmux_pane:split(Window, Cat#{direction => horizontal}),
            Criteria = #{width => #{lt => 100},
                current_command => <<"cat">>},
            Query = tmux_query:where(Criteria, tmux_query:panes(Server)),
            Pushed = tmux_query:pushdown(true, Query),
            % explain/1 does no I/O: it only describes what fetch would run.
            #{candidate := #{format := Local}} = tmux_query:explain(Query),
            #{candidate := #{format := Native, local_only := Kept}} =
                tmux_query:explain(Pushed),
            {ok, Everything} = tmux_query:fetch(Query),
            {ok, Narrowed} = tmux_query:fetch(Pushed),
            {ok, Isolated} = tmux_query:fetch(Pushed,
                #{hydration => isolated}),
            Ids = ids(Narrowed),
            2 = length(Ids),
            Ids = ids(Everything),
            Ids = ids(Isolated),
            #{local_candidate => Local, native_candidate => Native,
              kept_local => [maps:get(field, Reason) || Reason <- Kept],
              matched_panes => length(Ids), same_rows => true}
        end),
    Result.

ids(Selection) ->
    [tmux_model:get(id, Pane) || Pane <- tmux_select:to_list(Selection)].
