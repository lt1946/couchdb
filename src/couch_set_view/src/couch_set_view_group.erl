% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_set_view_group).
-behaviour(gen_server).

%% API
-export([start_link/1, request_group_info/1, get_data_size/1]).
-export([open_set_group/2]).
-export([request_group/2, release_group/1]).
-export([is_view_defined/1, define_view/2]).
-export([set_state/4]).
-export([partition_deleted/2]).
-export([add_replica_partitions/2, remove_replica_partitions/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").

-define(TIMEOUT, 3000).
-define(DELAYED_COMMIT_PERIOD, 5000).
-define(MIN_CHANGES_AUTO_UPDATE, 20000).
-define(BTREE_CHUNK_THRESHOLD, 5120).

-define(root_dir(State), element(1, State#state.init_args)).
-define(set_name(State), element(2, State#state.init_args)).
-define(type(State), (element(3, State#state.init_args))#set_view_group.type).
-define(group_sig(State), (element(3, State#state.init_args))#set_view_group.sig).
-define(group_id(State), (State#state.group)#set_view_group.name).
-define(db_set(State), (State#state.group)#set_view_group.db_set).
-define(is_defined(State),
    is_integer(((State#state.group)#set_view_group.index_header)#set_view_index_header.num_partitions)).
-define(replicas_on_transfer(State),
        ((State#state.group)#set_view_group.index_header)#set_view_index_header.replicas_on_transfer).
-define(have_pending_transition(State),
        ((((State#state.group)#set_view_group.index_header)
          #set_view_index_header.pending_transition) /= nil)).

-define(MAX_HIST_SIZE, 20).

-record(state, {
    init_args,
    replica_group = nil,
    group,
    updater_pid = nil,
    % 'not_running' | 'starting' | 'updating_active' | 'updating_passive'
    updater_state = not_running,
    compactor_pid = nil,
    compactor_file = nil,
    compactor_fun = nil,
    commit_ref = nil,
    waiting_list = [],
    cleaner_pid = nil,
    shutdown = false,
    replica_partitions = [],
    pending_transition_waiters = []
}).

-define(inc_stat(Group, S),
    ets:update_counter(
        ?SET_VIEW_STATS_ETS,
        ?set_view_group_stats_key(Group),
        {S, 1})).
-define(inc_cleanup_stops(Group), ?inc_stat(Group, #set_view_group_stats.cleanup_stops)).
-define(inc_updater_errors(Group), ?inc_stat(Group, #set_view_group_stats.update_errors)).
-define(inc_accesses(Group), ?inc_stat(Group, #set_view_group_stats.accesses)).


% api methods
request_group(Pid, Req) ->
    #set_view_group_req{wanted_partitions = WantedPartitions} = Req,
    Req2 = Req#set_view_group_req{
        wanted_partitions = ordsets:from_list(WantedPartitions)
    },
    request_group(Pid, Req2, 1).


request_group(Pid, Req, Retries) ->
    case gen_server:call(Pid, Req, infinity) of
    {ok, Group, ActiveReplicasBitmask} ->
        #set_view_group{
            ref_counter = RefCounter,
            replica_pid = RepPid,
            name = GroupName,
            set_name = SetName
        } = Group,
        case request_replica_group(RepPid, ActiveReplicasBitmask, Req) of
        {ok, RepGroup} ->
            {ok, Group#set_view_group{replica_group = RepGroup}};
        retry ->
            couch_ref_counter:drop(RefCounter),
            ?LOG_INFO("Retrying group `~s` request, stale=~s,"
                  " set `~s`, retry attempt #~p",
                  [GroupName, Req#set_view_group_req.stale, SetName, Retries]),
            request_group(Pid, Req, Retries + 1)
        end;
    Error ->
        Error
    end.


request_replica_group(_RepPid, 0, _Req) ->
    {ok, nil};
request_replica_group(RepPid, ActiveReplicasBitmask, Req) ->
    {ok, RepGroup, 0} = gen_server:call(RepPid, Req, infinity),
    case ?set_abitmask(RepGroup) =:= ActiveReplicasBitmask of
    true ->
        {ok, RepGroup};
    false ->
        couch_ref_counter:drop(RepGroup#set_view_group.ref_counter),
        retry
    end.


release_group(#set_view_group{ref_counter = RefCounter, replica_group = RepGroup}) ->
    couch_ref_counter:drop(RefCounter),
    case RepGroup of
    #set_view_group{ref_counter = RepRefCounter} ->
        couch_ref_counter:drop(RepRefCounter);
    nil ->
        ok
    end.


request_group_info(Pid) ->
    case gen_server:call(Pid, request_group_info, infinity) of
    {ok, GroupInfoList} ->
        {ok, GroupInfoList};
    Error ->
        throw(Error)
    end.


get_data_size(Pid) ->
    case gen_server:call(Pid, get_data_size, infinity) of
    {ok, _Info} = Ok ->
        Ok;
    Error ->
        throw(Error)
    end.


% Returns 'ignore' or 'shutdown'.
partition_deleted(Pid, PartId) ->
    try
        gen_server:call(Pid, {partition_deleted, PartId}, infinity)
    catch
    _:_ ->
        % May have stopped already, because partition was part of the
        % group's db set (active or passive partition).
        shutdown
    end.


define_view(Pid, Params) ->
    #set_view_params{
        max_partitions = NumPartitions,
        active_partitions = ActivePartitionsList,
        passive_partitions = PassivePartitionsList,
        use_replica_index = UseReplicaIndex
    } = Params,
    ActiveList = lists:usort(ActivePartitionsList),
    ActiveBitmask = couch_set_view_util:build_bitmask(ActiveList),
    PassiveList = lists:usort(PassivePartitionsList),
    PassiveBitmask = couch_set_view_util:build_bitmask(PassiveList),
    case (ActiveBitmask band PassiveBitmask) /= 0 of
    true ->
        throw({bad_view_definition,
            <<"Intersection between active and passive bitmasks">>});
    false ->
        ok
    end,
    gen_server:call(
        Pid, {define_view, NumPartitions, ActiveList, ActiveBitmask,
            PassiveList, PassiveBitmask, UseReplicaIndex}, infinity).


is_view_defined(Pid) ->
    gen_server:call(Pid, is_view_defined, infinity).


set_state(_Pid, [], [], []) ->
    ok;
set_state(Pid, ActivePartitions, PassivePartitions, CleanupPartitions) ->
    Active = ordsets:from_list(ActivePartitions),
    Passive = ordsets:from_list(PassivePartitions),
    case ordsets:intersection(Active, Passive) of
    [] ->
        Cleanup = ordsets:from_list(CleanupPartitions),
        case ordsets:intersection(Active, Cleanup) of
        [] ->
            case ordsets:intersection(Passive, Cleanup) of
            [] ->
                gen_server:call(
                    Pid, {set_state, Active, Passive, Cleanup}, infinity);
            _ ->
                {error,
                    <<"Intersection between passive and cleanup partition lists">>}
            end;
        _ ->
            {error, <<"Intersection between active and cleanup partition lists">>}
        end;
    _ ->
        {error, <<"Intersection between active and passive partition lists">>}
    end.


add_replica_partitions(_Pid, []) ->
    ok;
add_replica_partitions(Pid, Partitions) ->
    BitMask = couch_set_view_util:build_bitmask(Partitions),
    gen_server:call(Pid, {add_replicas, BitMask}, infinity).


remove_replica_partitions(_Pid, []) ->
    ok;
remove_replica_partitions(Pid, Partitions) ->
    gen_server:call(Pid, {remove_replicas, ordsets:from_list(Partitions)}, infinity).


start_link({RootDir, SetName, Group}) ->
    Args = {RootDir, SetName, Group#set_view_group{type = main}},
    proc_lib:start_link(?MODULE, init, [Args]).


init({_, _, Group} = InitArgs) ->
    process_flag(trap_exit, true),
    {ok, State} = try
        do_init(InitArgs)
    catch
    _:Error ->
        ?LOG_ERROR("~s error opening set view group `~s` from set `~s`: ~p",
            [?MODULE, Group#set_view_group.name, Group#set_view_group.set_name, Error]),
        exit(Error)
    end,
    proc_lib:init_ack({ok, self()}),
    gen_server:enter_loop(?MODULE, [], State, 1).


do_init({_, SetName, _} = InitArgs) ->
    case prepare_group(InitArgs, false) of
    {ok, #set_view_group{fd = Fd, index_header = Header, type = Type} = Group} ->
        RefCounter = new_fd_ref_counter(Fd),
        case Header#set_view_index_header.has_replica of
        false ->
            ReplicaPid = nil,
            ReplicaParts = [];
        true ->
            ReplicaPid = open_replica_group(InitArgs),
            maybe_fix_replica_group(ReplicaPid, Group),
            ReplicaParts = get_replica_partitions(ReplicaPid)
        end,
        case is_integer(Header#set_view_index_header.num_partitions) of
        false ->
            DbSet = nil,
            ?LOG_INFO("Started undefined ~s set view group `~s`, group `~s`",
                      [Type, SetName, Group#set_view_group.name]);
        true ->
            {ActiveList, PassiveList} = make_partition_lists(Group),
            DbSet = case (catch couch_db_set:open(SetName, ActiveList, PassiveList, [])) of
            {ok, SetPid} ->
                SetPid;
            Error ->
                throw(Error)
            end,
            ?LOG_INFO("Started ~s set view group `~s`, group `~s`~n"
                      "active partitions:  ~w~n"
                      "passive partitions: ~w~n"
                      "cleanup partitions: ~w~n"
                      "~sreplica support~n" ++
                      case Header#set_view_index_header.has_replica of
                      true ->
                          "replica partitions: ~w~n"
                          "replica partitions on transfer: ~w~n";
                      false ->
                          ""
                      end,
                      [Type, SetName, Group#set_view_group.name,
                       couch_set_view_util:decode_bitmask(Header#set_view_index_header.abitmask),
                       couch_set_view_util:decode_bitmask(Header#set_view_index_header.pbitmask),
                       couch_set_view_util:decode_bitmask(Header#set_view_index_header.cbitmask),
                       case Header#set_view_index_header.has_replica of
                       true ->
                           "";
                       false ->
                           "no "
                       end] ++
                       case Header#set_view_index_header.has_replica of
                       true ->
                           [ReplicaParts, ?set_replicas_on_transfer(Group)];
                       false ->
                           []
                       end)
        end,
        InitState = #state{
            init_args = InitArgs,
            replica_group = ReplicaPid,
            replica_partitions = ReplicaParts,
            group = Group#set_view_group{
                ref_counter = RefCounter,
                db_set = DbSet,
                replica_pid = ReplicaPid
            }
        },
        true = ets:insert(
             ?SET_VIEW_STATS_ETS,
             #set_view_group_stats{ets_key = ?set_view_group_stats_key(Group)}),
        {ok, maybe_apply_pending_transition(InitState)};
    Error ->
        throw(Error)
    end.

handle_call({define_view, NumPartitions, ActiveList, ActiveBitmask,
        PassiveList, PassiveBitmask, UseReplicaIndex}, _From, State) when not ?is_defined(State) ->
    #state{init_args = InitArgs, group = Group} = State,
    Seqs = lists:map(
        fun(PartId) -> {PartId, 0} end, lists:usort(ActiveList ++ PassiveList)),
    #set_view_group{
        name = DDocId,
        index_header = Header,
        views = Views
    } = Group,
    NewHeader = Header#set_view_index_header{
        num_partitions = NumPartitions,
        abitmask = ActiveBitmask,
        pbitmask = PassiveBitmask,
        seqs = Seqs,
        purge_seqs = Seqs,
        has_replica = UseReplicaIndex
    },
    case (catch couch_db_set:open(?set_name(State), ActiveList, PassiveList, [])) of
    {ok, DbSet} ->
        case (?type(State) =:= main) andalso UseReplicaIndex of
        false ->
            ReplicaPid = nil;
        true ->
            ReplicaPid = open_replica_group(InitArgs),
            ok = gen_server:call(ReplicaPid, {define_view, NumPartitions, [], 0, [], 0, false}, infinity)
        end,
        NewGroup = Group#set_view_group{
            db_set = DbSet,
            index_header = NewHeader,
            replica_pid = ReplicaPid,
            views = lists:map(
                fun(V) -> V#set_view{update_seqs = Seqs, purge_seqs = Seqs} end, Views)
        },
        ok = commit_header(NewGroup, true),
        NewState = State#state{
            group = NewGroup,
            replica_group = ReplicaPid
        },
        ?LOG_INFO("Set view `~s`, ~s group `~s`, configured with:~n"
            "~p partitions~n"
            "~sreplica support~n"
            "initial active partitions ~w~n"
            "initial passive partitions ~w",
            [?set_name(State), ?type(State), DDocId, NumPartitions,
            case UseReplicaIndex of
            true ->  "";
            false -> "no "
            end,
            ActiveList, PassiveList]),
        {reply, ok, NewState, ?TIMEOUT};
    Error ->
        {reply, Error, State, ?TIMEOUT}
    end;

handle_call({define_view, _, _, _, _, _, _}, _From, State) ->
    {reply, view_already_defined, State, ?TIMEOUT};

handle_call(is_view_defined, _From, #state{group = Group} = State) ->
    {reply, is_integer(?set_num_partitions(Group)), State, ?TIMEOUT};

handle_call({partition_deleted, master}, _From, State) ->
    Error = {error, {db_deleted, ?master_dbname((?set_name(State)))}},
    State2 = reply_all(State, Error),
    {stop, shutdown, shutdown, State2};
handle_call({partition_deleted, PartId}, _From, #state{group = Group} = State) ->
    Mask = 1 bsl PartId,
    case ((?set_abitmask(Group) band Mask) =/= 0) orelse
        ((?set_pbitmask(Group) band Mask) =/= 0) of
    true ->
        Error = {error, {db_deleted, ?dbname((?set_name(State)), PartId)}},
        State2 = reply_all(State, Error),
        {stop, shutdown, shutdown, State2};
    false ->
        {reply, ignore, State, ?TIMEOUT}
    end;

handle_call(_Msg, _From, State) when not ?is_defined(State) ->
    {reply, view_undefined, State};

handle_call({set_state, ActiveList, PassiveList, CleanupList}, _From, State) ->
    try
        NewState = maybe_update_partition_states(
            ActiveList, PassiveList, CleanupList, State),
        {reply, ok, NewState, ?TIMEOUT}
    catch
    throw:Error ->
        {reply, Error, State}
    end;

handle_call({add_replicas, BitMask}, _From, #state{replica_group = ReplicaPid} = State) when is_pid(ReplicaPid) ->
    #state{
        group = Group,
        replica_partitions = ReplicaParts
    } = State,
    BitMask2 = case BitMask band ?set_abitmask(Group) of
    0 ->
        BitMask;
    Common1 ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, ignoring request to set partitions"
                  " ~w to replica state because they are currently marked as active",
                  [?set_name(State), ?type(State), ?group_id(State),
                   couch_set_view_util:decode_bitmask(Common1)]),
        BitMask bxor Common1
    end,
    BitMask3 = case BitMask2 band ?set_pbitmask(Group) of
    0 ->
        BitMask2;
    Common2 ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, ignoring request to set partitions"
                  " ~w to replica state because they are currently marked as passive",
                  [?set_name(State), ?type(State), ?group_id(State),
                   couch_set_view_util:decode_bitmask(Common2)]),
        BitMask2 bxor Common2
    end,
    Parts = ordsets:from_list(couch_set_view_util:decode_bitmask(BitMask3)),
    ok = set_state(ReplicaPid, [], Parts, []),
    NewReplicaParts = ordsets:union(ReplicaParts, Parts),
    ?LOG_INFO("Set view `~s`, ~s group `~s`, defined new replica partitions: ~w~n"
              "New full set of replica partitions is: ~w~n",
              [?set_name(State), ?type(State), ?group_id(State), Parts, NewReplicaParts]),
    {reply, ok, State#state{replica_partitions = NewReplicaParts}, ?TIMEOUT};

handle_call({remove_replicas, Partitions}, _From, #state{replica_group = ReplicaPid} = State) when is_pid(ReplicaPid) ->
    #state{
        replica_partitions = ReplicaParts,
        group = Group
    } = State,
    case ordsets:intersection(?set_replicas_on_transfer(Group), Partitions) of
    [] ->
        ok = set_state(ReplicaPid, [], [], Partitions),
        NewState = State#state{
            replica_partitions = ordsets:subtract(ReplicaParts, Partitions)
        };
    Common ->
        UpdaterWasRunning = is_pid(State#state.updater_pid),
        State2 = stop_cleaner(State),
        #state{group = Group3} = State3 = stop_updater(State2, immediately),
        {ok, NewAbitmask, NewPbitmask, NewCbitmask, NewSeqs, NewPurgeSeqs} =
            set_cleanup_partitions(
                Common,
                ?set_abitmask(Group3),
                ?set_pbitmask(Group3),
                ?set_cbitmask(Group3),
                ?set_seqs(Group3),
                ?set_purge_seqs(Group3)),
        case NewCbitmask =/= ?set_cbitmask(Group3) of
        true ->
             State4 = restart_compactor(State3, "partition states were updated");
        false ->
             State4 = State3
        end,
        ok = couch_db_set:remove_partitions(?db_set(State4), Common),
        ReplicaPartitions2 = ordsets:subtract(ReplicaParts, Common),
        ReplicasOnTransfer2 = ordsets:subtract(?set_replicas_on_transfer(Group3), Common),
        State5 = update_header(
            State4,
            NewAbitmask,
            NewPbitmask,
            NewCbitmask,
            NewSeqs,
            NewPurgeSeqs,
            ReplicasOnTransfer2,
            ReplicaPartitions2),
        ok = set_state(ReplicaPid, [], [], Partitions),
        case UpdaterWasRunning of
        true ->
            State6 = start_updater(State5);
        false ->
            State6 = State5
        end,
        NewState = maybe_start_cleaner(State6)
    end,
    ?LOG_INFO("Set view `~s`, ~s group `~s`, marked the following replica partitions for removal: ~w",
              [?set_name(State), ?type(State), ?group_id(State), Partitions]),
    {reply, ok, NewState, ?TIMEOUT};

handle_call(#set_view_group_req{} = Req, From, State) ->
    #state{
        group = Group,
        pending_transition_waiters = Waiters
    } = State,
    State2 = case is_any_partition_pending(Req, Group) of
    false ->
        process_view_group_request(Req, From, State);
    true ->
        State#state{pending_transition_waiters = [{From, Req} | Waiters]}
    end,
    inc_view_group_access_stats(Req, State2#state.group),
    {noreply, State2, ?TIMEOUT};

handle_call(request_group, _From, #state{group = Group} = State) ->
    % Meant to be called only by this module and the compactor module.
    % Callers aren't supposed to read from the group's fd, we don't
    % increment here the ref counter on behalf of the caller.
    {reply, {ok, Group}, State, ?TIMEOUT};

handle_call(request_group_info, _From, State) ->
    GroupInfo = get_group_info(State),
    {reply, {ok, GroupInfo}, State, ?TIMEOUT};

handle_call(get_data_size, _From, State) ->
    DataSizeInfo = get_data_size_info(State),
    {reply, {ok, DataSizeInfo}, State, ?TIMEOUT};

handle_call({start_compact, CompactFun}, _From, #state{compactor_pid = nil} = State) ->
    #state{compactor_pid = Pid} = State2 = start_compactor(State, CompactFun),
    {reply, {ok, Pid}, State2};
handle_call({start_compact, _}, _From, State) ->
    %% compact already running, this is a no-op
    {reply, {ok, State#state.compactor_pid}, State};

handle_call({compact_done, Result}, {Pid, _}, #state{compactor_pid = Pid} = State) ->
    #state{
        group = Group,
        updater_pid = UpdaterPid,
        compactor_pid = CompactorPid
    } = State,
    #set_view_group{
        fd = OldFd,
        ref_counter = RefCounter,
        filepath = OldFilepath
    } = Group,
    #set_view_compactor_result{
        group = NewGroup0,
        compact_time = Duration,
        cleanup_kv_count = CleanupKVCount
    } = Result,

    case group_up_to_date(NewGroup0, State#state.group) of
    true ->
        NewGroup = NewGroup0#set_view_group{
            index_header = get_index_header_data(NewGroup0)
        },
        if is_pid(UpdaterPid) ->
            couch_util:shutdown_sync(UpdaterPid);
        true ->
            ok
        end,
        ok = commit_header(NewGroup, true),
        ?LOG_INFO("Set view `~s`, ~s group `~s`, compaction complete in ~.3f seconds,"
            " filtered ~p key-value pairs",
            [?set_name(State), ?type(State), ?group_id(State), Duration, CleanupKVCount]),
        NewFilepath = increment_filepath(Group),
        ok = couch_file:only_snapshot_reads(OldFd),
        ok = couch_file:delete(?root_dir(State), OldFilepath),
        ok = couch_file:rename(NewGroup#set_view_group.fd, NewFilepath),

        %% cleanup old group
        unlink(CompactorPid),
        drop_fd_ref_counter(RefCounter),
        NewRefCounter = new_fd_ref_counter(NewGroup#set_view_group.fd),
        NewGroup2 = NewGroup#set_view_group{
            ref_counter = NewRefCounter,
            filepath = NewFilepath,
            index_header = (NewGroup#set_view_group.index_header)#set_view_index_header{
                replicas_on_transfer = ?set_replicas_on_transfer(Group)
            }
        },

        NewUpdaterPid =
        if is_pid(UpdaterPid) ->
            spawn_link(couch_set_view_updater, update, [self(), NewGroup2]);
        true ->
            nil
        end,

        State2 = State#state{
            compactor_pid = nil,
            compactor_file = nil,
            compactor_fun = nil,
            updater_pid = NewUpdaterPid,
            updater_state = case is_pid(NewUpdaterPid) of
                true -> starting;
                false -> not_running
            end,
            group = NewGroup2
        },
        inc_compactions(State2#state.group, Result),
        {reply, ok, maybe_apply_pending_transition(State2), ?TIMEOUT};
    false ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, compaction still behind, retrying",
            [?set_name(State), ?type(State), ?group_id(State)]),
        {reply, update, State}
    end;
handle_call({compact_done, _Result}, _From, State) ->
    % From a previous compactor that was killed/stopped, ignore.
    {noreply, State, ?TIMEOUT};

handle_call(cancel_compact, _From, #state{compactor_pid = nil} = State) ->
    {reply, ok, State, ?TIMEOUT};
handle_call(cancel_compact, _From, #state{compactor_pid = Pid, compactor_file = CompactFd} = State) ->
    couch_util:shutdown_sync(Pid),
    couch_util:shutdown_sync(CompactFd),
    CompactFile = compact_file_name(State),
    ok = couch_file:delete(?root_dir(State), CompactFile),
    State2 = maybe_start_cleaner(State#state{compactor_pid = nil, compactor_file = nil}),
    {reply, ok, State2, ?TIMEOUT}.


handle_cast({partial_update, Pid, NewGroup}, #state{updater_pid = Pid} = State) ->
    case ?have_pending_transition(State) andalso
        (?set_cbitmask(NewGroup) =:= 0) andalso
        (?set_cbitmask(State#state.group) =/= 0) andalso
        (State#state.waiting_list =:= []) of
    true ->
        State2 = stop_updater(State, immediately),
        NewState = maybe_apply_pending_transition(State2);
    false ->
        NewState = process_partial_update(State, NewGroup)
    end,
    {noreply, NewState};
handle_cast({partial_update, _, _}, State) ->
    %% message from an old (probably pre-compaction) updater; ignore
    {noreply, State, ?TIMEOUT};

handle_cast(ddoc_updated, State) ->
    #state{
        waiting_list = Waiters,
        group = #set_view_group{name = DDocId, sig = CurSig}
    } = State,
    DbName = ?master_dbname((?set_name(State))),
    {ok, Db} = couch_db:open_int(DbName, []),
    case couch_db:open_doc(Db, DDocId, [ejson_body]) of
    {not_found, deleted} ->
        NewSig = nil;
    {ok, DDoc} ->
        #set_view_group{sig = NewSig} =
            couch_set_view_util:design_doc_to_set_view_group(?set_name(State), DDoc)
    end,
    couch_db:close(Db),
    case NewSig of
    CurSig ->
        {noreply, State#state{shutdown = false}, ?TIMEOUT};
    _ ->
        case Waiters of
        [] ->
            {stop, normal, State};
        _ ->
            {noreply, State#state{shutdown = true}}
        end
    end.


handle_info(timeout, State) when not ?is_defined(State) ->
    {noreply, State};

handle_info(timeout, State) ->
    case ?type(State) of
    main ->
        {noreply, maybe_start_cleaner(State)};
    replica ->
        {noreply, maybe_update_replica_index(State)}
    end;

handle_info({updater_info, Pid, {state, UpdaterState}}, #state{updater_pid = Pid} = State) ->
    #state{
        group = Group,
        waiting_list = WaitList,
        replica_partitions = RepParts
    } = State,
    State2 = State#state{updater_state = UpdaterState},
    case UpdaterState of
    updating_passive ->
        reply_with_group(Group, RepParts, WaitList),
        case State#state.shutdown of
        true ->
            State3 = stop_updater(State2),
            {stop, normal, State3};
        false ->
            State3 = maybe_apply_pending_transition(State2),
            {noreply, State3#state{waiting_list = []}}
        end;
    _ ->
        {noreply, State2}
    end;

handle_info({updater_info, _Pid, {state, _UpdaterState}}, State) ->
    % Message from an old updater, ignore.
    {noreply, State, ?TIMEOUT};

handle_info(delayed_commit, #state{group = Group} = State) ->
    ?LOG_INFO("Checkpointing set view `~s` update for ~s group `~s`",
        [?set_name(State), ?type(State), ?group_id(State)]),
    commit_header(Group, false),
    {noreply, State#state{commit_ref = nil}, ?TIMEOUT};

handle_info({'EXIT', Pid, {clean_group, NewGroup, Count, Time}}, #state{cleaner_pid = Pid} = State) ->
    #state{group = OldGroup} = State,
    ?LOG_INFO("Cleanup finished for set view `~s`, ~s group `~s`~n"
              "Removed ~p values from the index in ~.3f seconds~n"
              "active partitions before:  ~w~n"
              "active partitions after:   ~w~n"
              "passive partitions before: ~w~n"
              "passive partitions after:  ~w~n"
              "cleanup partitions before: ~w~n"
              "cleanup partitions after:  ~w~n" ++
          case is_pid(State#state.replica_group) of
          true ->
              "Current set of replica partitions: ~w~n"
              "Current set of replicas on transfer: ~w~n";
          false ->
               []
          end,
          [?set_name(State), ?type(State), ?group_id(State), Count, Time,
           couch_set_view_util:decode_bitmask(?set_abitmask(OldGroup)),
           couch_set_view_util:decode_bitmask(?set_abitmask(NewGroup)),
           couch_set_view_util:decode_bitmask(?set_pbitmask(OldGroup)),
           couch_set_view_util:decode_bitmask(?set_pbitmask(NewGroup)),
           couch_set_view_util:decode_bitmask(?set_cbitmask(OldGroup)),
           couch_set_view_util:decode_bitmask(?set_cbitmask(NewGroup))] ++
              case is_pid(State#state.replica_group) of
              true ->
                  [State#state.replica_partitions, ?set_replicas_on_transfer(NewGroup)];
              false ->
                  []
              end),
    State2 = State#state{
        cleaner_pid = nil,
        group = NewGroup
    },
    inc_cleanups(State2#state.group, Time, Count),
    {noreply, maybe_apply_pending_transition(State2)};

handle_info({'EXIT', Pid, Reason}, #state{cleaner_pid = Pid} = State) ->
    {stop, {cleaner_died, Reason}, State#state{cleaner_pid = nil}};

handle_info({'EXIT', Pid, shutdown},
    #state{group = #set_view_group{db_set = Pid}} = State) ->
    ?LOG_INFO("Set view `~s`, ~s group `~s`, terminating because database set "
              "was shutdown", [?set_name(State), ?type(State), ?group_id(State)]),
    {stop, normal, State};

handle_info({'EXIT', Pid, {updater_finished, Result}}, #state{updater_pid = Pid} = State) ->
    #state{
        waiting_list = WaitList,
        shutdown = Shutdown,
        replica_partitions = ReplicaParts
    } = State,
    #set_view_updater_result{
        indexing_time = IndexingTime,
        blocked_time = BlockedTime,
        group = NewGroup,
        inserted_ids = InsertedIds,
        deleted_ids = DeletedIds,
        inserted_kvs = InsertedKVs,
        deleted_kvs = DeletedKVs,
        cleanup_kv_count = CleanupKVCount
    } = Result,
    ok = commit_header(NewGroup, false),
    reply_with_group(NewGroup, ReplicaParts, WaitList),
    inc_updates(NewGroup, Result),
    ?LOG_INFO("Set view `~s`, ~s group `~s`, updater finished~n"
        "Indexing time: ~.3f seconds~n"
        "Blocked time:  ~.3f seconds~n"
        "Inserted IDs:  ~p~n"
        "Deleted IDs:   ~p~n"
        "Inserted KVs:  ~p~n"
        "Deleted KVs:   ~p~n"
        "Cleaned KVs:   ~p~n",
        [?set_name(State), ?type(State), ?group_id(State), IndexingTime, BlockedTime,
            InsertedIds, DeletedIds, InsertedKVs, DeletedKVs, CleanupKVCount]),
    case Shutdown of
    true ->
        {stop, normal, State};
    false ->
        cancel_commit(State),
        State2 = State#state{
            updater_pid = nil,
            updater_state = not_running,
            commit_ref = nil,
            waiting_list = [],
            group = NewGroup
        },
        State3 = maybe_apply_pending_transition(State2),
        State4 = maybe_start_cleaner(State3),
        {noreply, State4, ?TIMEOUT}
    end;

handle_info({'EXIT', Pid, {updater_error, Error}}, #state{updater_pid = Pid} = State) ->
    ?LOG_ERROR("Set view `~s`, ~s group `~s`, received error from updater: ~p",
        [?set_name(State), ?type(State), ?group_id(State), Error]),
    case State#state.shutdown of
    true ->
        {stop, normal, reply_all(State, {error, Error})};
    false ->
        State2 = State#state{
            updater_pid = nil,
            updater_state = not_running
        },
        ?inc_updater_errors(State#state.group),
        State3 = reply_all(State2, {error, Error}),
        {noreply, maybe_start_cleaner(State3), ?TIMEOUT}
    end;

handle_info({'EXIT', _Pid, {updater_error, _Error}}, State) ->
    % from old, shutdown updater, ignore
    {noreply, State, ?TIMEOUT};

handle_info({'EXIT', UpPid, reset}, #state{updater_pid = UpPid} = State) ->
    % TODO: once purge support is properly added, this needs to take into
    % account the replica index.
    State2 = stop_cleaner(State),
    case prepare_group(State#state.init_args, true) of
    {ok, ResetGroup} ->
        {ok, start_updater(State2#state{group = ResetGroup})};
    Error ->
        {stop, normal, reply_all(State2, Error), ?TIMEOUT}
    end;

handle_info({'EXIT', Pid, normal}, State) ->
    ?LOG_INFO("Set view `~s`, ~s group `~s`, linked PID ~p stopped normally",
              [?set_name(State), ?type(State), ?group_id(State), Pid]),
    {noreply, State, ?TIMEOUT};

handle_info({'EXIT', Pid, Reason}, #state{compactor_pid = Pid} = State) ->
    couch_util:shutdown_sync(State#state.compactor_file),
    {stop, {compactor_died, Reason}, State};

handle_info({'EXIT', Pid, Reason}, #state{group = #set_view_group{db_set = Pid}} = State) ->
    {stop, {db_set_died, Reason}, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_ERROR("Set view `~s`, ~s group `~s`, terminating because linked PID ~p "
              "died with reason: ~p",
              [?set_name(State), ?type(State), ?group_id(State), Pid, Reason]),
    {stop, Reason, State}.


terminate(Reason, State) ->
    ?LOG_INFO("Set view `~s`, ~s group `~s`, terminating with reason: ~p",
        [?set_name(State), ?type(State), ?group_id(State), Reason]),
    State2 = stop_cleaner(State),
    State3 = reply_all(State2, Reason),
    State4 = notify_pending_transition_waiters(State3, {shutdown, Reason}),
    catch couch_db_set:close(?db_set(State4)),
    couch_util:shutdown_sync(State4#state.updater_pid),
    couch_util:shutdown_sync(State4#state.compactor_pid),
    couch_util:shutdown_sync(State4#state.compactor_file),
    couch_util:shutdown_sync(State4#state.replica_group),
    catch couch_file:only_snapshot_reads((State4#state.group)#set_view_group.fd),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


reply_with_group(_Group0, _ReplicaPartitions, []) ->
    ok;
reply_with_group(Group0, ReplicaPartitions, WaitList) ->
    #set_view_group{
        ref_counter = RefCnt,
        debug_info = DebugInfo
    } = Group0,
    ActiveReplicasBitmask = couch_set_view_util:build_bitmask(
        ?set_replicas_on_transfer(Group0)),
    [Stats] = ets:lookup(?SET_VIEW_STATS_ETS, ?set_view_group_stats_key(Group0)),
    Group = Group0#set_view_group{
        debug_info = DebugInfo#set_view_debug_info{
            stats = Stats,
            original_abitmask = ?set_abitmask(Group0),
            original_pbitmask = ?set_pbitmask(Group0),
            replica_partitions = ReplicaPartitions
        }
    },
    lists:foreach(fun({Pid, _} = From) ->
        couch_ref_counter:add(RefCnt, Pid),
        gen_server:reply(From, {ok, Group, ActiveReplicasBitmask})
    end, WaitList).


reply_all(#state{waiting_list = []} = State, _Reply) ->
    State;
reply_all(#state{waiting_list = WaitList} = State, Reply) ->
    lists:foreach(fun(From) -> catch gen_server:reply(From, Reply) end, WaitList),
    State#state{waiting_list = []}.


prepare_group({RootDir, SetName, #set_view_group{sig = Sig, type = Type} = Group0}, ForceReset)->
    Filepath = find_index_file(RootDir, Group0),
    Group = Group0#set_view_group{filepath = Filepath},
    case open_index_file(Filepath) of
    {ok, Fd} ->
        if ForceReset ->
            % this can happen if we missed a purge
            {ok, reset_file(Fd, SetName, Group)};
        true ->
            case (catch couch_file:read_header(Fd)) of
            {ok, {Sig, HeaderInfo}} ->
                % sigs match!
                {ok, init_group(Fd, Group, HeaderInfo)};
            _ ->
                % this happens on a new file
                case (not ForceReset) andalso (Type =:= main) of
                true ->
                    % initializing main view group
                    catch delete_index_file(RootDir, Group, replica);
                false ->
                    ok
                end,
                {ok, reset_file(Fd, SetName, Group)}
            end
        end;
    {error, emfile} = Error ->
        ?LOG_ERROR("Can't open set view `~s`, ~s group `~s`: too many files open",
            [SetName, Type, Group#set_view_group.name]),
        Error;
    Error ->
        catch delete_index_file(RootDir, Group, Type),
        case (not ForceReset) andalso (Type =:= main) of
        true ->
            % initializing main view group
            catch delete_index_file(RootDir, Group, replica);
        false ->
            ok
        end,
        Error
    end.

get_index_header_data(Group) ->
    #set_view_group{
        id_btree = IdBtree,
        views = Views,
        index_header = Header
    } = Group,
    ViewStates = [
        {
            couch_btree:get_state(V#set_view.btree),
            V#set_view.update_seqs,
            V#set_view.purge_seqs
        } || V <- Views
    ],
    Header#set_view_index_header{
        id_btree_state = couch_btree:get_state(IdBtree),
        view_states = ViewStates
    }.

hex_sig(GroupSig) ->
    couch_util:to_hex(?b2l(GroupSig)).


base_index_file_name(Group, Type) when Type =:= main; Type =:= replica ->
    atom_to_list(Type) ++ "_" ++ hex_sig(Group#set_view_group.sig) ++ ".view".


find_index_file(RootDir, Group) ->
    find_index_file(RootDir, Group, Group#set_view_group.type).

find_index_file(RootDir, Group, Type) ->
    DesignRoot = couch_set_view:set_index_dir(RootDir, Group#set_view_group.set_name),
    BaseName = base_index_file_name(Group, Type),
    FullPath = filename:join([DesignRoot, BaseName]),
    case filelib:wildcard(FullPath ++ ".[0-9]*") of
    [] ->
        FullPath ++ ".1";
    Matching ->
        BaseNameSplitted = string:tokens(BaseName, "."),
        Matching2 = lists:filter(
            fun(Match) ->
                MatchBase = filename:basename(Match),
                [Suffix | Rest] = lists:reverse(string:tokens(MatchBase, ".")),
                (lists:reverse(Rest) =:= BaseNameSplitted) andalso
                    is_integer((catch list_to_integer(Suffix)))
            end,
            Matching),
        case Matching2 of
        [] ->
            FullPath ++ ".1";
        _ ->
            GetSuffix = fun(FileName) ->
                list_to_integer(lists:last(string:tokens(FileName, ".")))
            end,
            Matching3 = lists:sort(
                fun(A, B) -> GetSuffix(A) > GetSuffix(B) end,
                Matching2),
            hd(Matching3)
        end
    end.


delete_index_file(RootDir, Group, Type) ->
    BaseName = base_index_file_name(Group, Type),
    lists:foreach(
        fun(F) -> couch_file:delete(RootDir, F) end,
        filelib:wildcard(BaseName ++ ".[0-9]*")).


compact_file_name(#state{group = Group}) ->
    compact_file_name(Group);
compact_file_name(#set_view_group{filepath = CurFilepath}) ->
    CurFilepath ++ ".compact".


increment_filepath(#set_view_group{filepath = CurFilepath}) ->
    [Suffix | Rest] = lists:reverse(string:tokens(CurFilepath, ".")),
    NewSuffix = integer_to_list(list_to_integer(Suffix) + 1),
    string:join(lists:reverse(Rest), ".") ++ "." ++ NewSuffix.



open_index_file(Filepath) ->
    case do_open_index_file(Filepath) of
    {ok, Fd} ->
        unlink(Fd),
        {ok, Fd};
    Error ->
        Error
    end.

do_open_index_file(Filepath) ->
    case couch_file:open(Filepath) of
    {ok, Fd}        -> {ok, Fd};
    {error, enoent} -> couch_file:open(Filepath, [create]);
    Error           -> Error
    end.


open_set_group(SetName, GroupId) ->
    case couch_db:open_int(?master_dbname(SetName), []) of
    {ok, Db} ->
        case couch_db:open_doc(Db, GroupId, [ejson_body]) of
        {ok, Doc} ->
            couch_db:close(Db),
            {ok, couch_set_view_util:design_doc_to_set_view_group(SetName, Doc)};
        Else ->
            couch_db:close(Db),
            Else
        end;
    Else ->
        Else
    end.

get_group_info(State) ->
    #state{
        group = Group,
        replica_group = ReplicaPid,
        updater_pid = UpdaterPid,
        updater_state = UpdaterState,
        compactor_pid = CompactorPid,
        commit_ref = CommitRef,
        waiting_list = WaitersList,
        cleaner_pid = CleanerPid,
        replica_partitions = ReplicaParts
    } = State,
    #set_view_group{
        fd = Fd,
        sig = GroupSig,
        id_btree = Btree,
        def_lang = Lang,
        views = Views
    } = Group,
    PendingTrans = get_pending_transition(State),
    [Stats] = ets:lookup(?SET_VIEW_STATS_ETS, ?set_view_group_stats_key(Group)),
    JsonStats = {[
        {full_updates, Stats#set_view_group_stats.full_updates},
        {partial_updates, Stats#set_view_group_stats.partial_updates},
        {stopped_updates, Stats#set_view_group_stats.stopped_updates},
        {updater_cleanups, Stats#set_view_group_stats.updater_cleanups},
        {compactions, Stats#set_view_group_stats.compactions},
        {cleanups, Stats#set_view_group_stats.cleanups},
        {waiting_clients, length(WaitersList)},
        {cleanup_interruptions, Stats#set_view_group_stats.cleanup_stops},
        {update_history, Stats#set_view_group_stats.update_history},
        {compaction_history, Stats#set_view_group_stats.compaction_history},
        {cleanup_history, Stats#set_view_group_stats.cleanup_history}
    ]},
    {ok, Size} = couch_file:bytes(Fd),
    [
        {signature, ?l2b(hex_sig(GroupSig))},
        {language, Lang},
        {disk_size, Size},
        {data_size, view_group_data_size(Btree, Views)},
        {updater_running, UpdaterPid /= nil},
        {updater_state, couch_util:to_binary(UpdaterState)},
        {compact_running, CompactorPid /= nil},
        {cleanup_running, (CleanerPid /= nil) orelse
            ((CompactorPid /= nil) andalso (?set_cbitmask(Group) =/= 0))},
        {waiting_commit, is_reference(CommitRef)},
        {max_number_partitions, ?set_num_partitions(Group)},
        {update_seqs, {[{couch_util:to_binary(P), S} || {P, S} <- ?set_seqs(Group)]}},
        {purge_seqs, {[{couch_util:to_binary(P), S} || {P, S} <- ?set_purge_seqs(Group)]}},
        {active_partitions, couch_set_view_util:decode_bitmask(?set_abitmask(Group))},
        {passive_partitions, couch_set_view_util:decode_bitmask(?set_pbitmask(Group))},
        {cleanup_partitions, couch_set_view_util:decode_bitmask(?set_cbitmask(Group))},
        {stats, JsonStats},
        {pending_transition, case PendingTrans of
            nil ->
                null;
            #set_view_transition{} ->
                {[
                    {active, PendingTrans#set_view_transition.active},
                    {passive, PendingTrans#set_view_transition.passive},
                    {cleanup, PendingTrans#set_view_transition.cleanup}
                ]}
            end
        }
    ] ++
    case (?type(State) =:= main) andalso is_pid(ReplicaPid) of
    true ->
        [{replica_partitions, ReplicaParts}, {replicas_on_transfer, ?set_replicas_on_transfer(Group)}];
    false ->
        []
    end ++
    get_replica_group_info(ReplicaPid).

get_replica_group_info(ReplicaPid) when is_pid(ReplicaPid) ->
    {ok, RepGroupInfo} = gen_server:call(ReplicaPid, request_group_info, infinity),
    [{replica_group_info, {RepGroupInfo}}];
get_replica_group_info(_) ->
    [].


get_data_size_info(State) ->
    #state{
        group = Group,
        replica_group = ReplicaPid,
        updater_pid = UpdaterPid
    } = State,
    #set_view_group{
        fd = Fd,
        id_btree = Btree,
        views = Views
    } = Group,
    {ok, FileSize} = couch_file:bytes(Fd),
    DataSize = view_group_data_size(Btree, Views),
    Info = [
        {disk_size, FileSize},
        {data_size, DataSize},
        {updater_running, is_pid(UpdaterPid)}
    ],
    case is_pid(ReplicaPid) of
    false ->
        Info;
    true ->
        {ok, RepInfo} = gen_server:call(ReplicaPid, get_data_size, infinity),
        [{replica_group_info, RepInfo} | Info]
    end.


view_group_data_size(IdBtree, Views) ->
    lists:foldl(
        fun(#set_view{btree = Btree}, Acc) ->
            Acc + couch_btree:size(Btree)
        end,
        couch_btree:size(IdBtree),
        Views).


reset_group(#set_view_group{views = Views} = Group) ->
    Views2 = [View#set_view{btree = nil} || View <- Views],
    Group#set_view_group{
        fd = nil,
        index_header = nil,
        id_btree = nil,
        views = Views2
    }.

reset_file(Fd, SetName, #set_view_group{
        sig = Sig, name = Name, index_header = Header} = Group) ->
    ?LOG_DEBUG("Resetting group index `~s` in set `~s`", [Name, SetName]),
    ok = couch_file:truncate(Fd, 0),
    ok = couch_file:write_header(Fd, {Sig, nil}),
    init_group(Fd, reset_group(Group), Header).

init_group(Fd, #set_view_group{views = Views}=Group, nil) ->
    EmptyHeader = #set_view_index_header{
        view_states = [{nil, [], []} || _ <- Views]
    },
    init_group(Fd, Group, EmptyHeader);
init_group(Fd, #set_view_group{views = Views0} = Group, IndexHeader) ->
    Views = [V#set_view{ref = make_ref()} || V <- Views0],
    #set_view_index_header{
        id_btree_state = IdBtreeState,
        view_states = ViewStates
    } = IndexHeader,
    StateUpdate = fun
        ({_, _, _}=State) -> State;
        (State) -> {State, [], []}
    end,
    ViewStates2 = lists:map(StateUpdate, ViewStates),
    IdTreeReduce = fun(reduce, KVs) ->
        {length(KVs), couch_set_view_util:partitions_map(KVs, 0)};
    (rereduce, [First | Rest]) ->
        lists:foldl(
            fun({S, M}, {T, A}) -> {S + T, M bor A} end,
            First, Rest)
    end,
    BtreeOptions = [
        {chunk_threshold, ?BTREE_CHUNK_THRESHOLD}
    ],
    {ok, IdBtree} = couch_btree:open(
        IdBtreeState, Fd, [{reduce, IdTreeReduce} | BtreeOptions]),
    Views2 = lists:zipwith(
        fun({BTState, USeqs, PSeqs}, #set_view{options = Options} = View) ->
            ReduceFun =
                fun(reduce, KVs) ->
                    AllPartitionsBitMap = couch_set_view_util:partitions_map(KVs, 0),
                    KVs2 = couch_set_view_util:expand_dups(KVs, []),
                    {ok, Reduced} = couch_set_view_mapreduce:reduce(View, KVs2),
                    {length(KVs2), Reduced, AllPartitionsBitMap};
                (rereduce, [{Count0, Red0, AllPartitionsBitMap0} | Reds]) ->
                    {Count, UserReds, AllPartitionsBitMap} = lists:foldl(
                        fun({C, R, Apbm}, {CountAcc, RedAcc, ApbmAcc}) ->
                            {C + CountAcc, [R | RedAcc], Apbm bor ApbmAcc}
                        end,
                        {Count0, [Red0], AllPartitionsBitMap0},
                        Reds),
                    {ok, Reduced} = couch_set_view_mapreduce:rereduce(View, UserReds),
                    {Count, Reduced, AllPartitionsBitMap}
                end,
            
            case couch_util:get_value(<<"collation">>, Options, <<"default">>) of
            <<"default">> ->
                Less = fun couch_set_view:less_json_ids/2;
            <<"raw">> ->
                Less = fun(A,B) -> A < B end
            end,
            {ok, Btree} = couch_btree:open(
                BTState, Fd, [{less, Less}, {reduce, ReduceFun} | BtreeOptions]),
            View#set_view{btree=Btree, update_seqs=USeqs, purge_seqs=PSeqs}
        end,
        ViewStates2, Views),
    Group#set_view_group{
        fd = Fd,
        id_btree = IdBtree,
        views = Views2,
        index_header = IndexHeader
    }.


commit_header(Group, Sync) ->
    Header = {Group#set_view_group.sig, get_index_header_data(Group)},
    ok = couch_file:write_header(Group#set_view_group.fd, Header),
    case Sync of
    true ->
        ok = couch_file:sync(Group#set_view_group.fd);
    false ->
        ok
    end.


group_up_to_date(#set_view_group{} = NewGroup, #set_view_group{} = CurGroup) ->
    compare_seqs(?set_seqs(NewGroup), ?set_seqs(CurGroup)).


compare_seqs([], []) ->
    true;
compare_seqs([{PartId, SeqA} | RestA], [{PartId, SeqB} | RestB]) ->
    case SeqA - SeqB of
    Greater when Greater >= 0 ->
        compare_seqs(RestA, RestB);
    _Smaller ->
        false
    end.


maybe_update_partition_states(ActiveList, PassiveList, CleanupList, State) ->
    #state{group = Group} = State,
    ActiveMask = couch_set_view_util:build_bitmask(ActiveList),
    case ActiveMask >= (1 bsl ?set_num_partitions(Group)) of
    true ->
        throw({error, <<"Invalid active partitions list">>});
    false ->
        ok
    end,
    PassiveMask = couch_set_view_util:build_bitmask(PassiveList),
    case PassiveMask >= (1 bsl ?set_num_partitions(Group)) of
    true ->
        throw({error, <<"Invalid passive partitions list">>});
    false ->
        ok
    end,
    CleanupMask = couch_set_view_util:build_bitmask(CleanupList),
    case CleanupMask >= (1 bsl ?set_num_partitions(Group)) of
    true ->
        throw({error, <<"Invalid cleanup partitions list">>});
    false ->
        ok
    end,
    case (ActiveMask bor ?set_abitmask(Group)) =:= ?set_abitmask(Group) andalso
        (PassiveMask bor ?set_pbitmask(Group)) =:= ?set_pbitmask(Group) andalso
        (CleanupMask bor ?set_cbitmask(Group)) =:= ?set_cbitmask(Group) of
    true ->
        State;
    false ->
        update_partition_states(ActiveList, PassiveList, CleanupList, State)
    end.


update_partition_states(ActiveList, PassiveList, CleanupList, State) ->
    case ?have_pending_transition(State) of
    true ->
        merge_into_pending_transition(ActiveList, PassiveList, CleanupList, State);
    false ->
        do_update_partition_states(ActiveList, PassiveList, CleanupList, State)
    end.


merge_into_pending_transition(ActiveList, PassiveList, CleanupList, State) ->
    % Note: checking if there's an intersection between active, passive and
    % cleanup lists must have been done already.
    Pending = get_pending_transition(State),
    Pending2 = merge_pending_active(Pending, ActiveList),
    Pending3 = merge_pending_passive(Pending2, PassiveList),
    Pending4 = merge_pending_cleanup(Pending3, CleanupList),
    #set_view_transition{
        active = ActivePending4,
        passive = PassivePending4,
        cleanup = CleanupPending4
    } = Pending4,
    State2 = set_pending_transition(State, Pending4),
    ok = commit_header(State2#state.group, true),
    ?LOG_INFO("Set view `~s`, ~s group `~s`, updated pending partition "
        "states transition to:~n"
        "    Active partitions:  ~w~n"
        "    Passive partitions: ~w~n"
        "    Cleanup partitions: ~w~n",
        [?set_name(State), ?type(State), ?group_id(State),
             ActivePending4, PassivePending4, CleanupPending4]),
    State3 = notify_pending_transition_waiters(State2),
    maybe_apply_pending_transition(State3).


merge_pending_active(Pending, ActiveList) ->
    #set_view_transition{
        active = ActivePending,
        passive = PassivePending,
        cleanup = CleanupPending
    } = Pending,
    Pending#set_view_transition{
        active = ordsets:union(ActivePending, ActiveList),
        passive = ordsets:subtract(PassivePending, ActiveList),
        cleanup = ordsets:subtract(CleanupPending, ActiveList)
    }.


merge_pending_passive(Pending, PassiveList) ->
    #set_view_transition{
        active = ActivePending,
        passive = PassivePending,
        cleanup = CleanupPending
    } = Pending,
    Pending#set_view_transition{
        active = ordsets:subtract(ActivePending, PassiveList),
        passive = ordsets:union(PassivePending, PassiveList),
        cleanup = ordsets:subtract(CleanupPending, PassiveList)
    }.


merge_pending_cleanup(Pending, CleanupList) ->
    #set_view_transition{
        active = ActivePending,
        passive = PassivePending,
        cleanup = CleanupPending
    } = Pending,
    Pending#set_view_transition{
        active = ordsets:subtract(ActivePending, CleanupList),
        passive = ordsets:subtract(PassivePending, CleanupList),
        cleanup = ordsets:union(CleanupPending, CleanupList)
    }.


do_update_partition_states(ActiveList, PassiveList, CleanupList, State) ->
    UpdaterRunning = is_pid(State#state.updater_pid),
    State2 = stop_cleaner(State),
    #state{group = Group3} = State3 = stop_updater(State2, immediately),
    InCleanup = partitions_still_in_cleanup(ActiveList ++ PassiveList, Group3),
    case InCleanup of
    [] ->
        State4 = persist_partition_states(State3, ActiveList, PassiveList, CleanupList);
    _ ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, created pending partition "
            "states transition, because the following partitions are still "
            "in cleanup:~w~n~n"
            "Pending partition states transition details:~n"
            "    Active partitions:  ~w~n"
            "    Passive partitions: ~w~n"
            "    Cleanup partitions: ~w~n",
            [?set_name(State), ?type(State), ?group_id(State),
                InCleanup, ActiveList, PassiveList, CleanupList]),
        Pending = #set_view_transition{
            active = ActiveList,
            passive = PassiveList,
            cleanup = CleanupList
        },
        State4 = set_pending_transition(State3, Pending)
    end,
    after_partition_states_updated(State4, UpdaterRunning).


after_partition_states_updated(State, UpdaterWasRunning) ->
    case ?type(State) of
    main ->
        State2 = case UpdaterWasRunning of
        true ->
            % Updater was running, we stopped it, updated the group we received
            % from the updater, updated that group's bitmasks and update/purge
            % seqs, and now restart the updater with this modified group.
            start_updater(State);
        false ->
            State
        end,
        State3 = restart_compactor(State2, "partition states were updated"),
        maybe_start_cleaner(State3);
    replica ->
        State2 = restart_compactor(State, "partition states were updated"),
        case is_pid(State2#state.compactor_pid) of
        true ->
            State2;
        false ->
            maybe_update_replica_index(State2)
        end
    end.


persist_partition_states(State, ActiveList, PassiveList, CleanupList) ->
    #state{
        group = Group,
        replica_partitions = ReplicaParts,
        replica_group = ReplicaPid
    } = State,
    case ordsets:intersection(ActiveList, ReplicaParts) of
    [] ->
         ActiveList2 = ActiveList,
         PassiveList2 = PassiveList,
         ReplicasOnTransfer2 = ?set_replicas_on_transfer(Group),
         ReplicasToMarkActive = [];
    CommonRep ->
         PassiveList2 = ordsets:union(PassiveList, CommonRep),
         ActiveList2 = ordsets:subtract(ActiveList, CommonRep),
         ReplicasOnTransfer2 = ordsets:union(?set_replicas_on_transfer(Group), CommonRep),
         ReplicasToMarkActive = CommonRep
    end,
    case ordsets:intersection(PassiveList, ReplicasOnTransfer2) of
    [] ->
        PassiveList3 = PassiveList2,
        ReplicasOnTransfer3 = ReplicasOnTransfer2;
    CommonRep2 ->
        PassiveList3 = ordsets:subtract(PassiveList2, CommonRep2),
        ReplicasOnTransfer3 = ordsets:subtract(ReplicasOnTransfer2, CommonRep2)
    end,
    case ordsets:intersection(CleanupList, ReplicasOnTransfer3) of
    [] ->
        ReplicaParts2 = ReplicaParts,
        ReplicasOnTransfer4 = ReplicasOnTransfer3,
        ReplicasToCleanup = [];
    CommonRep3 ->
        ReplicaParts2 = ordsets:subtract(ReplicaParts, CommonRep3),
        ReplicasOnTransfer4 = ordsets:subtract(ReplicasOnTransfer3, CommonRep3),
        ReplicasToCleanup = CommonRep3
    end,
    {ok, NewAbitmask1, NewPbitmask1, NewSeqs1, NewPurgeSeqs1} =
        set_active_partitions(
            ActiveList2,
            ?set_abitmask(Group),
            ?set_pbitmask(Group),
            ?set_seqs(Group),
            ?set_purge_seqs(Group)),
    {ok, NewAbitmask2, NewPbitmask2, NewSeqs2, NewPurgeSeqs2} =
        set_passive_partitions(
            PassiveList3,
            NewAbitmask1,
            NewPbitmask1,
            NewSeqs1,
            NewPurgeSeqs1),
    {ok, NewAbitmask3, NewPbitmask3, NewCbitmask3, NewSeqs3, NewPurgeSeqs3} =
        set_cleanup_partitions(
            CleanupList,
            NewAbitmask2,
            NewPbitmask2,
            ?set_cbitmask(Group),
            NewSeqs2,
            NewPurgeSeqs2),
    ok = couch_db_set:remove_partitions(?db_set(State), CleanupList),
    State2 = update_header(
        State,
        NewAbitmask3,
        NewPbitmask3,
        NewCbitmask3,
        NewSeqs3,
        NewPurgeSeqs3,
        ReplicasOnTransfer4,
        ReplicaParts2),
    % A crash might happen between updating our header and updating the state of
    % replica view group. The init function must detect and correct this.
    ok = set_state(ReplicaPid, ReplicasToMarkActive, [], ReplicasToCleanup),
    State2.


maybe_apply_pending_transition(State) when not ?have_pending_transition(State) ->
    State;
maybe_apply_pending_transition(State) ->
    #set_view_transition{
        active = ActivePending,
        passive = PassivePending,
        cleanup = CleanupPending
    } = get_pending_transition(State),
    InCleanup = partitions_still_in_cleanup(
        ActivePending ++ PassivePending, State#state.group),
    case InCleanup of
    [] ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, applying pending partition "
            "states transition:~n"
            "    Active partitions:  ~w~n"
            "    Passive partitions: ~w~n"
            "    Cleanup partitions: ~w~n",
            [?set_name(State), ?type(State), ?group_id(State),
                ActivePending, PassivePending, CleanupPending]),
        UpdaterRunning = is_pid(State#state.updater_pid),
        State2 = stop_cleaner(State),
        State3 = stop_updater(State2, immediately),
        State4 = set_pending_transition(State3, nil),
        State5 = persist_partition_states(
            State4, ActivePending, PassivePending, CleanupPending),
        State6 = notify_pending_transition_waiters(State5),
        after_partition_states_updated(State6, UpdaterRunning);
    _ ->
        State
    end.


notify_pending_transition_waiters(#state{pending_transition_waiters = []} = State) ->
    State;
notify_pending_transition_waiters(State) ->
    #state{
        pending_transition_waiters = TransWaiters,
        group = Group,
        replica_partitions = RepParts,
        waiting_list = WaitList
    } = State,
    {TransWaiters2, WaitList2, GroupReplyList, TriggerGroupUpdate} =
        lists:foldr(
            fun({From, Req} = TransWaiter, {AccTrans, AccWait, ReplyAcc, AccTriggerUp}) ->
                #set_view_group_req{stale = Stale} = Req,
                case is_any_partition_pending(Req, Group) of
                true ->
                    {[TransWaiter | AccTrans], AccWait, ReplyAcc, AccTriggerUp};
                false when Stale == ok ->
                    {AccTrans, AccWait, [From | ReplyAcc], AccTriggerUp};
                false when Stale == update_after ->
                    {AccTrans, AccWait, [From | ReplyAcc], true};
                false when Stale == false ->
                    {AccTrans, [From | AccWait], ReplyAcc, true}
                end
            end,
            {[], WaitList, [], false},
            TransWaiters),
    reply_with_group(Group, RepParts, GroupReplyList),
    State2 = State#state{
        pending_transition_waiters = TransWaiters2,
        waiting_list = WaitList2
    },
    case TriggerGroupUpdate of
    true ->
        start_updater(State2);
    false ->
        State2
    end.


notify_pending_transition_waiters(#state{pending_transition_waiters = []} = State, _Reply) ->
    State;
notify_pending_transition_waiters(#state{pending_transition_waiters = Waiters} = State, Reply) ->
    lists:foreach(fun(F) -> catch gen_server:reply(F, Reply) end, Waiters),
    State#state{pending_transition_waiters = []}.


set_passive_partitions([], Abitmask, Pbitmask, Seqs, PurgeSeqs) ->
    {ok, Abitmask, Pbitmask, Seqs, PurgeSeqs};

set_passive_partitions([PartId | Rest], Abitmask, Pbitmask, Seqs, PurgeSeqs) ->
    PartMask = 1 bsl PartId,
    case PartMask band Abitmask of
    0 ->
        case PartMask band Pbitmask of
        PartMask ->
            set_passive_partitions(Rest, Abitmask, Pbitmask, Seqs, PurgeSeqs);
        0 ->
            NewSeqs = lists:ukeymerge(1, [{PartId, 0}], Seqs),
            NewPurgeSeqs = lists:ukeymerge(1, [{PartId, 0}], PurgeSeqs),
            set_passive_partitions(
                Rest, Abitmask, Pbitmask bor PartMask, NewSeqs, NewPurgeSeqs)
        end;
    PartMask ->
        set_passive_partitions(
            Rest, Abitmask bxor PartMask, Pbitmask bor PartMask, Seqs, PurgeSeqs)
    end.


set_active_partitions([], Abitmask, Pbitmask, Seqs, PurgeSeqs) ->
    {ok, Abitmask, Pbitmask, Seqs, PurgeSeqs};

set_active_partitions([PartId | Rest], Abitmask, Pbitmask, Seqs, PurgeSeqs) ->
    PartMask = 1 bsl PartId,
    case PartMask band Pbitmask of
    0 ->
        case PartMask band Abitmask of
        PartMask ->
            set_active_partitions(Rest, Abitmask, Pbitmask, Seqs, PurgeSeqs);
        0 ->
            NewSeqs = lists:ukeymerge(1, Seqs, [{PartId, 0}]),
            NewPurgeSeqs = lists:ukeymerge(1, PurgeSeqs, [{PartId, 0}]),
            set_active_partitions(
                Rest, Abitmask bor PartMask, Pbitmask, NewSeqs, NewPurgeSeqs)
        end;
    PartMask ->
        set_active_partitions(
            Rest, Abitmask bor PartMask, Pbitmask bxor PartMask, Seqs, PurgeSeqs)
    end.


set_cleanup_partitions([], Abitmask, Pbitmask, Cbitmask, Seqs, PurgeSeqs) ->
    {ok, Abitmask, Pbitmask, Cbitmask, Seqs, PurgeSeqs};

set_cleanup_partitions([PartId | Rest], Abitmask, Pbitmask, Cbitmask, Seqs, PurgeSeqs) ->
    PartMask = 1 bsl PartId,
    case PartMask band Cbitmask of
    PartMask ->
        set_cleanup_partitions(Rest, Abitmask, Pbitmask, Cbitmask, Seqs, PurgeSeqs);
    0 ->
        Seqs2 = lists:keydelete(PartId, 1, Seqs),
        PurgeSeqs2 = lists:keydelete(PartId, 1, PurgeSeqs),
        Cbitmask2 = Cbitmask bor PartMask,
        case PartMask band Abitmask of
        PartMask ->
            set_cleanup_partitions(
                Rest, Abitmask bxor PartMask, Pbitmask, Cbitmask2, Seqs2, PurgeSeqs2);
        0 ->
            case (PartMask band Pbitmask) of
            PartMask ->
                set_cleanup_partitions(
                    Rest, Abitmask, Pbitmask bxor PartMask, Cbitmask2, Seqs2, PurgeSeqs2);
            0 ->
                set_cleanup_partitions(
                    Rest, Abitmask, Pbitmask, Cbitmask, Seqs, PurgeSeqs)
            end
        end
    end.


update_header(State, NewAbitmask, NewPbitmask, NewCbitmask, NewSeqs, NewPurgeSeqs, NewRelicasOnTransfer, NewReplicaParts) ->
    #state{
        group = #set_view_group{
            index_header =
                #set_view_index_header{
                    abitmask = Abitmask,
                    pbitmask = Pbitmask,
                    cbitmask = Cbitmask,
                    replicas_on_transfer = ReplicasOnTransfer
                } = Header,
            views = Views
        } = Group,
        replica_partitions = ReplicaParts
    } = State,
    NewState = State#state{
        group = Group#set_view_group{
            index_header = Header#set_view_index_header{
                abitmask = NewAbitmask,
                pbitmask = NewPbitmask,
                cbitmask = NewCbitmask,
                seqs = NewSeqs,
                purge_seqs = NewPurgeSeqs,
                replicas_on_transfer = NewRelicasOnTransfer
            },
            views = lists:map(
                fun(V) ->
                    V#set_view{update_seqs = NewSeqs, purge_seqs = NewPurgeSeqs}
                end, Views)
        },
        replica_partitions = NewReplicaParts
    },
    ok = commit_header(NewState#state.group, true),
    case (NewAbitmask =:= Abitmask) andalso (NewPbitmask =:= Pbitmask) of
    true ->
        ok;
    false ->
        {ActiveList, PassiveList} = make_partition_lists(NewState#state.group),
        ok = couch_db_set:set_active(?db_set(NewState), ActiveList),
        ok = couch_db_set:set_passive(?db_set(NewState), PassiveList)
    end,
    ?LOG_INFO("Set view `~s`, ~s group `~s`, partition states updated~n"
        "active partitions before:  ~w~n"
        "active partitions after:   ~w~n"
        "passive partitions before: ~w~n"
        "passive partitions after:  ~w~n"
        "cleanup partitions before: ~w~n"
        "cleanup partitions after:  ~w~n" ++
        case is_pid(State#state.replica_group) of
        true ->
            "replica partitions before:   ~w~n"
            "replica partitions after:    ~w~n"
            "replicas on transfer before: ~w~n"
            "replicas on transfer after:  ~w~n";
        false ->
            ""
        end,
        [?set_name(State), ?type(State), ?group_id(State),
         couch_set_view_util:decode_bitmask(Abitmask),
         couch_set_view_util:decode_bitmask(NewAbitmask),
         couch_set_view_util:decode_bitmask(Pbitmask),
         couch_set_view_util:decode_bitmask(NewPbitmask),
         couch_set_view_util:decode_bitmask(Cbitmask),
         couch_set_view_util:decode_bitmask(NewCbitmask)] ++
         case is_pid(State#state.replica_group) of
         true ->
             [ReplicaParts, NewReplicaParts, ReplicasOnTransfer, NewRelicasOnTransfer];
         false ->
             []
         end),
    NewState.


maybe_start_cleaner(#state{cleaner_pid = Pid} = State) when is_pid(Pid) ->
    State;
maybe_start_cleaner(#state{group = Group} = State) ->
    case is_pid(State#state.compactor_pid) orelse
        is_pid(State#state.updater_pid) orelse (?set_cbitmask(Group) == 0) of
    true ->
        State;
    false ->
        Cleaner = spawn_link(fun() -> exit(cleaner(State)) end),
        ?LOG_INFO("Started cleanup process ~p for set view `~s`, ~s group `~s`",
                  [Cleaner, ?set_name(State), ?type(State), ?group_id(State)]),
        State#state{cleaner_pid = Cleaner}
    end.


stop_cleaner(#state{cleaner_pid = nil} = State) ->
    State;
stop_cleaner(#state{cleaner_pid = Pid, group = OldGroup} = State) when is_pid(Pid) ->
    ?LOG_INFO("Stopping cleanup process for set view `~s`, group `~s`",
        [?set_name(State), ?group_id(State)]),
    Pid ! stop,
    receive
    {'EXIT', Pid, {clean_group, NewGroup, Count, Time}} ->
        ?LOG_INFO("Stopped cleanup process for set view `~s`, ~s group `~s`.~n"
             "Removed ~p values from the index in ~.3f seconds~n"
             "New set of partitions to cleanup: ~w~n"
             "Old set of partitions to cleanup: ~w~n",
             [?set_name(State), ?type(State), ?group_id(State), Count, Time,
                 couch_set_view_util:decode_bitmask(?set_cbitmask(NewGroup)),
                 couch_set_view_util:decode_bitmask(?set_cbitmask(OldGroup))]),
        case ?set_cbitmask(NewGroup) of
        0 ->
            inc_cleanups(State#state.group, Time, Count);
        _ ->
            ?inc_cleanup_stops(State#state.group)
        end,
        State#state{
            group = NewGroup,
            cleaner_pid = nil,
            commit_ref = schedule_commit(State)
        };
    {'EXIT', Pid, Reason} ->
        exit({cleanup_process_died, Reason})
    end.


cleaner(#state{group = Group}) ->
    #set_view_group{
        index_header = Header,
        views = Views,
        id_btree = IdBtree
    } = Group,
    ok = couch_set_view_util:open_raw_read_fd(Group),
    StartTime = os:timestamp(),
    PurgeFun = couch_set_view_util:make_btree_purge_fun(Group),
    {ok, NewIdBtree, {Go, IdPurgedCount}} =
        couch_btree:guided_purge(IdBtree, PurgeFun, {go, 0}),
    {TotalPurgedCount, NewViews} = case Go of
    go ->
        clean_views(go, PurgeFun, Views, IdPurgedCount, []);
    stop ->
        {IdPurgedCount, Views}
    end,
    ok = couch_set_view_util:close_raw_read_fd(Group),
    {ok, {_, IdBitmap}} = couch_btree:full_reduce(NewIdBtree),
    CombinedBitmap = lists:foldl(
        fun(#set_view{btree = Bt}, AccMap) ->
            {ok, {_, _, Bm}} = couch_btree:full_reduce(Bt),
            AccMap bor Bm
        end,
        IdBitmap, NewViews),
    NewCbitmask = ?set_cbitmask(Group) band CombinedBitmap,
    NewGroup = Group#set_view_group{
        id_btree = NewIdBtree,
        views = NewViews,
        index_header = Header#set_view_index_header{cbitmask = NewCbitmask}
    },
    Duration = timer:now_diff(os:timestamp(), StartTime) / 1000000,
    commit_header(NewGroup, true),
    {clean_group, NewGroup, TotalPurgedCount, Duration}.


clean_views(_, _, [], Count, Acc) ->
    {Count, lists:reverse(Acc)};
clean_views(stop, _, Rest, Count, Acc) ->
    {Count, lists:reverse(Acc, Rest)};
clean_views(go, PurgeFun, [#set_view{btree = Btree} = View | Rest], Count, Acc) ->
    couch_set_view_mapreduce:start_reduce_context(View),
    {ok, NewBtree, {Go, PurgedCount}} =
        couch_btree:guided_purge(Btree, PurgeFun, {go, Count}),
    couch_set_view_mapreduce:end_reduce_context(View),
    NewAcc = [View#set_view{btree = NewBtree} | Acc],
    clean_views(Go, PurgeFun, Rest, PurgedCount, NewAcc).


index_needs_update(#state{group = Group} = State) ->
    {ok, CurSeqs} = couch_db_set:get_seqs(?db_set(State)),
    CurSeqs > ?set_seqs(Group).


make_partition_lists(Group) ->
    make_partition_lists(?set_seqs(Group), ?set_abitmask(Group), ?set_pbitmask(Group), [], []).

make_partition_lists([], _Abitmask, _Pbitmask, Active, Passive) ->
    {lists:reverse(Active), lists:reverse(Passive)};
make_partition_lists([{PartId, _} | Rest], Abitmask, Pbitmask, Active, Passive) ->
    Mask = 1 bsl PartId,
    case Mask band Abitmask of
    0 ->
        Mask = Mask band Pbitmask,
        make_partition_lists(Rest, Abitmask, Pbitmask, Active, [PartId | Passive]);
    Mask ->
        make_partition_lists(Rest, Abitmask, Pbitmask, [PartId | Active], Passive)
    end.


start_compactor(State, CompactFun) ->
    #state{group = Group} = State2 = stop_cleaner(State),
    ?LOG_INFO("Set view `~s`, ~s group `~s`, compaction starting",
              [?set_name(State2), ?type(State), ?group_id(State2)]),
    #set_view_group{
        fd = CompactFd
    } = NewGroup = compact_group(State2),
    Pid = spawn_link(fun() ->
        CompactFun(Group, NewGroup)
    end),
    State2#state{
        compactor_pid = Pid,
        compactor_fun = CompactFun,
        compactor_file = CompactFd
    }.


restart_compactor(#state{compactor_pid = nil} = State, _Reason) ->
    State;
restart_compactor(#state{compactor_pid = Pid, compactor_file = CompactFd} = State, Reason) ->
    ?LOG_INFO("Restarting compaction for ~s group `~s`, set view `~s`. Reason: ~s",
        [?type(State), ?group_id(State), ?set_name(State), Reason]),
    couch_util:shutdown_sync(Pid),
    couch_util:shutdown_sync(CompactFd),
    case ?set_cbitmask(State#state.group) of
    0 ->
        ok;
    _ ->
        ?inc_cleanup_stops(State#state.group)
    end,
    start_compactor(State, State#state.compactor_fun).


compact_group(#state{group = Group} = State) ->
    CompactFilepath = compact_file_name(State),
    {ok, Fd} = open_index_file(CompactFilepath),
    reset_file(Fd, ?set_name(State), Group#set_view_group{filepath = CompactFilepath}).


stop_updater(State) ->
    stop_updater(State, after_active_indexed).

stop_updater(#state{updater_pid = nil} = State, _When) ->
    State;
stop_updater(#state{updater_pid = Pid} = State, When) ->
    case When of
    after_active_indexed ->
        Pid ! stop_after_active,
        ?LOG_INFO("Stopping updater for set view `~s`, ~s group `~s`, as soon "
            "as all active partitions are processed",
            [?set_name(State), ?type(State), ?group_id(State)]);
    immediately ->
        Pid ! stop_immediately,
        ?LOG_INFO("Stopping updater for set view `~s`, ~s group `~s`, immediately",
            [?set_name(State), ?type(State), ?group_id(State)])
    end,
    receive
    {'EXIT', Pid, {updater_finished, Result}} ->
        #set_view_updater_result{
            group = NewGroup,
            state = UpdaterFinishState,
            indexing_time = IndexingTime,
            blocked_time = BlockedTime,
            inserted_ids = InsertedIds,
            deleted_ids = DeletedIds,
            inserted_kvs = InsertedKVs,
            deleted_kvs = DeletedKVs,
            cleanup_kv_count = CleanupKVCount
        } = Result,
        ?LOG_INFO("Set view `~s`, ~s group `~s`, updater stopped~n"
            "Indexing time: ~.3f seconds~n"
            "Blocked time:  ~.3f seconds~n"
            "Inserted IDs:  ~p~n"
            "Deleted IDs:   ~p~n"
            "Inserted KVs:  ~p~n"
            "Deleted KVs:   ~p~n"
            "Cleaned KVs:   ~p~n",
            [?set_name(State), ?type(State), ?group_id(State), IndexingTime, BlockedTime,
                InsertedIds, DeletedIds, InsertedKVs, DeletedKVs, CleanupKVCount]),
        State2 = process_partial_update(State, NewGroup),
        case UpdaterFinishState of
        updating_active ->
            inc_updates(State2#state.group, Result, true, true),
            WaitingList2 = State2#state.waiting_list;
        updating_passive ->
            PartialUpdate = (?set_pbitmask(NewGroup) =/= 0),
            inc_updates(State2#state.group, Result, PartialUpdate, false),
            reply_with_group(
                NewGroup, State2#state.replica_partitions, State2#state.waiting_list),
            WaitingList2 = []
        end,
        State2#state{
            updater_pid = nil,
            updater_state = not_running,
            waiting_list = WaitingList2
        };
    {'EXIT', Pid, Reason} ->
        Reply = case Reason of
        {updater_error, _} ->
            {error, element(2, Reason)};
        _ ->
            {error, Reason}
        end,
        ?LOG_ERROR("Updater, set view `~s`, ~s group `~s`, died with "
            "unexpected reason: ~p",
            [?set_name(State), ?type(State), ?group_id(State), Reason]),
        NewState = State#state{
            updater_pid = nil,
            updater_state = not_running
        },
        ?inc_updater_errors(NewState#state.group),
        reply_all(NewState, Reply)
    end.


start_updater(#state{updater_pid = Pid} = State) when is_pid(Pid) ->
    State;
start_updater(#state{updater_pid = nil, updater_state = not_running} = State) ->
    #state{
        group = Group,
        replica_partitions = ReplicaParts,
        waiting_list = WaitList
    } = State,
    case index_needs_update(State) of
    true ->
        do_start_updater(State);
    false ->
        case State#state.waiting_list of
        [] ->
            State;
        _ ->
            reply_with_group(Group, ReplicaParts, WaitList),
            State#state{waiting_list = []}
        end
    end.


do_start_updater(State) ->
    #state{group = Group} = State2 = stop_cleaner(State),
    ?LOG_INFO("Starting updater for set view `~s`, ~s group `~s`",
        [?set_name(State), ?type(State), ?group_id(State)]),
    Pid = spawn_link(couch_set_view_updater, update, [self(), Group]),
    State2#state{
        updater_pid = Pid,
        updater_state = starting
    }.


partitions_still_in_cleanup(Parts, Group) ->
    partitions_still_in_cleanup(Parts, Group, []).

partitions_still_in_cleanup([], _Group, Acc) ->
    lists:reverse(Acc);
partitions_still_in_cleanup([PartId | Rest], Group, Acc) ->
    Mask = 1 bsl PartId,
    case Mask band ?set_cbitmask(Group) of
    Mask ->
        partitions_still_in_cleanup(Rest, Group, [PartId | Acc]);
    0 ->
        partitions_still_in_cleanup(Rest, Group, Acc)
    end.


open_replica_group({RootDir, SetName, Group} = _InitArgs) ->
    ReplicaArgs = {RootDir, SetName, Group#set_view_group{type = replica}},
    {ok, Pid} = proc_lib:start_link(?MODULE, init, [ReplicaArgs]),
    Pid.


get_replica_partitions(ReplicaPid) ->
    {ok, Group} = gen_server:call(ReplicaPid, request_group, infinity),
    ordsets:from_list(couch_set_view_util:decode_bitmask(
        ?set_abitmask(Group) bor ?set_pbitmask(Group))).


maybe_update_replica_index(#state{updater_pid = Pid} = State) when is_pid(Pid) ->
    State;
maybe_update_replica_index(#state{group = Group, updater_state = not_running} = State) ->
    {ok, CurSeqs} = couch_db_set:get_seqs(?db_set(State)),
    ChangesCount = lists:foldl(
        fun({{PartId, CurSeq}, {PartId, UpSeq}}, Acc) when CurSeq >= UpSeq ->
            Acc + (CurSeq - UpSeq)
        end,
        0, lists:zip(CurSeqs, ?set_seqs(Group))),
    case (ChangesCount >= ?MIN_CHANGES_AUTO_UPDATE) orelse
        (ChangesCount > 0 andalso ?set_cbitmask(Group) =/= 0) of
    true ->
        do_start_updater(State);
    false ->
        maybe_start_cleaner(State)
    end.


maybe_fix_replica_group(ReplicaPid, Group) ->
    {ok, RepGroup} = gen_server:call(ReplicaPid, request_group, infinity),
    RepGroupActive = couch_set_view_util:decode_bitmask(?set_abitmask(RepGroup)),
    RepGroupPassive = couch_set_view_util:decode_bitmask(?set_pbitmask(RepGroup)),
    CleanupList = lists:foldl(
        fun(PartId, Acc) ->
            case ordsets:is_element(PartId, ?set_replicas_on_transfer(Group)) of
            true ->
                Acc;
            false ->
                [PartId | Acc]
            end
        end,
        [], RepGroupActive),
    ActiveList = lists:foldl(
        fun(PartId, Acc) ->
            case ordsets:is_element(PartId, ?set_replicas_on_transfer(Group)) of
            true ->
                [PartId | Acc];
            false ->
                Acc
            end
        end,
        [], RepGroupPassive),
    ok = set_state(ReplicaPid, ActiveList, [], CleanupList).


schedule_commit(#state{commit_ref = Ref}) when is_reference(Ref) ->
    Ref;
schedule_commit(_State) ->
    erlang:send_after(?DELAYED_COMMIT_PERIOD, self(), delayed_commit).


cancel_commit(#state{commit_ref = Ref}) when is_reference(Ref) ->
    erlang:cancel_timer(Ref);
cancel_commit(_State) ->
    ok.


process_partial_update(#state{group = Group} = State, NewGroup) ->
    ReplicasTransferred = ordsets:subtract(
        ?set_replicas_on_transfer(Group), ?set_replicas_on_transfer(NewGroup)),
    case ReplicasTransferred of
    [] ->
        CommitRef2 = schedule_commit(State);
    _ ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, completed transferral of replica partitions ~w~n"
                  "New group of replica partitions to transfer is ~w~n",
                  [?set_name(State), ?type(State), ?group_id(State),
                   ReplicasTransferred, ?set_replicas_on_transfer(NewGroup)]),
        commit_header(NewGroup, true),
        ok = set_state(State#state.replica_group, [], [], ReplicasTransferred),
        cancel_commit(State),
        CommitRef2 = nil
    end,
    State#state{
        group = NewGroup,
        commit_ref = CommitRef2,
        replica_partitions = ordsets:subtract(State#state.replica_partitions, ReplicasTransferred)
    }.


inc_updates(Group, UpdaterResult) ->
    inc_updates(Group, UpdaterResult, false, false).

inc_updates(Group, UpdaterResult, PartialUpdate, ForcedStop) ->
    [Stats] = ets:lookup(?SET_VIEW_STATS_ETS, ?set_view_group_stats_key(Group)),
    #set_view_group_stats{update_history = Hist} = Stats,
    #set_view_updater_result{
        indexing_time = IndexingTime,
        blocked_time = BlockedTime,
        cleanup_kv_count = CleanupKvCount,
        cleanup_time = CleanupTime,
        inserted_ids = InsertedIds,
        deleted_ids = DeletedIds,
        inserted_kvs = InsertedKvs,
        deleted_kvs = DeletedKvs
    } = UpdaterResult,
    Entry = {
        case PartialUpdate of
        true ->
            [{<<"partial_update">>, true}];
        false ->
            []
        end ++
        case ForcedStop of
        true ->
            [{<<"forced_stop">>, true}];
        false ->
            []
        end ++ [
        {<<"indexing_time">>, IndexingTime},
        {<<"blocked_time">>, BlockedTime},
        {<<"cleanup_kv_count">>, CleanupKvCount},
        {<<"inserted_ids">>, InsertedIds},
        {<<"deleted_ids">>, DeletedIds},
        {<<"inserted_kvs">>, InsertedKvs},
        {<<"deleted_kvs">>, DeletedKvs}
    ]},
    Stats2 = Stats#set_view_group_stats{
        update_history = lists:sublist([Entry | Hist], ?MAX_HIST_SIZE),
        partial_updates = case PartialUpdate of
            true  -> Stats#set_view_group_stats.partial_updates + 1;
            false -> Stats#set_view_group_stats.partial_updates
            end,
        stopped_updates = case ForcedStop of
            true  -> Stats#set_view_group_stats.stopped_updates + 1;
            false -> Stats#set_view_group_stats.stopped_updates
            end,
        full_updates = case (not PartialUpdate) andalso (not ForcedStop) of
            true  -> Stats#set_view_group_stats.full_updates + 1;
            false -> Stats#set_view_group_stats.full_updates
            end
    },
    case CleanupKvCount > 0 of
    true ->
        inc_cleanups(Stats2, CleanupTime, CleanupKvCount, true);
    false ->
        true = ets:insert(?SET_VIEW_STATS_ETS, Stats2)
    end.


inc_cleanups(Group, Duration, Count) when is_record(Group, set_view_group) ->
    [Stats] = ets:lookup(?SET_VIEW_STATS_ETS, ?set_view_group_stats_key(Group)),
    inc_cleanups(Stats, Duration, Count, false);

inc_cleanups(Stats, Duration, Count) ->
    inc_cleanups(Stats, Duration, Count, false).

inc_cleanups(#set_view_group_stats{cleanup_history = Hist} = Stats, Duration, Count, ByUpdater) ->
    Entry = {[
        {<<"duration">>, Duration},
        {<<"kv_count">>, Count}
    ]},
    Stats2 = Stats#set_view_group_stats{
        cleanups = Stats#set_view_group_stats.cleanups + 1,
        cleanup_history = lists:sublist([Entry | Hist], ?MAX_HIST_SIZE),
        updater_cleanups = case ByUpdater of
            true ->
                Stats#set_view_group_stats.updater_cleanups + 1;
            false ->
                Stats#set_view_group_stats.updater_cleanups
            end
    },
    true = ets:insert(?SET_VIEW_STATS_ETS, Stats2).


inc_compactions(Group, Result) ->
    [Stats] = ets:lookup(?SET_VIEW_STATS_ETS, ?set_view_group_stats_key(Group)),
    #set_view_group_stats{compaction_history = Hist} = Stats,
    #set_view_compactor_result{
        compact_time = Duration,
        cleanup_kv_count = CleanupKVCount
    } = Result,
    Entry = {[
        {<<"duration">>, Duration},
        {<<"cleanup_kv_count">>, CleanupKVCount}
    ]},
    Stats2 = Stats#set_view_group_stats{
        compactions = Stats#set_view_group_stats.compactions + 1,
        compaction_history = lists:sublist([Entry | Hist], ?MAX_HIST_SIZE),
        cleanups = case CleanupKVCount of
            0 ->
                Stats#set_view_group_stats.cleanups;
            _ ->
                Stats#set_view_group_stats.cleanups + 1
        end
    },
    true = ets:insert(?SET_VIEW_STATS_ETS, Stats2).


new_fd_ref_counter(Fd) ->
    {ok, RefCounter} = couch_ref_counter:start([Fd]),
    RefCounter.


drop_fd_ref_counter(RefCounter) ->
    couch_ref_counter:drop(RefCounter).


inc_view_group_access_stats(#set_view_group_req{update_stats = true}, Group) ->
    ?inc_accesses(Group);
inc_view_group_access_stats(_Req, _Group) ->
    ok.


get_pending_transition(#state{group = Group}) ->
    get_pending_transition(Group);
get_pending_transition(#set_view_group{index_header = Header}) ->
    Header#set_view_index_header.pending_transition.


set_pending_transition(#state{group = Group} = State, Transition) ->
    #set_view_group{index_header = IndexHeader} = Group,
    IndexHeader2 = IndexHeader#set_view_index_header{
        pending_transition = Transition
    },
    Group2 = Group#set_view_group{index_header = IndexHeader2},
    State#state{group = Group2}.


is_any_partition_pending(Req, Group) ->
    #set_view_group_req{wanted_partitions = WantedPartitions} = Req,
    case get_pending_transition(Group) of
    nil ->
        false;
    Trans ->
        #set_view_transition{
            active = ActivePending,
            passive = PassivePending
        } = Trans,
        (not ordsets:is_disjoint(WantedPartitions, ActivePending)) orelse
        (not ordsets:is_disjoint(WantedPartitions, PassivePending))
    end.


process_view_group_request(#set_view_group_req{stale = false}, From, State) ->
    #state{
        group = Group,
        updater_pid = UpPid,
        updater_state = UpState,
        waiting_list = WaitList,
        replica_partitions = ReplicaParts
    } = State,
    case UpPid of
    nil ->
        start_updater(State#state{waiting_list = [From | WaitList]});
    _ when is_pid(UpPid), UpState =:= updating_passive ->
        reply_with_group(Group, ReplicaParts, [From]),
        State;
    _ when is_pid(UpPid) ->
        State#state{waiting_list = [From | WaitList]}
    end;

process_view_group_request(#set_view_group_req{stale = ok}, From, State) ->
    #state{
        group = Group,
        replica_partitions = ReplicaParts
    } = State,
    reply_with_group(Group, ReplicaParts, [From]),
    State;

process_view_group_request(#set_view_group_req{stale = update_after}, From, State) ->
    #state{
        group = Group,
        replica_partitions = ReplicaParts
    } = State,
    reply_with_group(Group, ReplicaParts, [From]),
    case State#state.updater_pid of
    Pid when is_pid(Pid) ->
        State;
    nil ->
        start_updater(State)
    end.
