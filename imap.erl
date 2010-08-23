-module(imap).

-include("imap.hrl").

-behaviour(gen_fsm).

-compile(export_all). % FIXME

%%--- TODO TODO TODO -------------------------------------------------------------------
%% Objetivos:
%%
%% Escanear INBOX, listar mensajes, coger un mensaje entero, parsear MIME y generar JSON
%%--------------------------------------------------------------------------------------

%%%--- TODO TODO TODO -------------------------
% 1. Arreglar el export
% 2. Filtrar mensajes de error_logger para desactivar los de este modulo, desactivar por defecto el logger?
%%%--------------------------------------------

%%%-----------------
%%% Client functions
%%%-----------------

connect(Host, Port) ->
	gen_fsm:start_link(?MODULE, {tcp, Host, Port}, []).

connect_ssl(Host, Port) ->
	gen_fsm:start_link(?MODULE, {ssl, Host, Port}, []).

login(Conn, User, Pass) ->
	gen_fsm:sync_send_event(Conn, {command, login, {User, Pass}}).

logout(Conn) ->
	gen_fsm:sync_send_event(Conn, {command, logout, {}}).

noop(Conn) ->
	gen_fsm:sync_send_event(Conn, {command, noop, {}}).

disconnect(Conn) ->
	gen_fsm:sync_send_all_state_event(Conn, {command, disconnect, {}}).

%%%-------------------
%%% Callback functions
%%%-------------------

init({SockType, Host, Port}) ->
	case imap_util:sock_connect(SockType, Host, Port, [list, {packet, line}]) of
		{ok, Sock} ->
			?LOG_INFO("IMAP connection open", []),
			{ok, server_greeting, #state_data{socket = Sock, socket_type = SockType}};
		{error, Reason} ->
			{stop, Reason}
	end.

server_greeting(Command = {command, _, _}, From, StateData) ->
	NewStateData = StateData#state_data{enqueued_commands = [{Command, From} | StateData#state_data.enqueued_commands]},
	?LOG_DEBUG("command enqueued: ~p", [Command]),
	{next_state, server_greeting, NewStateData}.

server_greeting(Response = {response, untagged, "OK", Capabilities}, StateData) ->
	?LOG_DEBUG("greeting received: ~p", [Response]),
	NewStateData = StateData#state_data{server_capabilities = Capabilities, enqueued_commands =
		lists:reverse(StateData#state_data.enqueued_commands)},
	{next_state, not_authenticated, NewStateData};
server_greeting(Response = {response, _, _, _}, StateData) ->
	?LOG_ERROR(server_greeting, "unrecognized greeting: ~p", [Response]),
	{stop, "unrecognized greeting", StateData}.

% TODO: hay que consumir los comandos encolados lo primero de todo
% TODO: hacer un comando `tag CAPABILITY' si tras hacer login no hemos recibido las CAPABILITY, en el login con el OK
not_authenticated(Command = {command, _, _}, From, StateData) ->
	handle_command(Command, From, not_authenticated, StateData).

not_authenticated(Response = {response, _, _, _}, StateData) ->
	handle_response(Response, not_authenticated, StateData).

authenticated(Command = {command, _, _}, From, StateData) ->
	handle_command(Command, From, authenticated, StateData).

authenticated(Response = {response, _, _, _}, StateData) ->
	handle_response(Response, authenticated, StateData).

logout(Command = {command, _, _}, From, StateData) ->
	handle_command(Command, From, logout, StateData).

logout(Response = {response, _, _, _}, StateData) ->
	handle_response(Response, logout, StateData).

% TODO: reconexion en caso de desconexion inesperada
handle_info({SockClosed, Sock}, logout, StateData = #state_data{socket = Sock}) when
		SockClosed == tcp_closed; SockClosed == ssl_closed ->
	?LOG_INFO("IMAP connection closed", []),
	{stop, normal, StateData};
handle_info({SockClosed, Sock}, _StateName, StateData = #state_data{socket = Sock}) when
		SockClosed == tcp_closed; SockClosed == ssl_closed ->
	?LOG_ERROR(handle_info, "IMAP connection closed unexpectedly", []),
	{stop, "connection closed unexpectedly", StateData};
handle_info({SockType, Sock, Line}, StateName, StateData = #state_data{socket_type = SockType, socket = Sock}) ->
	?LOG_DEBUG("line received: ~s", [imap_util:clean_line(Line)]),
	case imap_resp:parse_response(imap_util:clean_line(Line)) of
		{ok, Response} ->
			?MODULE:StateName(Response, StateData);
		{error, nomatch} ->
			?LOG_ERROR(handle_info, "unrecognized response: ~p", [imap_util:clean_line(Line)]),
			{stop, "unrecognized response", StateData}
	end.

handle_sync_event({command, disconnect, {}}, _From, _StateName, StateData) ->
	ok = imap_util:sock_close(StateData#state_data.socket_type, StateData#state_data.socket),
	?LOG_INFO("IMAP connection closed", []),
	{stop, normal, ok, StateData}.

terminate(normal, _StateName, _StateData) ->
	?LOG_DEBUG("gen_fsm terminated", []),
	ok.

%%%--------------------------------------
%%% Commands/Responses handling functions
%%%--------------------------------------

handle_response(Response = {response, untagged, _, _}, StateName, StateData) ->
	NewStateData = StateData#state_data{untagged_responses_received =
		[Response | StateData#state_data.untagged_responses_received]},
	{next_state, StateName, NewStateData};
handle_response(Response = {response, Tag, _, _}, StateName, StateData) ->
	case StateData#state_data.untagged_responses_received of
		[] ->
			ResponsesReceived = [Response];
		UntaggedResponsesReceived ->
			ResponsesReceived = lists:reverse([Response | UntaggedResponsesReceived])
	end,
	{ok, {Command, From}, CommandsPendingResponse} = imap_util:extract_dict_element(Tag,
		StateData#state_data.commands_pending_response),
	NewStateData = StateData#state_data{commands_pending_response = CommandsPendingResponse},
	NextStateName = imap_resp:analyze_response(StateName, ResponsesReceived, Command, From),
	{next_state, NextStateName, NewStateData}.

handle_command(Command, From, StateName, StateData) ->
	case imap_cmd:send_command(StateData#state_data.socket_type, StateData#state_data.socket, Command) of
		{ok, Tag} ->
			NewStateData = StateData#state_data{commands_pending_response =
				dict:store(Tag, {Command, From}, StateData#state_data.commands_pending_response)},
			{next_state, StateName, NewStateData};
		{error, Reason} ->
			{stop, Reason, StateData}
	end.

%%%-----------
%%% Unit tests
%%%-----------

complete_test() ->
	ok = eunit:test([imap_util, imap_re, imap_resp, imap_cmd]).

invalid_connection_test() ->
	{error, badarg} = connect(foo, bar).

connection_test() ->
	{ok, Conn} = connect("alumnos.fi.upm.es", 143),
	ok = disconnect(Conn).

connection_ssl_test() ->
	{ok, Conn} = connect_ssl("alumnos.fi.upm.es", 993),
	ok = disconnect(Conn).
