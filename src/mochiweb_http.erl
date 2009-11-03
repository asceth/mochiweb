%% @author Bob Ippolito <bob@mochimedia.com>
%% @copyright 2007 Mochi Media, Inc.

%% @doc HTTP server.

-module(mochiweb_http).
-author('bob@mochimedia.com').
-export([start/0, start/1, stop/0, stop/1]).
-export([loop/3, default_body/1]).
-export([after_response/3, reentry/2]).

-define(IDLE_TIMEOUT, 30000).

-define(MAX_HEADERS, 1000).
-define(DEFAULTS, [{name, ?MODULE},
                   {port, 8888}]).

-record(conn_info, {ssl = false,
                    opts_mod = inet,
                    conn_mod = gen_tcp}).

set_default({Prop, Value}, PropList) ->
    case proplists:is_defined(Prop, PropList) of
        true ->
            PropList;
        false ->
            [{Prop, Value} | PropList]
    end.

set_defaults(Defaults, PropList) ->
    lists:foldl(fun set_default/2, PropList, Defaults).

parse_options(Options) ->
  Ssl = proplists:is_defined(ssl, Options),
  Mods = if
           Ssl ->
             #conn_info{ssl = true, opts_mod = ssl, conn_mod = ssl};
           true ->
             #conn_info{opts_mod = inet, conn_mod = gen_tcp}
         end,
  {loop, HttpLoop} = proplists:lookup(loop, Options),
  Loop = fun (S) ->
             ?MODULE:loop(S, HttpLoop, Mods)
         end,
  Options1 = [{loop, Loop} | proplists:delete(loop, Options)],
  set_defaults(?DEFAULTS, Options1).

stop() ->
    mochiweb_socket_server:stop(?MODULE).

stop(Name) ->
    mochiweb_socket_server:stop(Name).

start() ->
    start([{ip, "127.0.0.1"},
           {loop, {?MODULE, default_body}}]).

start(Options) ->
    mochiweb_socket_server:start(parse_options(Options)).

frm(Body) ->
    ["<html><head></head><body>"
     "<form method=\"POST\">"
     "<input type=\"hidden\" value=\"message\" name=\"hidden\"/>"
     "<input type=\"submit\" value=\"regular POST\">"
     "</form>"
     "<br />"
     "<form method=\"POST\" enctype=\"multipart/form-data\""
     " action=\"/multipart\">"
     "<input type=\"hidden\" value=\"multipart message\" name=\"hidden\"/>"
     "<input type=\"file\" name=\"file\"/>"
     "<input type=\"submit\" value=\"multipart POST\" />"
     "</form>"
     "<pre>", Body, "</pre>"
     "</body></html>"].

default_body(Req, M, "/chunked") when M =:= 'GET'; M =:= 'HEAD' ->
    Res = Req:ok({"text/plain", [], chunked}),
    Res:write_chunk("First chunk\r\n"),
    timer:sleep(5000),
    Res:write_chunk("Last chunk\r\n"),
    Res:write_chunk("");
default_body(Req, M, _Path) when M =:= 'GET'; M =:= 'HEAD' ->
    Body = io_lib:format("~p~n", [[{parse_qs, Req:parse_qs()},
                                   {parse_cookie, Req:parse_cookie()},
                                   Req:dump()]]),
    Req:ok({"text/html",
            [mochiweb_cookies:cookie("mochiweb_http", "test_cookie")],
            frm(Body)});
default_body(Req, 'POST', "/multipart") ->
    Body = io_lib:format("~p~n", [[{parse_qs, Req:parse_qs()},
                                   {parse_cookie, Req:parse_cookie()},
                                   {body, Req:recv_body()},
                                   Req:dump()]]),
    Req:ok({"text/html", [], frm(Body)});
default_body(Req, 'POST', _Path) ->
    Body = io_lib:format("~p~n", [[{parse_qs, Req:parse_qs()},
                                   {parse_cookie, Req:parse_cookie()},
                                   {parse_post, Req:parse_post()},
                                   Req:dump()]]),
    Req:ok({"text/html", [], frm(Body)});
default_body(Req, _Method, _Path) ->
    Req:respond({501, [], []}).

default_body(Req) ->
    default_body(Req, Req:get(method), Req:get(path)).

loop(Socket, Body, #conn_info{opts_mod = OptsMod} = Mods) ->
    OptsMod:setopts(Socket, [{packet, http}]),
    request(Socket, Body, Mods).

request(Socket, Body, #conn_info{conn_mod = ConnMod} = Mods) ->
  case ConnMod:recv(Socket, 0, ?IDLE_TIMEOUT) of
    {ok, {http_request, Method, Path, Version}} ->
      headers(Socket, {Method, Path, Version}, [], Body, 0, Mods);
    {error, {http_error, "\r\n"}} ->
      request(Socket, Body, Mods);
    {error, {http_error, "\n"}} ->
      request(Socket, Body, Mods);
    _Other ->
      ConnMod:close(Socket),
      exit(normal)
  end.

reentry(Body, Mods) ->
    fun (Req) ->
            ?MODULE:after_response(Body, Req, Mods)
    end.

headers(Socket, Request, Headers, _Body, ?MAX_HEADERS, #conn_info{ssl = Ssl, opts_mod = OptsMod, conn_mod = ConnMod}) ->
    %% Too many headers sent, bad request.
    OptsMod:setopts(Socket, [{packet, raw}]),
    Req = mochiweb:new_request({Socket, Request,
                                lists:reverse(Headers),
                                Ssl, OptsMod, ConnMod}),
    Req:respond({400, [], []}),
    ConnMod:close(Socket),
    exit(normal);
headers(Socket, Request, Headers, Body, HeaderCount, #conn_info{ssl = Ssl, opts_mod = OptsMod, conn_mod = ConnMod} = Mods) ->
  case ConnMod:recv(Socket, 0, ?IDLE_TIMEOUT) of
    {ok, http_eoh} ->
      OptsMod:setopts(Socket, [{packet, raw}]),
      Req = mochiweb:new_request({Socket, Request,
                                  lists:reverse(Headers),
                                  Ssl, OptsMod, ConnMod}),
      Body(Req),
      ?MODULE:after_response(Body, Req, Mods);
    {ok, {http_header, _, Name, _, Value}} ->
      headers(Socket, Request, [{Name, Value} | Headers], Body,
              1 + HeaderCount, Mods);
    _Other ->
      ConnMod:close(Socket),
      exit(normal)
  end.

after_response(Body, Req, #conn_info{conn_mod = ConnMod} = Mods) ->
    Socket = Req:get(socket),
    case Req:should_close() of
        true ->
            ConnMod:close(Socket),
            exit(normal);
        false ->
            Req:cleanup(),
            ?MODULE:loop(Socket, Body, Mods)
    end.
