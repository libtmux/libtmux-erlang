-module(tmux_docs_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, native_examples/1]).

all() -> [native_examples].

native_examples(_Config) ->
    Modules = lists:append([begin
        case application:load(App) of
            ok -> ok;
            {error, {already_loaded, App}} -> ok
        end,
        {ok, Members} = application:get_key(App, modules),
        Members
    end || App <- [libtmux_erlang]]),
    lists:foreach(fun(Module) ->
        %% Prose-only contracts need no artificial example. Every advertised
        %% Erlang code block must contain a runnable shell transcript.
        Result = ct_doctest:module(Module, [
            {skipped_blocks, 0}
        ]),
        case Result of
            ok -> ok;
            {comment, _MissingExamples} -> ok
        end
    end, Modules).
