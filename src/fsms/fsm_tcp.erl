%%% TCP FSM Reference
%%%

-module(fsm_tcp).
-author("David Rossier - david.rossier@kudelskisecurity.com").
-author("Adrien Giner - adrien.giner@kudelskisecurity.com").
-behavior(gen_fsm).

-include("../includes/args.hrl").

-export([start_link/1, start/1]).
-export([init/1, terminate/3, handle_info/3]).
-export([code_change/4, handle_sync_event/4, handle_event/3]).
-export([connecting/2, callback/2]).

% see http://erlang.org/doc/man/inet.html#setopts-2
-define(COPTS, [binary, {packet, 0}, inet, {recbuf, 65536}, {active, false}, {reuseaddr, true}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% debug
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% send debug
debug(Args, Msg) ->
  utils:debug(fpmodules, Msg,
    {Args#args.target, Args#args.id}, Args#args.debugval).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API calls
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% called by "handle_info" when timeout occurs
callback(timeout, Data) when Data#args.retrycnt > 0 andalso Data#args.packetrcv == 0
      andalso Data#args.payload /= << >>  ->
  send_data(Data#args{retrycnt=Data#args.retrycnt-1});
callback(timeout, Data) ->
  case apply(Data#args.module, callback_next_step, [Data]) of
    {continue, Nbpacket, Payload, ModData} ->
      flush_socket(Data#args.socket),
      inet:setopts(Data#args.socket, [{active, once}]), % we want a packet
      send_data(Data#args{moddata=ModData,nbpacket=Nbpacket,payload=Payload});
    {restart, {Target, Port}, ModData} ->
      Newtarget = case Target == undefined of true -> Data#args.ctarget; false -> Target end,
      Newport = case Port == undefined of true -> Data#args.cport; false -> Port end,
      gen_tcp:close(Data#args.socket),
      {next_state, connecting, Data#args{ctarget=Newtarget, cport=Newport,
        moddata=ModData, sending=false, retrycnt=Data#args.retry,
        datarcv = << >>, payload = << >>, packetrcv=0}, 0};
    {result, Result} ->
      gen_tcp:close(Data#args.socket),
      {stop, normal, Data#args{result=Result}} % RESULT
  end.

send_data(Data) ->
  case gen_tcp:send(Data#args.socket, Data#args.payload) of
    ok ->
      {next_state, callback, Data#args{
        sending=true,
        datarcv = << >>,
        packetrcv = 0
        },
      Data#args.timeout};
    {error, Reason} ->
      {next_state, callback, Data#args{sndreason=Reason}, 0}
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_fsm modules (http://www.erlang.org/doc/man/gen_fsm.html)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% this is when there's no supervisor Args is an #args record
start_link(Args) ->
  gen_fsm:start_link(?MODULE, Args, []).
% this is when it's part of a supervised tree
start([Args]) ->
  gen_fsm:start(?MODULE, Args, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_fsm callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% called by start/start_link
init(Args) ->
  doit(Args#args{ctarget=Args#args.target, cport=Args#args.port, retrycnt=Args#args.retry}).

% start the process
doit(Args) ->
  debug(Args, io_lib:fwrite("~p on ~p", [Args#args.module, Args#args.ctarget])),
  % first let's call "connect" through "connecting" using a timeout of 0
  {ok, connecting, Args, 0}.

% get privport opt
get_privports(true) ->
  [{port, rand:uniform(1024)}];
get_privports(_) ->
  [].

% provide the socket option
get_options(Args) ->
  ?COPTS ++ get_privports(Args#args.privports)
    ++ Args#args.fsmopts.

% State connecting is used to initiate the tcp connection
connecting(timeout, Data) ->
  Host = Data#args.ctarget, Port = Data#args.cport, Timeout = Data#args.timeout,
  case utils_fp:lookup(Host, Timeout, Data#args.checkwww) of
    {ok, Addr} ->
      try
        case gen_tcp:connect(Addr, Port, get_options(Data), Timeout) of
          {ok, Socket} ->
            {next_state, callback, Data#args{socket=Socket, ipaddr=Addr}, 0};
          {error, Reason} ->
            gen_fsm:send_event(self(), {error, list_to_atom("tcp_" ++ atom_to_list(Reason))}),
            {next_state, connecting, Data}
        end
      catch
        _:_ ->
          gen_fsm:send_event(self(), {error, tcp_conn_badaddr}),
          {next_state, connecting, Data}
      end;
    {error, Reason} ->
      gen_fsm:send_event(self(), {error, Reason}),
      {next_state, connecting, Data}
  end;
% called when connection is refused
connecting({error, econnrefused=Reason}, Data) ->
  {stop, normal, Data#args{result={{error, up}, Reason}}}; % RESULT
% called when connection is reset
connecting({error, econnreset=Reason}, Data) ->
  {stop, normal, Data#args{result={{error, up}, Reason}}}; % RESULT
% called when source port is already taken
connecting({error, tcp_eacces}, Data)
when Data#args.privports == true, Data#args.eaccess_retry < Data#args.eaccess_max ->
  {next_state, connecting, Data#args{eaccess_retry=Data#args.eaccess_retry+1}, 0};
% called when connection failed
connecting({error, Reason}, Data) ->
  {stop, normal, Data#args{result={{error, unknown}, Reason}}}. % RESULT

%% called by stop
terminate(_Reason, _State, Data) ->
  Result = {Data#args.module, Data#args.target, Data#args.port, Data#args.result},
  debug(Data, io_lib:fwrite("~p done on ~p (outdirect:~p)",
    [Data#args.module, Data#args.target, Data#args.direct])),
  case Data#args.direct of
    true ->
      utils:outputs_send(Data#args.outobj, [Result]);
    false ->
      Data#args.parent ! Result
  end,
  ok.

flush_socket(Socket) ->
  case gen_tcp:recv(Socket, 0, 0) of
    {error, _Reason} ->
      ok;
    {ok, _Result} ->
      flush_socket(Socket)
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% event handlers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% called when a new packet is received
handle_info({tcp, _Socket, Packet}, callback, Data) ->
  case Data#args.nbpacket of
    infinity ->
      inet:setopts(Data#args.socket, [{active, once}]), % We want more
      {next_state, callback, Data#args{
        datarcv = <<(Data#args.datarcv)/binary, Packet/binary>>,
        packetrcv = Data#args.packetrcv + 1
        },
      Data#args.timeout};
    1 -> % It is the last packet to receive
      {next_state, callback, Data#args{
        datarcv = <<(Data#args.datarcv)/binary, Packet/binary>>,
        nbpacket = 0,
        packetrcv = Data#args.packetrcv + 1
        },
      0};
    0 -> % If they didn't want any packet ?
      {stop, normal, Data#args{result={
        {error,up},[toomanypacketreceived, Packet]}}}; % RESULT
    _ -> % They are more packets (maybe)
      inet:setopts(Data#args.socket, [{active, once}]), % We want more
      {next_state, callback, Data#args{
        datarcv = <<(Data#args.datarcv)/binary, Packet/binary>>,
        nbpacket=Data#args.nbpacket - 1,
        packetrcv = Data#args.packetrcv + 1
        },
      Data#args.timeout}
  end;
handle_info({tcp_closed=Reason, _Socket}, _State, Data) ->
  % Happen when there was still packets to receive
  % but the tcp port is closed
  {next_state, callback, Data#args{rcvreason=Reason}, 0};
% called when error on socket
handle_info({tcp_error, _Socket, Reason}, _State, Data) ->
  {next_state, callback, Data#args{rcvreason=Reason}, 0};
% called when domain lookup failed
handle_info({timeout, _Socket, inet}, _State, Data) ->
  {stop, normal, Data#args{result={{error, unknown}, dns_timeout}}}. % RESULT

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% UNUSED event handlers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
code_change(_Prev, State, Data, _Extra) ->
  {ok , State, Data}.
handle_sync_event(_Ev, _From, _State, Data) ->
  {stop, unexpectedSyncEvent, Data}.
handle_event(_Ev, _State, Data) ->
  {stop, unexpectedEvent, Data}.

