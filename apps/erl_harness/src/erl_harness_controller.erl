-%% Starts sessions and keeps a registry of their handles.
%% Looks up live session processes and removes entries when those processes exit.

module(erl_harness_controller).
-behaviour(gen_server).

-export([start_link/0, open/2, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

open(Owner, Workspace) ->
    gen_server:call(?MODULE, {open, Owner, filename:absname(Workspace)}).

lookup(Id) ->
    gen_server:call(?MODULE, {lookup, Id}).

init([]) ->
    Existing = supervisor:which_children(erl_harness_session_sup),
    {ok, maps:from_list([{Id, watch(Pid)} || {Id, Pid, _, _} <- Existing, is_pid(Pid)])}.

handle_call({open, Owner, Workspace}, _, Sessions) ->
    Id = make_ref(),
    Spec = #{id => Id, start => {erl_harness_session, start_link, [Owner, Workspace]},
        restart => temporary},
    case supervisor:start_child(erl_harness_session_sup, Spec) of
        {ok, Pid} -> {reply, {ok, Id, Pid}, Sessions#{Id => watch(Pid)}};
        Error -> {reply, Error, Sessions}
    end;
handle_call({lookup, Id}, _, Sessions) ->
    Reply = case maps:find(Id, Sessions) of
        {ok, {Pid, _}} -> {ok, Pid};
        error -> {error, not_found}
    end,
    {reply, Reply, Sessions}.

handle_cast(_, Sessions) ->
    {noreply, Sessions}.

handle_info({'DOWN', Ref, process, _, _}, Sessions) ->
    {noreply, maps:filter(fun(_, {_, Monitor}) -> Monitor =/= Ref end, Sessions)};
handle_info(_, Sessions) ->
    {noreply, Sessions}.

watch(Pid) ->
    {Pid, erlang:monitor(process, Pid)}.
