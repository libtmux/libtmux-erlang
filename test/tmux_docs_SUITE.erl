-module(tmux_docs_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, native_examples/1]).

all() -> [native_examples].

native_examples(_Config) ->
    case application:load(libtmux_erlang) of
        ok -> ok;
        {error, {already_loaded, libtmux_erlang}} -> ok
    end,
    {ok, Modules} = application:get_key(libtmux_erlang, modules),
    lists:foreach(fun(Module) ->
        DocumentationOnly = case Module of
            tmux_model -> [{bind, 3}];
            tmux_filter -> [{predicate, 1}];
            tmux_select -> [{matching, 2}];
            _ -> []
        end,
        ok = ct_doctest:module(Module, [
            {skipped_blocks, 0}, {missing_tests, DocumentationOnly}
        ])
    end, Modules).
