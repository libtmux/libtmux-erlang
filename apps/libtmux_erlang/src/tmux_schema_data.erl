%% Generated from schema/entities.json by tools/generate_schema.escript.
-module(tmux_schema_data).
-moduledoc false.
-export([entities/0, fields/1, relations/1, wire_entity/1]).

-spec entities() -> [atom()].
entities() -> [session, window, window_link, pane].

-spec fields(atom()) -> #{atom() => map()}.
fields(session) -> #{
    id => #{type => session_id, wire => <<"id">>, stable => <<"tmux.session.id">>, required => true, nullable => false, format => <<"session_id">>},
    name => #{type => text, wire => <<"name">>, stable => <<"tmux.session.name">>, required => false, nullable => false, format => <<"session_name">>},
    attached_count => #{type => uint, wire => <<"attachedCount">>, stable => <<"tmux.session.attachedCount">>, required => false, nullable => false, format => <<"session_attached">>},
    attached => #{type => boolean, wire => <<"attached">>, stable => <<"tmux.session.attached">>, required => false, nullable => false},
    created => #{type => uint, wire => <<"created">>, stable => <<"tmux.session.created">>, required => false, nullable => false, format => <<"session_created">>}
};
fields(window) -> #{
    id => #{type => window_id, wire => <<"id">>, stable => <<"tmux.window.id">>, required => true, nullable => false, format => <<"window_id">>},
    name => #{type => text, wire => <<"name">>, stable => <<"tmux.window.name">>, required => false, nullable => false, format => <<"window_name">>},
    width => #{type => uint, wire => <<"width">>, stable => <<"tmux.window.width">>, required => false, nullable => false, format => <<"window_width">>},
    height => #{type => uint, wire => <<"height">>, stable => <<"tmux.window.height">>, required => false, nullable => false, format => <<"window_height">>},
    pane_count => #{type => uint, wire => <<"paneCount">>, stable => <<"tmux.window.paneCount">>, required => false, nullable => false, format => <<"window_panes">>},
    layout => #{type => text, wire => <<"layout">>, stable => <<"tmux.window.layout">>, required => false, nullable => false, format => <<"window_layout">>}
};
fields(window_link) -> #{
    session_id => #{type => session_id, wire => <<"sessionId">>, stable => <<"tmux.windowLink.sessionId">>, required => true, nullable => false, format => <<"session_id">>},
    window_id => #{type => window_id, wire => <<"windowId">>, stable => <<"tmux.windowLink.windowId">>, required => true, nullable => false, format => <<"window_id">>},
    index => #{type => uint, wire => <<"index">>, stable => <<"tmux.windowLink.index">>, required => true, nullable => false, format => <<"window_index">>},
    active => #{type => boolean, wire => <<"active">>, stable => <<"tmux.windowLink.active">>, required => false, nullable => false, format => <<"window_active">>}
};
fields(pane) -> #{
    id => #{type => pane_id, wire => <<"id">>, stable => <<"tmux.pane.id">>, required => true, nullable => false, format => <<"pane_id">>},
    window_id => #{type => window_id, wire => <<"windowId">>, stable => <<"tmux.pane.windowId">>, required => false, nullable => false, format => <<"window_id">>},
    index => #{type => uint, wire => <<"index">>, stable => <<"tmux.pane.index">>, required => false, nullable => false, format => <<"pane_index">>},
    active => #{type => boolean, wire => <<"active">>, stable => <<"tmux.pane.active">>, required => false, nullable => false, format => <<"pane_active">>},
    current_command => #{type => text, wire => <<"currentCommand">>, stable => <<"tmux.pane.currentCommand">>, required => false, nullable => false, format => <<"pane_current_command">>},
    current_path => #{type => bytes, wire => <<"currentPath">>, stable => <<"tmux.pane.currentPath">>, required => false, nullable => false, format => <<"pane_current_path">>},
    width => #{type => uint, wire => <<"width">>, stable => <<"tmux.pane.width">>, required => false, nullable => false, format => <<"pane_width">>},
    height => #{type => uint, wire => <<"height">>, stable => <<"tmux.pane.height">>, required => false, nullable => false, format => <<"pane_height">>},
    pid => #{type => uint, wire => <<"pid">>, stable => <<"tmux.pane.pid">>, required => false, nullable => true, minimum => 1, format => <<"pane_pid">>},
    title => #{type => text, wire => <<"title">>, stable => <<"tmux.pane.title">>, required => false, nullable => false, format => <<"pane_title">>},
    dead => #{type => boolean, wire => <<"dead">>, stable => <<"tmux.pane.dead">>, required => false, nullable => false, format => <<"pane_dead">>},
    exit_status => #{type => integer, wire => <<"exitStatus">>, stable => <<"tmux.pane.exitStatus">>, required => false, nullable => true, format => <<"pane_dead_status">>}
}.

-spec relations(atom()) -> #{atom() => map()}.
relations(session) -> #{windows => #{kind => many, target => window, wire => <<"windows">>, stable => <<"tmux.session.windows">>}, window_links => #{kind => many, target => window_link, wire => <<"windowLinks">>, stable => <<"tmux.session.windowLinks">>}};
relations(window) -> #{panes => #{kind => many, target => pane, wire => <<"panes">>, stable => <<"tmux.window.panes">>}, window_links => #{kind => many, target => window_link, wire => <<"windowLinks">>, stable => <<"tmux.window.windowLinks">>}};
relations(window_link) -> #{session => #{kind => one, target => session, wire => <<"session">>, stable => <<"tmux.windowLink.session">>}, window => #{kind => one, target => window, wire => <<"window">>, stable => <<"tmux.windowLink.window">>}};
relations(pane) -> #{window => #{kind => one, target => window, wire => <<"window">>, stable => <<"tmux.pane.window">>}}.

-spec wire_entity(atom()) -> binary().
wire_entity(session) -> <<"session">>;
wire_entity(window) -> <<"window">>;
wire_entity(window_link) -> <<"windowLink">>;
wire_entity(pane) -> <<"pane">>.
