%% @author Sergey Smirnov <sasmir@gmail.com>

-module(dcbc_solver).

-export([start_link/4]).

-record(state, {solver_args, master, name, port = none, sol_incumbent = none}).

-behaviour(gen_server).
-export([init/1, handle_cast/2, handle_info/2, terminate/2]).

start_link(CbcPath, Name, MasterPid, Args) ->
    gen_server:start_link(?MODULE, [CbcPath, Name, MasterPid, Args], []).

init([CbcPath, Name, MasterPid, Args]) ->
    SolverArgs = proplists:get_value(solver_args, Args, []),
    Stub = proplists:get_value(stub, Args),
    BestVal = proplists:get_value(best_val, Args),
    gen_server:cast(self(), {do_init, CbcPath, Stub, BestVal}),
    monitor(process, MasterPid),
    {ok, #state{solver_args = SolverArgs, master = MasterPid, name = Name}}.

handle_cast({do_init, CbcPath, Stub, BestVal}, State) ->
    ok = file:write_file(stub_filename(), Stub),
    Args = [stub_filename(), "-p", "-o", log_filename()] ++ 
        case BestVal of
            none ->
                [];
            BestVal ->
                ["-b", float_to_list(BestVal)]
        end ++ ["--"] ++ State#state.solver_args,
    io:format("Starting solver for ~p: ~s ~p~n", [State#state.name, CbcPath, Args]),
    process_flag(trap_exit, true),
    Port = open_port({spawn_executable, CbcPath}, [{packet, 2}, nouse_stdio,
                                                   binary, {args, Args}]),
    {noreply, State#state{port = Port}};
handle_cast({update_best_val, Val}, #state{port = Port} = State) ->
    Port ! {self(), {command, <<1, Val/float>>}},
    {noreply, State}.

handle_info({'DOWN', _Ref, process, _Pid, _Reason}, State) -> 
    {stop, master_down, State};
handle_info({'EXIT', _Port, _ExitReason}, State) ->
    Log = case file:read_file(log_filename()) of
              {ok, LL} -> LL;
              {error, _LogReason} -> <<>>
          end,
    {Result, Inc, Sol} = case file:read_file(sol_filename()) of
                             {ok, SS} ->
                                 [L1 | _Rest] = string:tokens(binary_to_list(SS), "\n"),
                                 [_C, _V, R | Rest1] = string:tokens(L1, "/, "),
                                 case R of
                                     "optimal" -> {success, get_objective(Rest1), SS};
                                     "infeasible" -> {infeasible, none, <<>>}
                                 end;
                             {error, _Reason} ->
                                 {port_terminated, none, <<>>}
                         end,
    gen_server:cast(State#state.master, {solver_done, State#state.name, Result,
                                         Inc, Sol, Log}),
    {stop, normal, State};
handle_info({Port, {data, Data}}, #state{port = Port} = State) ->
    case decode(Data) of
        {best_val, Val} ->
            gen_server:cast(State#state.master, {best_val, State#state.name, Val}),
            {noreply, State};
        {done, Val, _} ->
            {noreply, State#state{sol_incumbent = Val}}
    end.

get_objective(["objective", Val | _Rest]) ->
    case string:to_float(Val) of
        {error, _} ->
            case string:to_integer(Val) of
                {error, _} -> none;
                {V, _} -> V
            end;
        {V, _} -> V
    end;
get_objective([_Head | Rest]) ->
    get_objective(Rest);
get_objective([]) ->
    none.

decode(<<2, BestVal/float, Status/binary>>) ->
    {done, BestVal, binary_to_list(Status)};
decode(<<3, BestVal/float>>) ->
    {best_val, BestVal}.

terminate(_Reason, _State) ->
    file:delete(stub_filename()),
    file:delete(sol_filename()),
    file:delete(log_filename()),
    ok.

stub_filename() ->
    "stub" ++ pid_to_list(self()) ++ ".nl".

sol_filename() ->
    "stub" ++ pid_to_list(self()) ++ ".sol".

log_filename() ->
    "stub" ++ pid_to_list(self()) ++ ".log".
