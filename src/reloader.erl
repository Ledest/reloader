%% @copyright 2007 Mochi Media, Inc.
%% @author Matthew Dempsky <matthew@mochimedia.com>
%%
%% @doc Erlang module for automatically reloading modified modules
%% during development.

-module(reloader).
-author("Matthew Dempsky <matthew@mochimedia.com>").

-include_lib("kernel/include/file.hrl").

-behaviour(gen_server).
-export([start/0, start_link/0]).
-export([stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([all_changed/0]).
-export([is_changed/1]).
-export([reload_modules/1]).
-export([reload_app/0, reload_app/1]).
-export([update_app/0, update_app/1]).
-export([module_status/1]).
-export([update_path/0, update_path/1]).
-record(state, {last, tref}).

%% External API

%% @spec start() -> ServerRet
%% @doc Start the reloader.
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @spec start_link() -> ServerRet
%% @doc Start the reloader.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @spec stop() -> ok
%% @doc Stop the reloader.
stop() ->
    gen_server:call(?MODULE, stop).

%% gen_server callbacks

%% @spec init([]) -> {ok, State}
%% @doc gen_server init, opens the server in an initial state.
init([]) ->
    {ok, TRef} = timer:send_interval(timer:seconds(1), doit),
    {ok, #state{last = stamp(), tref = TRef}}.

%% @spec handle_call(Args, From, State) -> tuple()
%% @doc gen_server callback.
handle_call(stop, _From, State) ->
    {stop, shutdown, stopped, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badrequest}, State}.

%% @spec handle_cast(Cast, State) -> tuple()
%% @doc gen_server callback.
handle_cast(_Req, State) ->
    {noreply, State}.

%% @spec handle_info(Info, State) -> tuple()
%% @doc gen_server callback.
handle_info(doit, State) ->
    Now = stamp(),
    _ = doit(State#state.last, Now),
    {noreply, State#state{last = Now}};
handle_info(_Info, State) ->
    {noreply, State}.

%% @spec terminate(Reason, State) -> ok
%% @doc gen_server termination callback.
terminate(_Reason, State) ->
    {ok, cancel} = timer:cancel(State#state.tref),
    ok.


%% @spec code_change(_OldVsn, State, _Extra) -> State
%% @doc gen_server code_change callback (trivial).
code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%% @spec reload_modules([atom()]) -> [{module, atom()} | {error, term()}]
%% @doc code:purge/1 and code:load_file/1 the given list of modules in order,
%%      return the results of code:load_file/1.
reload_modules(Modules) ->
    [begin code:purge(M), code:load_file(M) end || M <- Modules].

reload_app() -> reload_app(which_applications()).

reload_app(Apps) when is_list(Apps) -> [{App, reload_app(App)} || App <- Apps];
reload_app(App) when is_atom(App) ->
    case application:get_key(App, modules) of
        {ok, Ms} -> case code:modified_modules() of
                        [_|_] = MM ->
                            reload_modules(sets:to_list(sets:intersection(sets:from_list(Ms), sets:from_list(MM))));
                        R -> R
                    end;
        R -> R
    end.

update_app() -> update_app(which_applications()).

update_app(App) when is_atom(App) -> {reload_app(App), update_app_key(App, vsn)};
update_app(Apps) when is_list(Apps) -> lists:zip(reload_app(Apps), [update_app_key(App, vsn) || App <- Apps]).

module_status(M) when is_atom(M) -> code:module_status(M).

update_path() ->
    update_path(case os:getenv("ROOTDIR") of
                    [_|_] = R -> [filename:join(R, "lib")];
                    _ -> []
                end ++
                case os:getenv("ERL_LIBS") of
                    [_|_] = L -> string:tokens(L, ":");
                    _ -> []
                end).

update_path([_|_] = Ds) ->
    DLs = lists:map(fun filename:split/1, Ds),
    lists:foreach(fun(P) ->
                      filelib:is_dir(P) orelse
                          begin
                          PL = filename:split(P),
                          lists:last(PL) =:= "ebin" andalso
                              begin
                              L = length(PL) - 2,
                              lists:any(fun(DL) -> length(DL) =:= L andalso lists:prefix(DL, PL) end,
                                        DLs) andalso code:del_path(P)
                              end
                          end
                  end, code:get_path()),
    code:add_paths(lists:flatmap(fun(D) -> filelib:wildcard(filename:join([D, "*", "ebin"])) end, Ds));
update_path([]) -> ok.

%% @spec all_changed() -> [atom()]
%% @doc Return a list of beam modules that have changed.
all_changed() -> code:modified_modules().

%% @spec is_changed(atom()) -> boolean()
%% @doc true if the loaded module is a beam with a vsn attribute
%%      and does not match the on-disk beam file, returns false otherwise.
is_changed(M) -> code:module_status(M) =:= modified.

%% Internal API

doit(From, To) ->
    [case file:read_file_info(Filename) of
         {ok, #file_info{mtime = Mtime}} when Mtime >= From, Mtime < To ->
             reload(Module);
         {ok, _} ->
             unmodified;
         {error, enoent} ->
             %% The Erlang compiler deletes existing .beam files if
             %% recompiling fails.  Maybe it's worth spitting out a
             %% warning here, but I'd want to limit it to just once.
             gone;
         {error, Reason} ->
             io:format("Error reading ~s's file info: ~p~n",
                       [Filename, Reason]),
             error
     end || {Module, Filename} <- code:all_loaded(), is_list(Filename)].

reload(Module) ->
    io:format("Reloading ~p ...", [Module]),
    code:purge(Module),
    case code:load_file(Module) of
        {module, Module} ->
            io:format(" ok.~n"),
            case erlang:function_exported(Module, test, 0) of
                true ->
                    io:format(" - Calling ~p:test() ...", [Module]),
                    case catch Module:test() of
                        ok ->
                            io:format(" ok.~n"),
                            reload;
                        Reason ->
                            io:format(" fail: ~p.~n", [Reason]),
                            reload_but_test_failed
                    end;
                false ->
                    reload
            end;
        {error, Reason} ->
            io:format(" fail: ~p.~n", [Reason]),
            error
    end.


stamp() ->
    erlang:localtime().

update_app_key(App, K) ->
    case file:consult(code:where_is_file(atom_to_list(App) ++ ".app")) of
        {ok, [{application, App, New}] = A} ->
            case application:get_all_key(App) of
                {ok, Old} ->
                    case {lists:keyfind(K, 1, Old), lists:keyfind(K, 1, New)} of
                        {O, O} -> false;
                        {O, N} ->
                            application_controller:change_application_data(A, [{rmt, application:get_all_env(App)}]),
                            {true, O, N}
                    end;
                E -> E
            end;
        E -> E
    end.

which_applications() -> [App || {App, _, _} <- application:which_applications()].

%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
