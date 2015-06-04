%%%--------------------------------------------------------------------
%%% @author Konrad Zemek
%%% @copyright (C) 2015 ACK CYFRONET AGH
%%% This software is released under the MIT license
%%% cited in 'LICENSE.txt'.
%%% @end
%%%--------------------------------------------------------------------
%%% @doc Main API module for SSL2.
%%%--------------------------------------------------------------------
-module(ssl2).
-author("Konrad Zemek").

%% API
-export([connect/3, connect/4, send/2, recv/2, recv/3, listen/2,
    accept/1, accept/2, handshake/1, handshake/2, setopts/2,
    controlling_process/2, peername/1, sockname/1, close/1, peercert/1]).

-record(sock_ref, {
    socket :: term(),
    supervisor :: pid(),
    receiver :: pid(),
    sender :: pid()
}).

%%%===================================================================
%%% API
%%%===================================================================

connect(Host, Port, Options) ->
    connect(Host, Port, Options, infinity).

connect(Host, Port, Options, Timeout) ->
    Ref = make_ref(),
    case ssl2_nif:connect(Ref, Host, Port) of
        ok ->
            receive
                {Ref, {ok, Sock}} -> start_socket_processes(Sock, Options);
                {Ref, Result} -> Result
            after Timeout ->
                {error, timeout}
            end;

        {error, Reason} ->
            {error, Reason}
    end.

send(#sock_ref{sender = Sender}, Data) ->
    gen_fsm:sync_send_event(Sender, {send, Data}, infinity).

recv(SockRef, Size) ->
    recv(SockRef, Size, infinity).

recv(#sock_ref{receiver = Receiver}, Size, Timeout) ->
    gen_fsm:sync_send_event(Receiver, {recv, Size, Timeout}, infinity).

listen(Port, Options) ->
    true = proplists:is_defined(certfile, Options),
    CertPath = proplists:get_value(certfile, Options),
    KeyPath = proplists:get_value(keyfile, Options, CertPath),
    ssl2_nif:listen(Port, CertPath, KeyPath).

accept(Acceptor) ->
    accept(Acceptor, infinity).

accept(Acceptor, Timeout) ->
    Ref = make_ref(),
    case ssl2_nif:accept(Ref, Acceptor) of
        ok ->
            receive
                {Ref, {ok, Sock}} -> start_socket_processes(Sock, []);
                {Ref, Result} -> Result
            after Timeout ->
                {error, timeout}
            end;

        {error, Reason} ->
            {error, Reason}
    end.

handshake(Socket) ->
    handshake(Socket, infinity).

handshake(#sock_ref{socket = Sock}, Timeout) ->
    Ref = make_ref(),
    case ssl2_nif:handshake(Ref, Sock) of
        ok ->
            receive
                {Ref, Result} -> Result
            after Timeout ->
                {error, timeout}
            end;

        {error, Reason} ->
            {error, Reason}
    end.

setopts(#sock_ref{receiver = Receiver, sender = Sender}, Options) ->
    gen_fsm:send_all_state_event(Receiver, {setopts, Options}),
    gen_fsm:send_all_state_event(Sender, {setopts, Options}),
    ok.

controlling_process(#sock_ref{receiver = Receiver}, Pid) ->
    gen_fsm:send_all_state_event(Receiver, {controlling_process, Pid}),
    ok.

peername(#sock_ref{socket = Sock}) ->
    parse_name_result(ssl2_nif:peername(Sock)).

sockname(#sock_ref{socket = Sock}) ->
    parse_name_result(ssl2_nif:sockname(Sock)).

close(#sock_ref{socket = Sock, supervisor = Sup}) ->
    ok = supervisor:terminate_child(ssl2_sup, Sup),
    case ssl2_nif:close(Sock) of
        {error, Reason} -> {error, Reason};
        Else -> Else
    end.

peercert(#sock_ref{socket = Sock}) ->
    case ssl2_nif:certificate_chain(Sock) of
        {ok, []} -> {error, no_peer_certificate};
        {ok, Chain} -> {ok, lists:last(Chain)};
        {error, Reason} -> {error, Reason}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_socket_processes(Sock, Options) ->
    Args = [Sock, Options, self()],
    {ok, Sup} = supervisor:start_child(ssl2_sup, Args),

    Children = supervisor:which_children(Sup),
    {_, Receiver, _, _} = lists:keyfind(receiver, 1, Children),
    {_, Sender, _, _} = lists:keyfind(sender, 1, Children),

    SockRef = #sock_ref{socket = Sock, supervisor = Sup,
        receiver = Receiver, sender = Sender},

    gen_fsm:send_all_state_event(Receiver, {sock_ref, SockRef}),

    {ok, SockRef}.

parse_name_result({ok, {StrAddress, Port}}) ->
    {ok, Addr} = inet:parse_ipv4_address(StrAddress),
    {ok, {Addr, Port}};
parse_name_result(Result) ->
    Result.
