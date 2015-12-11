%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 11. Dec 2015 10:57 AM
%%%-------------------------------------------------------------------
-module(minuteman_routes).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0,
  get_route/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gen_netlink/include/netlink.hrl").
-define(SERVER, ?MODULE).

-record(state, {socket :: gen_socket:socket()}).
%% TODO: define a route,
%% They look roughly like:
%[{dst,{8,8,8,8}},
%{oif,2},
%{prefsrc,{10,0,2,15}},
%{gateway,{10,0,2,2}}]
% Treat it as a proplist, not an ordict
-type(route() :: [term()]).

%%%===================================================================
%%% API
%%%===================================================================

-spec(get_route(Addr :: inet:ip4_address()) -> {ok, Route :: route()} | {error, Reason :: term()}).
get_route(Addr) when is_tuple(Addr) ->
  gen_server:call(?SERVER, {get_route, Addr}).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  %% TODO: Return error, don't just bail
  {unix, linux} = os:type(),
  {ok, Socket} = socket(netlink, raw, ?NETLINK_ROUTE, []),
  %% Our fates are linked.
  {gen_socket, RealPort, _, _, _, _} = Socket,
  erlang:link(RealPort),
  ok = gen_socket:bind(Socket, netlink:sockaddr_nl(netlink, 0, 0)),
  {ok, #state{socket = Socket}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
  State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
%% TODO: Caching.
handle_call({get_route, Addr}, _From, State = #state{socket = Socket}) ->
  Reply = handle_get_route(Addr, Socket),
  {reply, Reply, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
  State :: #state{}) -> term()).
terminate(_Reason, _State = #state{socket = Socket}) ->
  gen_socket:close(Socket),
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
  Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


%% This NFNL query function isn't like the others.
%% It uses the nl_rt_dec / nl_rt_enc
%% NOT the:    nl_ct_dec / nl_ct_dec
%% The difference is rt netlink, versus conntrack decoding
nfnl_query(Socket, Query) ->
  Request = netlink:nl_rt_enc(Query),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request),
  Answer = gen_socket:recv(Socket, 8192),
  lager:debug("Answer: ~p~n", [Answer]),
  case Answer of
    {ok, Reply} ->
      lager:debug("Reply: ~p~n", [netlink:nl_rt_dec(Reply)]),
      netlink:nl_rt_dec(Reply);
    Other ->
      Other
  end.


socket(Family, Type, Protocol, Opts) ->
  case proplists:get_value(netns, Opts) of
    undefined ->
      gen_socket:socket(Family, Type, Protocol);
    NetNs ->
      gen_socket:socketat(NetNs, Family, Type, Protocol)
  end.

-spec(handle_get_route(Addr :: inet:ip4_address(), Socket :: gen_socket:socket()) ->
  {ok, Route :: route} | {error, Reason :: term()}).
handle_get_route(Addr, Socket) when is_tuple(Addr) ->
  Seq = erlang:time_offset() + erlang:monotonic_time(),
  Req = [{dst, Addr}],
  Family = inet,
  DstLen = 0,
  SrcLen = 0,
  Tos = 0,
  Table = main,
  Protocol = unspec, %% This is the routing protocol, like: static, zebra, etc...
  Scope = universe,
  RtmType = unicast,
  Flags = [],
  Msg = {Family, DstLen, SrcLen, Tos, Table, Protocol, Scope, RtmType, Flags, Req},
  Query = [#rtnetlink{type = getroute, flags=[request], seq = Seq, pid = 0, msg = Msg}],
  handle_nfnl_response(nfnl_query(Socket, Query)).

handle_nfnl_response({error, Msg}) ->
  {error, Msg};

handle_nfnl_response([#rtnetlink{type = newroute,
  msg = {inet = _Family, _DstLen, _SrcLen, _Tos, _Table, _Protocol, _Scope, _RtmType, _Flags, Res}}]) ->
  {ok, Res};
handle_nfnl_response(Res) ->
  lager:debug("Unknown response: ~p", [Res]),
  {error, unknown}.



-ifdef(TEST).
basic_test() ->
  case os:type() of
    {unix, linux} ->
      basic_test_real();
    _ ->
      ?debugMsg("Unsupported OS")
  end.
basic_test_real() ->
  {ok, State} = init([]),
  Response = handle_get_route({8, 8, 8, 8}, State#state.socket),
  ?assertNotEqual(proplists:get_value(prefsrc, Response, undefined), undefined),
  ?assertNotEqual(proplists:get_value(gateway, Response, undefined), undefined).

-endif.








