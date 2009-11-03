%% @author Bob Ippolito <bob@mochimedia.com>
%% @copyright 2007 Mochi Media, Inc.

%% @doc MochiWeb socket server.

-module(mochiweb_socket_server).
-author('bob@mochimedia.com').
-behaviour(gen_server).

-export([start/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3,
         handle_info/2]).
-export([get/2]).

-export([acceptor_loop/1]).

-record(mochiweb_socket_server,
        {port,
         loop,
         name=undefined,
         max=2048,
         ip=any,
         listen=null,
         acceptor=null,
         backlog=128,
         ssl=false,
         % SSL options
         keyfile=null,
        certfile=null,
        verify=0,
        depth=1,
        password=null,
        cacertfile=null,
        ciphers=null,
        cachetimeout=null}).

start(State=#mochiweb_socket_server{}) ->
    start_server(State);
start(Options) ->
    start(parse_options(Options)).

get(Name, Property) ->
    gen_server:call(Name, {get, Property}).

stop(Name) when is_atom(Name) ->
    gen_server:cast(Name, stop);
stop(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, stop);
stop({local, Name}) ->
    stop(Name);
stop({global, Name}) ->
    stop(Name);
stop(Options) ->
    State = parse_options(Options),
    stop(State#mochiweb_socket_server.name).

%% Internal API

parse_options(Options) ->
    parse_options(Options, #mochiweb_socket_server{}).

parse_options([], State) ->
    State;
parse_options([{name, L} | Rest], State) when is_list(L) ->
    Name = {local, list_to_atom(L)},
    parse_options(Rest, State#mochiweb_socket_server{name=Name});
parse_options([{name, A} | Rest], State) when is_atom(A) ->
    Name = {local, A},
    parse_options(Rest, State#mochiweb_socket_server{name=Name});
parse_options([{name, Name} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{name=Name});
parse_options([{port, L} | Rest], State) when is_list(L) ->
    Port = list_to_integer(L),
    parse_options(Rest, State#mochiweb_socket_server{port=Port});
parse_options([{port, Port} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{port=Port});
parse_options([{ip, Ip} | Rest], State) ->
    ParsedIp = case Ip of
                   any ->
                       any;
                   Ip when is_tuple(Ip) ->
                       Ip;
                   Ip when is_list(Ip) ->
                       {ok, IpTuple} = inet_parse:address(Ip),
                       IpTuple
               end,
    parse_options(Rest, State#mochiweb_socket_server{ip=ParsedIp});
parse_options([{loop, Loop} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{loop=Loop});
parse_options([{backlog, Backlog} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{backlog=Backlog});

parse_options([{ssl, Ssl} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{ssl=Ssl});
parse_options([{keyfile, SslKeyFile} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{keyfile=SslKeyFile});
parse_options([{certfile, SslCertFile} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{certfile=SslCertFile});
parse_options([{cacertfile, SslCACertFile} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{cacertfile=SslCACertFile});
parse_options([{verify, SslVerify} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{verify=SslVerify});
parse_options([{depth, SslDepth} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{depth=SslDepth});
parse_options([{password, SslPassword} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{password=SslPassword});
parse_options([{ciphers, SslCiphers} | Rest], State) ->
    parse_options(Rest, State#mochiweb_socket_server{ciphers=SslCiphers});

parse_options([{max, Max} | Rest], State) ->
    MaxInt = case Max of
                 Max when is_list(Max) ->
                     list_to_integer(Max);
                 Max when is_integer(Max) ->
                     Max
             end,
    parse_options(Rest, State#mochiweb_socket_server{max=MaxInt}).

start_server(State=#mochiweb_socket_server{name=Name}) ->
    case Name of
        undefined ->
            gen_server:start_link(?MODULE, State, []);
        _ ->
            gen_server:start_link(Name, ?MODULE, State, [])
    end.

ipv6_supported() ->
  case (catch inet:getaddr("localhost", inet6)) of
    {ok, _Addr} ->
      true;
    {error, _} ->
      false
  end.

init(State=#mochiweb_socket_server{ip=Ip, port=Port, backlog=Backlog, ssl=Ssl}) ->
  process_flag(trap_exit, true),
  Opts = if
           Ssl ->
             ssl_opts(Ip, State);
           true ->
             opts(Ip, Backlog)
         end,
  case gen_tcp_listen(Port, Opts, State) of
    {stop, eacces} ->
      case Port < 1024 of
        true ->
          case fdsrv:start() of
            {ok, _} ->
              case fdsrv:bind_socket(tcp, Port) of
                {ok, Fd} ->
                  gen_tcp_listen(Port, [{fd, Fd} | Opts], State);
                _ ->
                  {stop, fdsrv_bind_failed}
              end;
            _ ->
              {stop, fdsrv_start_failed}
          end;
        false ->
          {stop, eacces}
      end;
    Other ->
      Other
  end.

opts(Ip, Backlog) ->
  BaseOpts = [binary,
              {reuseaddr, true},
              {packet, 0},
              {backlog, Backlog},
              {recbuf, 8192},
              {active, false},
              {nodelay, true}],
  case Ip of
    any ->
      case ipv6_supported() of % IPv4, and IPv6 if supported
        true -> [inet, inet6 | BaseOpts];
        _ -> BaseOpts
      end;
    undefined ->
      BaseOpts;
    {_, _, _, _} -> % IPv4
      [inet, {ip, Ip} | BaseOpts];
    {_, _, _, _, _, _, _, _} -> % IPv6
      [inet6, {ip, Ip} | BaseOpts]
  end.

ssl_opts(Ip, State) when is_tuple(Ip) ->
  Opts = [
          binary,
          {packet, http},
          {ip, Ip},
          {active, false} | ssl_opts(State)],
  Opts;
ssl_opts(_Ip, State) ->
  Opts = [
          binary,
          {packet, http},
          {active, false} | ssl_opts(State)],
  Opts.

ssl_opts(#mochiweb_socket_server{keyfile=Keyfile,
                                 certfile=Certfile,
                                 verify=Verify,
                                 depth=Depth,
                                 password=Password,
                                 cacertfile=CACertFile,
                                 ciphers=Ciphers,
                                 cachetimeout=_CacheTimeout}) ->
  L = [if Keyfile =/= null ->
           {keyfile, Keyfile};
          true ->
           false
       end,
       if Certfile =/= null ->
           {certfile, Certfile};
          true ->
           false
       end,
       if CACertFile =/= null  ->
           {cacertfile, CACertFile};
          true ->
           false
       end,

       {verify, Verify},
       {depth, Depth},

       if Password =/= null ->
           {password, Password};
          true ->
           false
       end,
       if Ciphers =/= null ->
           {ciphers, Ciphers};
          true ->
           false
       end
      ],
  filter_false(L).

filter_false(L) ->
  [X || X <- L, X /= false].

gen_tcp_listen(Port, Opts, State=#mochiweb_socket_server{ssl=Ssl}) ->
  case do_listen(Port, Opts, Ssl) of
    {ok, Listen, ListenPort} ->
      {ok, new_acceptor(State#mochiweb_socket_server{listen=Listen,
                                                     port=ListenPort})};
    {error, Reason} ->
      {stop, Reason}
  end.

do_listen(Port, Opts, Ssl) when Ssl =:= true->
	application:start(ssl),
	{ok, Listen} = ssl:listen(Port, Opts),
	{ok, Listen, Port};
do_listen(Port, Opts, _Ssl) ->
	{ok, Listen} = gen_tcp:listen(Port, Opts),
	{ok, ListenPort} = inet:port(Listen),
	{ok, Listen, ListenPort}.

new_acceptor(State=#mochiweb_socket_server{max=0}) ->
    io:format("Not accepting new connections~n"),
    State#mochiweb_socket_server{acceptor=null};
new_acceptor(State=#mochiweb_socket_server{listen=Listen, loop=Loop, ssl=Ssl}) ->
    Pid = proc_lib:spawn_link(?MODULE, acceptor_loop,
                              [{self(), Listen, Loop, Ssl}]),
    State#mochiweb_socket_server{acceptor=Pid}.

call_loop({M, F}, Socket) ->
    M:F(Socket);
call_loop(Loop, Socket) ->
    Loop(Socket).

acceptor_loop({Server, Listen, Loop, Ssl}) ->
  case catch do_accept(Listen, Ssl) of
    {ok, Socket} ->
      gen_server:cast(Server, {accepted, self()}),
      call_loop(Loop, Socket);
    {error, closed} ->
      exit({error, closed});
    Other ->
      error_logger:error_report(
        [{application, mochiweb},
         "Accept failed error",
         lists:flatten(io_lib:format("~p", [Other]))]),
      exit({error, accept_failed})
  end.

do_accept(Listen, Ssl) when Ssl =:= true ->
  {ok, Socket} = ssl:transport_accept(Listen),
	case ssl:ssl_accept(Socket) of
		ok ->
			{ok, Socket};
		Error ->
			error_logger:error_report("Ssl accept failed: ~p~n",
                                [Error]),
			Error
	end;
do_accept(Listen, _Ssl) ->
  gen_tcp:accept(Listen).

do_get(port, #mochiweb_socket_server{port=Port}) ->
  Port.

handle_call({get, Property}, _From, State) ->
    Res = do_get(Property, State),
    {reply, Res, State};
handle_call(_Message, _From, State) ->
    Res = error,
    {reply, Res, State}.

handle_cast({accepted, Pid},
            State=#mochiweb_socket_server{acceptor=Pid, max=Max}) ->
    % io:format("accepted ~p~n", [Pid]),
    State1 = State#mochiweb_socket_server{max=Max - 1},
    {noreply, new_acceptor(State1)};
handle_cast(stop, State) ->
    {stop, normal, State}.

terminate(_Reason, #mochiweb_socket_server{listen=Listen, port=Port, ssl=Ssl}) ->
  if
    Ssl ->
      ssl:close(Listen);
    true ->
      gen_tcp:close(Listen)
  end,
  case Port < 1024 of
    true ->
      catch fdsrv:stop(),
      ok;
    false ->
      ok
  end.

code_change(_OldVsn, State, _Extra) ->
    State.

handle_info({'EXIT', Pid, normal},
            State=#mochiweb_socket_server{acceptor=Pid}) ->
    % io:format("normal acceptor down~n"),
    {noreply, new_acceptor(State)};
handle_info({'EXIT', Pid, Reason},
            State=#mochiweb_socket_server{acceptor=Pid}) ->
    error_logger:error_report({?MODULE, ?LINE,
                               {acceptor_error, Reason}}),
    timer:sleep(100),
    {noreply, new_acceptor(State)};
handle_info({'EXIT', _LoopPid, Reason},
            State=#mochiweb_socket_server{acceptor=Pid, max=Max}) ->
    case Reason of
        normal ->
            ok;
        _ ->
            error_logger:error_report({?MODULE, ?LINE,
                                       {child_error, Reason}})
    end,
    State1 = State#mochiweb_socket_server{max=Max + 1},
    State2 = case Pid of
                 null ->
                     new_acceptor(State1);
                 _ ->
                     State1
             end,
    {noreply, State2};
handle_info(Info, State) ->
    error_logger:info_report([{'INFO', Info}, {'State', State}]),
    {noreply, State}.
