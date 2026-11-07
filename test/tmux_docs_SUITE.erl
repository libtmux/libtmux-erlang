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
