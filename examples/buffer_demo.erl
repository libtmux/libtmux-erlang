-module(buffer_demo).
-moduledoc "Store a binary artifact without terminal or text conversion.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Name = <<"libtmux-example-",
        (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>,
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        tmux_scope:run_or_error(fun() ->
            Bytes = <<0, 255, "build\n%end 1 2 3\n\\r">>,
            {ok, _} = tmux_buffer:load(Server, Name, Bytes),
            {ok, Bytes} = tmux_buffer:show(Server, Name),
            {ok, [#{name := Name, size := Size} | _]} =
                tmux_buffer:list(Server),
            Size = byte_size(Bytes),
            {ok, _} = tmux_buffer:load(Server, Name, <<>>),
            {ok, Bytes} = tmux_buffer:show(Server, Name),
            #{byte_count => Size, exact_round_trip => true,
              empty_load_kept_bytes => true}
        end, fun() ->
            case tmux_buffer:delete(Server, Name) of
                {ok, _} -> ok;
                {error, #{code := buffer_not_found}} -> ok;
                Failure -> error({buffer_cleanup_failed, Failure})
            end,
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
