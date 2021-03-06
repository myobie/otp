%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2018-2020. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

-module(prim_socket).

-compile(no_native).

-export([on_load/0, on_load/1]).

-export(
   [
    info/0, info/1,
    debug/1, socket_debug/1, use_registry/1,
    supports/0, supports/1, supports/2,
    is_supported/1, is_supported/2,
    open/2, open/4,
    bind/2, bind/3,
    connect/1, connect/3,
    listen/2,
    accept/2,
    send/4, sendto/5, sendmsg/4,
    recv/4, recvfrom/4, recvmsg/5,
    close/1, finalize_close/1,
    shutdown/2,
    setopt/3, setopt_native/3,
    getopt/2, getopt_native/3,
    sockname/1, peername/1,
    cancel/3
   ]).

-export([enc_sockaddr/1, p_get/1]).


%% Also in socket
-define(REGISTRY, socket_registry).


%% ===========================================================================
%%
%% Defaults
%%

-define(ESOCK_SOCKADDR_IN4_DEFAULTS,
        (#{port => 0, addr => any})).
-define(ESOCK_SOCKADDR_IN6_DEFAULTS,
        (#{port => 0, addr => any,
           flowinfo => 0, scope_id => 0})).

%% ===========================================================================
%%
%% Constants common to prim_socket_nif.c - has to be "identical"
%%

%% ----------------------------------
%% *** OTP (socket) options

-define(ESOCK_OPT_OTP_DEBUG,           1001).
-define(ESOCK_OPT_OTP_IOW,             1002).
-define(ESOCK_OPT_OTP_CTRL_PROC,       1003).
-define(ESOCK_OPT_OTP_RCVBUF,          1004).
%%-define(ESOCK_OPT_OTP_SNDBUF,          1005).
-define(ESOCK_OPT_OTP_RCVCTRLBUF,      1006).
-define(ESOCK_OPT_OTP_SNDCTRLBUF,      1007).
-define(ESOCK_OPT_OTP_FD,              1008).
-define(ESOCK_OPT_OTP_META,            1009).
-define(ESOCK_OPT_OTP_USE_REGISTRY,    1010).
%%
-define(ESOCK_OPT_OTP_DOMAIN,          1999). % INTERNAL
%%-define(ESOCK_OPT_OTP_TYPE,            1998). % INTERNAL
%%-define(ESOCK_OPT_OTP_PROTOCOL,        1997). % INTERNAL
%%-define(ESOCK_OPT_OTP_DTP,             1996). % INTERNAL



%% ===========================================================================
%% API for 'erl_init'
%%

on_load() ->
    on_load(#{}).

on_load(Extra) when is_map(Extra) ->
    %% This is spawned as a system process to prevent init:restart/0 from
    %% killing it.
    Pid = erts_internal:spawn_system_process(?REGISTRY, start, []),
    %%
    DebugFilename =
        case os:get_env_var("ESOCK_DEBUG_FILENAME") of
            "*" ->
                "/tmp/esock-dbg-??????";
            F ->
                F
        end,
    UseRegistry =
        case os:get_env_var("ESOCK_USE_SOCKET_REGISTRY") of
            "true" ->
                true;
            "false" ->
                false;
            _ ->
                undefined
        end,
    %%
    Extra_1 =
        case UseRegistry of
            undefined ->
                Extra#{registry => Pid};
            _ ->
                Extra
                    #{registry => Pid,
                      use_registry => UseRegistry}
        end,
    Extra_2 =
          case DebugFilename of
              false ->
                  Extra_1;
              _ ->
                  Extra_1
                      #{debug => true,
                        socket_debug => true,
                        debug_filename => enc_path(DebugFilename)}
          end,
    ok = erlang:load_nif(atom_to_list(?MODULE), Extra_2),
    %%
    PT =
        put_supports_table(
          protocols, fun (Protocols) -> protocols_table(Protocols) end),
    _ = put_supports_table(
          options, fun (Options) -> options_table(Options, PT) end),
    _ = put_supports_table(msg_flags, fun (Flags) -> Flags end),
    ok.

put_supports_table(Tag, MkTable) ->
    Table =
        try nif_supports(Tag) of
            Data ->
                maps:from_list(MkTable(Data))
        catch
            error : notsup ->
                #{}
        end,
    p_put(Tag, Table),
    Table.

%% ->
%% [{Num, [Name, ...]}
%%  {Name, Num} for all names]
protocols_table([{Names, Num} | Protocols]) ->
    [{Num, Names} | protocols_table(Protocols, Names, Num)];
protocols_table([]) ->
    [].
%%
protocols_table(Protocols, [Name | Names], Num) ->
    [{Name, Num} | protocols_table(Protocols, Names, Num)];
protocols_table(Protocols, [], _Num) ->
    protocols_table(Protocols).

%% ->
%% [{{socket,Opt}, {socket,OptNum}} |
%%  {{Level, Opt}, {LevelNum, OptNum}} for all Levels (protocol aliases)]
options_table([], _PT) ->
    [];
options_table([{socket, LevelOpts} | Options], PT) ->
    options_table(Options, PT, socket, LevelOpts, [socket]);
options_table([{LevelNum, LevelOpts} | Options], PT) ->
    Levels = maps:get(LevelNum, PT),
    options_table(Options, PT, LevelNum, LevelOpts, Levels).
%%
options_table(Options, PT, _Level, [], _Levels) ->
    options_table(Options, PT);
options_table(Options, PT, Level, [LevelOpt | LevelOpts], Levels) ->
    LevelOptNum =
        case LevelOpt of
            {Opt, OptNum} ->
                {Level,OptNum};
            Opt when is_atom(Opt) ->
                undefined
        end,
    options_table(
      Options, PT, Level, LevelOpts, Levels,
      Opt, LevelOptNum, Levels).
%%
options_table(
  Options, PT, Level, LevelOpts, Levels,
  _Opt, _LevelOptNum, []) ->
    options_table(Options, PT, Level, LevelOpts, Levels);
options_table(
  Options, PT, Level, LevelOpts, Levels,
  Opt, LevelOptNum, [L | Ls]) ->
    [{{L,Opt}, LevelOptNum} |
     options_table(
       Options, PT, Level, LevelOpts, Levels,
       Opt, LevelOptNum, Ls)].

%% ===========================================================================
%% API for 'socket'
%%

info() ->
    nif_info().

info(SockRef) ->
    #{protocol := NumProtocol} = Info = nif_info(SockRef),
    case p_get(protocols) of
        #{NumProtocol := [Protocol | _]} ->
            Info#{protocol := Protocol};
        #{} ->
            Info
    end.

%% ----------------------------------

debug(D) ->
    nif_command(#{command => ?FUNCTION_NAME, data => D}).


socket_debug(D) ->
    nif_command(#{command => ?FUNCTION_NAME, data => D}).


use_registry(D) ->
    nif_command(#{command => ?FUNCTION_NAME, data => D}).

%% ----------------------------------

supports() ->
    nif_supports().
     
supports(protocols) ->
    maps:fold(
      fun (Name, _Num, Acc) when is_atom(Name) ->
              [{Name, true} | Acc];
          (Num, _Names, Acc) when is_integer(Num) ->
              Acc
      end, [], p_get(protocols));
supports(options) ->
    maps:fold(
      fun ({_Level,_Opt} = Option, Value, Acc) ->
              [{Option, is_supported_option(Option, Value)} | Acc]
      end, [], p_get(options));
supports(msg_flags) ->
    maps:fold(
      fun (Name, Num, Acc) ->
              [{Name, Num =/= 0} | Acc]
      end, [], p_get(msg_flags));
supports(Key) ->
    nif_supports(Key).

supports(options, Level) when is_atom(Level) ->
    maps:fold(
      fun ({L, Opt} = Option, Value, Acc) ->
              if
                  L =:= Level ->
                      [{Opt, is_supported_option(Option, Value)} | Acc];
                  true ->
                      Acc
              end
      end, [], p_get(options));
supports(options, _Level) ->
    [];
supports(_Key1, _Key2) ->
    [].

is_supported_option({socket, peek_off}, _Value) ->
    %% Due to the behaviour of peek when peek_off is used,
    %% this option is reported as not supported.
    %% Can cause an infinite loop when calling recv with
    %% the peek flag (the second of two calls).
    %% So, until we have added extra code to know when
    %% peek-off is used, we do not claim to support this!
    %%
    false;
is_supported_option(_Option, {_NumLevel,_NumOpt}) ->
    true;
is_supported_option(_Option, undefined) ->
    false.

is_supported(Key1) ->
    get_is_supported(Key1, nif_supports()).

is_supported(protocols = Tab, Name) when is_atom(Name) ->
    p_get_is_supported(Tab, Name, fun (_) -> true end);
is_supported(protocols, _Name) ->
    false;
is_supported(options = Tab, {_Level,_Opt} = Option) ->
    p_get_is_supported(
      Tab, Option,
      fun (Value) ->
              is_supported_option(Option, Value)
      end);
is_supported(options, _Option) ->
    false;
is_supported(msg_flags = Tab, Flag) ->
    p_get_is_supported(Tab, Flag, fun (Value) -> Value =/= 0 end);
is_supported(Key1, Key2) ->
    get_is_supported(Key2, nif_supports(Key1)).


p_get_is_supported(Tab, Key, Fun) ->
    case p_get(Tab) of
        #{Key := Val} ->
            Fun(Val);
        #{} ->
            false
    end.

get_is_supported(Key, Supported) ->
    case lists:keyfind(Key, 1, Supported) of
        false ->
            false;
        {_, Value} when is_boolean(Value) ->
            Value
    end.

%% ----------------------------------

open(FD, Opts) when is_map(Opts) ->
    try
        case Opts of
            #{protocol := Protocol} ->
                NumProtocol = enc_protocol(Protocol),
                Opts#{protocol := NumProtocol};
            #{} ->
                Opts
        end
    of
        EOpts ->
            case nif_open(FD, EOpts) of
                {invalid, Reason} ->
                  if
                      Reason =:= domain;
                      Reason =:= type ->
                          {error, {invalid, {options, Opts, Reason}}}
                  end;
                Result -> Result
            end
    catch
        throw : Reason ->
            {error, Reason}
    end.

open(Domain, Type, Protocol, Opts) when is_map(Opts) ->
    try
        {enc_protocol(Protocol),
         case Opts of
            #{netns := Path} when is_list(Path) ->
                Opts#{netns := enc_path(Path)};
            _ ->
                Opts
         end}
    of
        {NumProtocol, EOpts} ->
            case nif_open(Domain, Type, NumProtocol, EOpts) of
                {invalid, Reason} ->
                    {error,
                     {invalid,
                      {Reason,
                       case Reason of
                           domain -> Domain;
                           type -> Type
                       end}}};
                Result -> Result
            end
    catch
        throw : Reason ->
            {error, Reason}
    end.

%% ----------------------------------

bind(SockRef, Addr) ->
    try
        enc_sockaddr(Addr)
    of
        EAddr ->
            case nif_bind(SockRef, EAddr) of
                {invalid, Reason} ->
                    case Reason of
                        sockaddr ->
                            {error, {invalid, {Reason, Addr}}}
                    end;
                Result -> Result
            end
    catch
        throw : Reason ->
            {error, Reason}
    end.

bind(SockRef, Addrs, Action) when is_list(Addrs) ->
    try
        [enc_sockaddr(Addr) || Addr <- Addrs]
    of
        EAddrs ->
            %% Not implemented yet
            case nif_bind(SockRef, EAddrs, Action) of
                {invalid, Reason} ->
                    case Reason of
                        {sockaddr, N} ->
                            {error,
                             {invalid, {sockaddr, lists:nth(N, Addrs)}}}
                    end;
                Result -> Result
            end
    catch
        throw : Reason ->
            {error, Reason}
    end.

%% ----------------------------------

connect(SockRef, ConnectRef, SockAddr) ->
    try
        enc_sockaddr(SockAddr)
    of
        ESockAddr ->
            case nif_connect(SockRef, ConnectRef, ESockAddr) of
                {invalid, Reason} ->
                    case Reason of
                        sockaddr ->
                            {error, {invalid, {Reason, SockAddr}}}
                    end;
                Result -> Result
            end
    catch
        throw : Reason ->
            {error, Reason}
    end.

connect(SockRef) ->
    nif_connect(SockRef).

%% ----------------------------------

listen(SockRef, Backlog) ->
    nif_listen(SockRef, Backlog).

%% ----------------------------------

accept(ListenSockRef, AccRef) ->
    nif_accept(ListenSockRef, AccRef).

%% ----------------------------------

send(SockRef, SendRef, Data, Flags) ->
    try enc_msg_flags(Flags) of
        EFlags ->
            nif_send(SockRef, SendRef, Data, EFlags)
    catch throw : Reason ->
            {error, Reason}
    end.

sendto(SockRef, SendRef, Data, To, Flags) ->
    try {enc_sockaddr(To), enc_msg_flags(Flags)} of
        {ETo, EFlags} ->
            case nif_sendto(SockRef, SendRef, Data, ETo, EFlags) of
                {invalid, Reason} ->
                    case Reason of
                        sockaddr ->
                            {error, {invalid, {sockaddr, To}}}
                    end;
                Result -> Result
            end
    catch throw : Reason ->
            {error, Reason}
    end.

sendmsg(SockRef, SendRef, Msg, Flags) ->
    try {enc_msg(Msg), enc_msg_flags(Flags)} of
        {EMsg, EFlags} ->
            case nif_sendmsg(SockRef, SendRef, EMsg, EFlags) of
                {invalid, Reason} ->
                    if
                        Reason =:= addr;
                        Reason =:= iov;
                        Reason =:= ctrl ->
                            {error, {invalid, {msg, Msg, Reason}}}
                    end;
                Result -> Result
            end
    catch throw : Reason ->
            {error, Reason}
    end.

%% ----------------------------------

recv(SockRef, RecvRef, Length, Flags) ->
    try enc_msg_flags(Flags) of
        EFlags ->
	    nif_recv(SockRef, RecvRef, Length, EFlags)
    catch throw : Reason ->
            {error, Reason}
    end.

recvfrom(SockRef, RecvRef, Length, Flags) ->
    try enc_msg_flags(Flags) of
        EFlags ->
            nif_recvfrom(SockRef, RecvRef, Length, EFlags)
    catch throw : Reason ->
            {error, Reason}
    end.

recvmsg(SockRef, RecvRef, BufSz, CtrlSz, Flags) ->
    try enc_msg_flags(Flags) of
        EFlags ->
            case nif_recvmsg(SockRef, RecvRef, BufSz, CtrlSz, EFlags) of
		{ok, #{ctrl := []}} = Result ->
		    Result;
		{ok, #{ctrl := Cmsgs} = Msg} ->
		    {ok, Msg#{ctrl := dec_cmsgs(Cmsgs, p_get(protocols))}};
		Result ->
		    Result
	    end
    catch throw : Reason ->
            {error, Reason}
    end.

%% ----------------------------------

close(SockRef) ->
    nif_close(SockRef).

finalize_close(SockRef) ->    
    nif_finalize_close(SockRef).

%% ----------------------------------

shutdown(SockRef, How) ->
    nif_shutdown(SockRef, How).

%% ----------------------------------

setopt(SockRef, Option, Value) ->
    NativeValue = 0,
    setopt_common(SockRef, Option, Value, NativeValue).

setopt_native(SockRef, Option, Value) ->
    NativeValue = 1,
    setopt_common(SockRef, Option, Value, NativeValue).

setopt_common(SockRef, Option, Value, NativeValue) ->
    case enc_sockopt(Option, NativeValue) of
        undefined ->
            {error, {invalid, {socket_option, Option}}};
        invalid ->
            {error, {invalid, {socket_option, Option}}};
        {NumLevel,NumOpt} ->
            case nif_setopt(SockRef, NumLevel, NumOpt, Value, NativeValue) of
                {invalid, Reason} ->
                    case Reason of
                        socket_option ->
                            {error,
                             {invalid, {socket_option, Option}}};
                        value ->
                            {error,
                             {invalid, {socket_option, Option, Value}}}
                    end;
                Result ->
                    Result
            end
    end.


getopt(SockRef, Option) ->
    NativeValue = 0,
    case enc_sockopt(Option, NativeValue) of
        undefined ->
            {error, {invalid, {socket_option, Option}}};
        invalid ->
            {error, {invalid, {socket_option, Option}}};
        {NumLevel,NumOpt} ->
            case nif_getopt(SockRef, NumLevel, NumOpt) of
                {invalid, Reason} ->
                    case Reason of
                        socket_option ->
                            {error, {invalid, {socket_option, Option}}}
                    end;
                Result ->
                    getopt_result(Result, Option)
            end
    end.

getopt_result({ok, Val} = Result, Option) ->
    case Option of
        {socket,protocol} ->
            if
                is_atom(Val) ->
                    Result;
                is_integer(Val) ->
                    case p_get(protocols) of
                        #{Val := [Protocol | _]} ->
                            {ok, Protocol};
                        #{} ->
                            Result
                    end
            end;
        _ ->
            Result
    end;
getopt_result(Error, _Option) ->
    Error.

getopt_native(SockRef, Option, ValueSpec) ->
    NativeValue = 1,
    case enc_sockopt(Option, NativeValue) of
        undefined ->
            {error, {invalid, {socket_option, Option}}};
        invalid ->
            {error, {invalid, {socket_option, Option}}};
        {NumLevel,NumOpt} ->
            case nif_getopt(SockRef, NumLevel, NumOpt, ValueSpec) of
                {invalid, Reason} ->
                    case Reason of
                        value ->
                            {error, {invalid, {value_spec, ValueSpec}}}
                    end;
                Result -> Result
            end
    end.

%% ----------------------------------

sockname(Ref) ->
    nif_sockname(Ref).

peername(Ref) ->
    nif_peername(Ref).

%% ----------------------------------

cancel(SRef, Op, Ref) ->
    nif_cancel(SRef, Op, Ref).

%% ===========================================================================
%% Encode / decode
%%

%% These clauses should be deprecated
enc_protocol({raw, ProtoNum}) when is_integer(ProtoNum) ->
    ProtoNum;
enc_protocol(default) ->
    0;
%%
enc_protocol(Proto) when is_atom(Proto) ->
    case p_get(protocols) of
        #{Proto := Num} ->
            Num;
        #{} ->
            throw({invalid, {protocol, Proto}})
    end;
enc_protocol(Proto) when is_integer(Proto) ->
    Proto;
enc_protocol(Proto) ->
    %% Neater than a function clause
    erlang:error({invalid, {protocol, Proto}}).


enc_sockaddr(#{family := inet} = SockAddr) ->
    maps:merge(?ESOCK_SOCKADDR_IN4_DEFAULTS, SockAddr);
enc_sockaddr(#{family := inet6} = SockAddr) ->
    maps:merge(?ESOCK_SOCKADDR_IN6_DEFAULTS, SockAddr);
enc_sockaddr(#{family := local, path := Path} = SockAddr) ->
  if
      is_list(Path), 0 =< length(Path), length(Path) =< 255 ->
          BinPath = enc_path(Path),
          enc_sockaddr(SockAddr#{path => BinPath});
      is_binary(Path), 0 =< byte_size(Path), byte_size(Path) =< 255 ->
          SockAddr;
      true ->
          %% Neater than an if clause
          erlang:error({invalid, {sockaddr, SockAddr, path}})
  end;
enc_sockaddr(#{family := local} = SockAddr) ->
    %% Neater than a function clause
    erlang:error({invalid, {sockaddr, SockAddr, path}});
enc_sockaddr(#{family := _} = SockAddr) ->
    SockAddr;
enc_sockaddr(SockAddr) ->
    %% Neater than a function clause
    erlang:error({invalid, {sockaddr, SockAddr, map_or_family}}).


%% File names has to be encoded according to
%% the native file encoding
%%
enc_path(Path) ->
    %% These are all BIFs - will not cause code loading
    case unicode:characters_to_binary(Path, file:native_name_encoding()) of
        {error, _Bin, _Rest} ->
            throw({invalid, {path, Path}});
        {incomplete, _Bin1, _Bin2} ->
            throw({invalid, {path, Path}});
        BinPath when is_binary(BinPath) ->
            BinPath
    end.


enc_msg_flags([]) ->
    0;
enc_msg_flags(Flags) ->
    enc_msg_flags(Flags, p_get(msg_flags), 0).

enc_msg_flags([], _Table, Val) ->
    Val;
enc_msg_flags([Flag | Flags], Table, Val) when is_atom(Flag) ->
    case Table of
        #{Flag := V} ->
            enc_msg_flags(Flags, Table, Val bor V);
        #{} ->
            throw({invalid, {msg_flag, Flag}})
    end;
enc_msg_flags([Flag | Flags], Table, Val)
  when is_integer(Flag), 0 =< Flag ->
    enc_msg_flags(Flags, Table, Val bor Flag);
enc_msg_flags(Flags, _Table, _Val) ->
    %% Neater than a function clause
    error({invalid, {msg_flags, Flags}}).


enc_msg(#{ctrl := []} = M) ->
    enc_msg(maps:remove(ctrl, M));
enc_msg(#{iov := IOV} = M)
  when is_list(IOV), IOV =/= [] ->
    maps:map(
      fun (iov, Iov) ->
              erlang:iolist_to_iovec(Iov);
          (addr, Addr) ->
              enc_sockaddr(Addr);
          (ctrl, Cmsgs) ->
              enc_cmsgs(Cmsgs, p_get(protocols));
          (_, V) ->
              V
      end,
      M);
enc_msg(M) ->
    error({invalid, {msg, M}}).


enc_cmsgs(Cmsgs, Protocols) ->
    [if
	 is_atom(Level) ->
	     case Protocols of
		 #{} when Level =:= socket ->
		     Cmsg;
		 #{Level := L} ->
		     Cmsg#{level := L};
		 #{} ->
		     throw({invalid, {protocol, Level}})
	     end;
	 true ->
	     Cmsg
     end || #{level := Level} = Cmsg <- Cmsgs].


dec_cmsgs(Cmsgs, Protocols) ->
    [case Protocols of
	 #{Level := [L | _]} when is_integer(Level) ->
	     Cmsg#{level := L};
	 #{} ->
	     Cmsg
     end || #{level := Level} = Cmsg <- Cmsgs].


%% Common to setopt and getopt
%%
enc_sockopt({otp = Level, Opt}, 0 = _NativeValue) ->
    case
        case Opt of
            debug               -> ?ESOCK_OPT_OTP_DEBUG;
            iow                 -> ?ESOCK_OPT_OTP_IOW;
            controlling_process -> ?ESOCK_OPT_OTP_CTRL_PROC;
            rcvbuf              -> ?ESOCK_OPT_OTP_RCVBUF;
            rcvctrlbuf          -> ?ESOCK_OPT_OTP_RCVCTRLBUF;
            sndctrlbuf          -> ?ESOCK_OPT_OTP_SNDCTRLBUF;
            fd                  -> ?ESOCK_OPT_OTP_FD;
            meta                -> ?ESOCK_OPT_OTP_META;
            use_registry        -> ?ESOCK_OPT_OTP_USE_REGISTRY;
            domain              -> ?ESOCK_OPT_OTP_DOMAIN;
            _                   -> invalid
        end
    of
        invalid       -> invalid;
        NumOpt          -> {Level, NumOpt}
    end;
enc_sockopt({NumLevel,NumOpt} = NumOption, NativeValue)
  when is_integer(NumLevel), is_integer(NumOpt), NativeValue =/= 0 ->
    NumOption;
enc_sockopt({Level,NumOpt}, NativeValue)
  when is_atom(Level), is_integer(NumOpt), NativeValue =/= 0 ->
    if
        Level =:= socket ->
            {socket,NumOpt};
        true ->
            case p_get(protocols) of
                #{Level := NumLevel} ->
                    {NumLevel,NumOpt};
                #{} ->
                    invalid
            end
    end;
enc_sockopt({Level,Opt} = Option, _NativeValue)
  when is_atom(Level), is_atom(Opt) ->
    case p_get(options) of
        #{Option := NumOpt} ->
            NumOpt;
        #{} ->
            invalid
    end;
enc_sockopt(Option, _NativeValue) ->
    %% Neater than a function clause
    erlang:error({invalid, {socket_option, Option}}).

%% ===========================================================================
%% Persistent term functions
%%

p_put(Name, Value) ->
    persistent_term:put({?MODULE, Name}, Value).

%% Also called from prim_net
p_get(Name) ->
    persistent_term:get({?MODULE, Name}).

%% ===========================================================================
%% NIF functions
%%

nif_info() -> erlang:nif_error(undef).
nif_info(_SRef) -> erlang:nif_error(undef).

nif_command(_Command) -> erlang:nif_error(undef).

nif_supports() -> erlang:nif_error(undef).
nif_supports(_Key) -> erlang:nif_error(undef).

nif_open(_FD, _Opts) -> erlang:nif_error(undef).
nif_open(_Domain, _Type, _Protocol, _Opts) -> erlang:nif_error(undef).

nif_bind(_SRef, _SockAddr) -> erlang:nif_error(undef).
nif_bind(_SRef, _SockAddrs, _Action) -> erlang:nif_error(undef).

nif_connect(_SRef) -> erlang:nif_error(undef).
nif_connect(_SRef, _ConnectRef, _SockAddr) -> erlang:nif_error(undef).

nif_listen(_SRef, _Backlog) -> erlang:nif_error(undef).

nif_accept(_SRef, _Ref) -> erlang:nif_error(undef).

nif_send(_SockRef, _SendRef, _Data, _Flags) -> erlang:nif_error(undef).
nif_sendto(_SRef, _SendRef, _Data, _Dest, _Flags) -> erlang:nif_error(undef).
nif_sendmsg(_SRef, _SendRef, _Msg, _Flags) -> erlang:nif_error(undef).

nif_recv(_SRef, _RecvRef, _Length, _Flags) -> erlang:nif_error(undef).
nif_recvfrom(_SRef, _RecvRef, _Length, _Flags) -> erlang:nif_error(undef).
nif_recvmsg(_SRef, _RecvRef, _BufSz, _CtrlSz, _Flags) -> erlang:nif_error(undef).

nif_close(_SRef) -> erlang:nif_error(undef).
nif_finalize_close(_SRef) -> erlang:nif_error(undef).
nif_shutdown(_SRef, _How) -> erlang:nif_error(undef).

nif_setopt(_Ref, _Lev, _Opt, _Val, _NativeVal) -> erlang:nif_error(undef).
nif_getopt(_Ref, _Lev, _Opt) -> erlang:nif_error(undef).
nif_getopt(_Ref, _Lev, _Opt, _ValSpec) -> erlang:nif_error(undef).

nif_sockname(_Ref) -> erlang:nif_error(undef).
nif_peername(_Ref) -> erlang:nif_error(undef).

nif_cancel(_SRef, _Op, _Ref) -> erlang:nif_error(undef).

%% ===========================================================================
