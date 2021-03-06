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

-module(couch_replicator).
-behaviour(gen_server).

% public API
-export([replicate/1]).

% meant to be used only by the replicator database listener
-export([async_replicate/1]).
-export([cancel_replication/1]).

% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-include("couch_db.hrl").
-include("couch_api_wrap.hrl").
-include("couch_replicator.hrl").

-import(couch_util, [
    get_value/2,
    get_value/3,
    to_binary/1
]).

-import(couch_replicator_utils, [
    start_db_compaction_notifier/2,
    stop_db_compaction_notifier/1
]).

-record(rep_state, {
    rep_details,
    source_name,
    target_name,
    source,
    target,
    history,
    checkpoint_history,
    start_seq,
    committed_seq,
    current_through_seq,
    seqs_in_progress = [],
    highest_seq_done = ?LOWEST_SEQ,
    source_log,
    target_log,
    rep_starttime,
    src_starttime,
    tgt_starttime,
    timer, % checkpoint timer
    missing_revs_queue,
    changes_queue,
    changes_reader,
    missing_rev_finders,
    workers,
    stats = #rep_stats{},
    session_id,
    source_db_compaction_notifier = nil,
    target_db_compaction_notifier = nil,
    source_monitor = nil,
    target_monitor = nil
}).


replicate(#rep{id = RepId, options = Options} = Rep) ->
    case get_value(cancel, Options, false) of
    true ->
        cancel_replication(RepId);
    false ->
        {ok, Listener} = rep_result_listener(RepId),
        Result = do_replication_loop(Rep),
        couch_replication_notifier:stop(Listener),
        Result
    end.


do_replication_loop(#rep{id = {BaseId,_} = Id, options = Options} = Rep) ->
    case async_replicate(Rep) of
    {ok, _Pid} ->
        case get_value(continuous, Options, false) of
        true ->
            {ok, {continuous, ?l2b(BaseId)}};
        false ->
            wait_for_result(Id)
        end;
    Error ->
        Error
    end.


async_replicate(#rep{id = {BaseId, Ext}, source = Src, target = Tgt} = Rep) ->
    RepChildId = BaseId ++ Ext,
    Source = couch_api_wrap:db_uri(Src),
    Target = couch_api_wrap:db_uri(Tgt),
    ChildSpec = {
        RepChildId,
        {gen_server, start_link, [?MODULE, Rep, []]},
        temporary,
        1,
        worker,
        [?MODULE]
    },
    % All these nested cases to attempt starting/restarting a replication child
    % are ugly and not 100% race condition free. The following patch submission
    % is a solution:
    %
    % http://erlang.2086793.n4.nabble.com/PATCH-supervisor-atomically-delete-child-spec-when-child-terminates-td3226098.html
    %
    case supervisor:start_child(couch_rep_sup, ChildSpec) of
    {ok, Pid} ->
        ?LOG_INFO("starting new replication `~s` at ~p (`~s` -> `~s`)",
            [RepChildId, Pid, Source, Target]),
        {ok, Pid};
    {error, already_present} ->
        case supervisor:restart_child(couch_rep_sup, RepChildId) of
        {ok, Pid} ->
            ?LOG_INFO("restarting replication `~s` at ~p (`~s` -> `~s`)",
                [RepChildId, Pid, Source, Target]),
            {ok, Pid};
        {error, running} ->
            %% this error occurs if multiple replicators are racing
            %% each other to start and somebody else won. Just grab
            %% the Pid by calling start_child again.
            {error, {already_started, Pid}} =
                supervisor:start_child(couch_rep_sup, ChildSpec),
            ?LOG_INFO("replication `~s` already running at ~p (`~s` -> `~s`)",
                [RepChildId, Pid, Source, Target]),
            {ok, Pid};
        {error, {'EXIT', {badarg,
            [{erlang, apply, [gen_server, start_link, undefined]} | _]}}} ->
            % Clause to deal with a change in the supervisor module introduced
            % in R14B02. For more details consult the thread at:
            %     http://erlang.org/pipermail/erlang-bugs/2011-March/002273.html
            _ = supervisor:delete_child(couch_rep_sup, RepChildId),
            async_replicate(Rep);
        {error, _} = Error ->
            Error
        end;
    {error, {already_started, Pid}} ->
        ?LOG_INFO("replication `~s` already running at ~p (`~s` -> `~s`)",
            [RepChildId, Pid, Source, Target]),
        {ok, Pid};
    {error, {Error, _}} ->
        {error, Error}
    end.


rep_result_listener(RepId) ->
    ReplyTo = self(),
    {ok, _Listener} = couch_replication_notifier:start_link(
        fun({_, RepId2, _} = Ev) when RepId2 =:= RepId ->
                ReplyTo ! Ev;
            (_) ->
                ok
        end).


wait_for_result(RepId) ->
    receive
    {finished, RepId, RepResult} ->
        {ok, RepResult};
    {error, RepId, Reason} ->
        {error, Reason}
    end.


cancel_replication({BaseId, Extension}) ->
    FullRepId = BaseId ++ Extension,
    case supervisor:terminate_child(couch_rep_sup, FullRepId) of
    ok ->
        ok = supervisor:delete_child(couch_rep_sup, FullRepId),
        {ok, {cancelled, ?l2b(BaseId)}};
    Error ->
        Error
    end.


init(InitArgs) ->
    try
        do_init(InitArgs)
    catch
    throw:{unauthorized, DbUri} ->
        {stop, {unauthorized,
            <<"unauthorized to access database ", DbUri/binary>>}};
    throw:{db_not_found, DbUri} ->
        {stop, {db_not_found, <<"could not open ", DbUri/binary>>}};
    throw:Error ->
        {stop, Error}
    end.

do_init(#rep{options = Options, id = {BaseId, Ext}} = Rep) ->
    process_flag(trap_exit, true),

    #rep_state{
        source = Source,
        target = Target,
        source_name = SourceName,
        target_name = TargetName,
        start_seq = StartSeq
    } = State = init_state(Rep),

    CopiersCount = get_value(worker_processes, Options),
    RevFindersCount = CopiersCount,
    BatchSize = get_value(worker_batch_size, Options),
    {ok, MissingRevsQueue} = couch_work_queue:new([
        {multi_workers, true},
        {max_items, trunc(CopiersCount * 2.0)}
    ]),
    {ok, ChangesQueue} = couch_work_queue:new([
        {multi_workers, true},
        {max_items, trunc(BatchSize * RevFindersCount * 2.0)}
    ]),
    % This starts the _changes reader process. It adds the changes from
    % the source db to the ChangesQueue.
    ChangesReader = spawn_changes_reader(
        StartSeq, Source, ChangesQueue, Options),
    % This starts the missing rev finders. They check the target for changes
    % in the ChangesQueue to see if they exist on the target or not. If not,
    % adds them to MissingRevsQueue.
    MissingRevFinders = lists:map(
        fun(_) ->
            {ok, Pid} = couch_replicator_rev_finder:start_link(
                self(), Target, ChangesQueue, MissingRevsQueue, BatchSize),
            Pid
        end,
        lists:seq(1, RevFindersCount)),
    % This starts the doc copy processes. They fetch documents from the
    % MissingRevsQueue and copy them from the source to the target database.
    MaxHttpConns = get_value(http_connections, Options),
    HttpPipeSize = get_value(http_pipeline_size, Options),
    MaxParallelConns = lists:max(
        [(MaxHttpConns * HttpPipeSize) div CopiersCount, 1]),
    Workers = lists:map(
        fun(_) ->
            {ok, Pid} = couch_replicator_doc_copier:start_link(
                self(), Source, Target, MissingRevsQueue, MaxParallelConns),
            Pid
        end,
        lists:seq(1, CopiersCount)),

    couch_task_status:add_task(
        "Replication",
         io_lib:format("`~s`: `~s` -> `~s`",
            [BaseId ++ Ext, SourceName, TargetName]), "Starting"),

    % Restarting a supervised child implies that the original arguments
    % (#rep{} record) specified in the MFA component of the supervisor
    % child spec will always be used whenever the child is restarted.
    % This implies the same replication performance tunning parameters will
    % always be used. See the following threads for details:
    %
    % http://www.erlang.org/cgi-bin/ezmlm-cgi?3:sss:1772:201012:kihiniifeclgnpodlipd#b
    % http://erlang.2086793.n4.nabble.com/PATCH-supervisor-atomically-delete-child-spec-when-child-terminates-td3226098.html
    %
    % The current solution is to delete the child spec (see cancel_replication/1)
    % and then start the replication again, but this is unfortunately not immune
    % to race conditions.

    ?LOG_INFO("Replication `~p` is using:~n"
        "~c~p worker processes~n"
        "~ca worker batch size of ~p~n"
        "~c~p HTTP connections, each with a pipeline size of ~p~n"
        "~ca connection timeout of ~p milliseconds~n"
        "~csocket options are: ~s",
        [BaseId ++ Ext, $\t, CopiersCount, $\t, BatchSize, $\t, MaxHttpConns,
            HttpPipeSize, $\t, get_value(connection_timeout, Options),
            $\t, io_lib:format("~p", [get_value(socket_options, Options)])]),

    ?LOG_DEBUG("Missing rev finder pids are: ~p", [MissingRevFinders]),
    ?LOG_DEBUG("Worker pids are: ~p", [Workers]),

    couch_replication_manager:replication_started(Rep),

    {ok, State#rep_state{
            missing_revs_queue = MissingRevsQueue,
            changes_queue = ChangesQueue,
            changes_reader = ChangesReader,
            missing_rev_finders = MissingRevFinders,
            workers = Workers
        }
    }.


handle_info({'DOWN', Ref, _, _, Why}, #rep_state{source_monitor = Ref} = St) ->
    ?LOG_ERROR("Source database is down. Reason: ~p", [Why]),
    {stop, source_db_down, St};

handle_info({'DOWN', Ref, _, _, Why}, #rep_state{target_monitor = Ref} = St) ->
    ?LOG_ERROR("Target database is down. Reason: ~p", [Why]),
    {stop, target_db_down, St};

handle_info({'EXIT', Pid, normal}, #rep_state{changes_reader=Pid} = State) ->
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #rep_state{changes_reader=Pid} = State) ->
    ?LOG_ERROR("ChangesReader process died with reason: ~p", [Reason]),
    {stop, changes_reader_died, cancel_timer(State)};

handle_info({'EXIT', Pid, normal}, #rep_state{missing_revs_queue=Pid} = St) ->
    {noreply, St};

handle_info({'EXIT', Pid, Reason}, #rep_state{missing_revs_queue=Pid} = St) ->
    ?LOG_ERROR("MissingRevsQueue process died with reason: ~p", [Reason]),
    {stop, missing_revs_queue_died, cancel_timer(St)};

handle_info({'EXIT', Pid, normal}, #rep_state{changes_queue=Pid} = State) ->
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #rep_state{changes_queue=Pid} = State) ->
    ?LOG_ERROR("ChangesQueue process died with reason: ~p", [Reason]),
    {stop, changes_queue_died, cancel_timer(State)};

handle_info({'EXIT', Pid, normal}, State) ->
    #rep_state{
        workers = Workers,
        missing_rev_finders = RevFinders,
        missing_revs_queue = RevsQueue
    } = State,
    case lists:member(Pid, RevFinders) of
    false ->
        case lists:member(Pid, Workers) of
        false ->
            {stop, {unknown_process_died, Pid, normal}, State};
        true ->
            case Workers -- [Pid] of
            [] ->
                do_last_checkpoint(State);
            Workers2 ->
                {noreply, State#rep_state{workers = Workers2}}
            end
        end;
    true ->
        case RevFinders -- [Pid] of
        [] ->
            couch_work_queue:close(RevsQueue),
            {noreply, State#rep_state{missing_rev_finders = []}};
        RevFinders2 ->
            {noreply, State#rep_state{missing_rev_finders = RevFinders2}}
        end
    end;

handle_info({'EXIT', Pid, Reason}, State) ->
    #rep_state{
        workers = Workers,
        missing_rev_finders = RevFinders
    } = State,
    State2 = cancel_timer(State),
    case lists:member(Pid, Workers) of
    false ->
        case lists:member(Pid, RevFinders) of
        false ->
            {stop, {unknown_process_died, Pid, Reason}, State2};
        true ->
            ?LOG_ERROR("RevsFinder ~p died with reason: ~p", [Pid, Reason]),
            {stop, {revs_finder_died, Pid, Reason}, State2}
        end;
    true ->
        ?LOG_ERROR("DocCopier ~p died with reason: ~p", [Pid, Reason]),
        {stop, {doc_copier_died, Pid, Reason}, State2}
    end.


handle_call(Msg, _From, State) ->
    ?LOG_ERROR("Replicator received an unexpected synchronous call: ~p", [Msg]),
    {stop, unexpected_sync_message, State}.


handle_cast({db_compacted, DbName},
    #rep_state{source = #db{name = DbName} = Source} = State) ->
    {ok, NewSource} = couch_db:reopen(Source),
    {noreply, State#rep_state{source = NewSource}};

handle_cast({db_compacted, DbName},
    #rep_state{target = #db{name = DbName} = Target} = State) ->
    {ok, NewTarget} = couch_db:reopen(Target),
    {noreply, State#rep_state{target = NewTarget}};

handle_cast(checkpoint, State) ->
    case do_checkpoint(State) of
    {ok, NewState} ->
        {noreply, NewState#rep_state{timer = start_timer(State)}};
    Error ->
        {stop, Error, State}
    end;

handle_cast({report_seq, Seq},
    #rep_state{seqs_in_progress = SeqsInProgress} = State) ->
    NewSeqsInProgress = ordsets:add_element(Seq, SeqsInProgress),
    {noreply, State#rep_state{seqs_in_progress = NewSeqsInProgress}};

handle_cast({report_seq_done, Seq, StatsInc},
    #rep_state{seqs_in_progress = SeqsInProgress, highest_seq_done = HighestDone,
        current_through_seq = ThroughSeq, stats = Stats} = State) ->
    {NewThroughSeq0, NewSeqsInProgress} = case SeqsInProgress of
    [Seq | Rest] ->
        {Seq, Rest};
    [_ | _] ->
        {ThroughSeq, ordsets:del_element(Seq, SeqsInProgress)}
    end,
    NewHighestDone = lists:max([HighestDone, Seq]),
    NewThroughSeq = case NewSeqsInProgress of
    [] ->
        lists:max([NewThroughSeq0, NewHighestDone]);
    _ ->
        NewThroughSeq0
    end,
    ?LOG_DEBUG("Worker reported seq ~p, through seq was ~p, "
        "new through seq is ~p, highest seq done was ~p, "
        "new highest seq done is ~p~n"
        "Seqs in progress were: ~p~nSeqs in progress are now: ~p",
        [Seq, ThroughSeq, NewThroughSeq, HighestDone,
            NewHighestDone, SeqsInProgress, NewSeqsInProgress]),
    case NewThroughSeq of
    ThroughSeq ->
        ok;
    _ ->
        couch_task_status:update("Processed source seq ~p", [NewThroughSeq])
    end,
    NewState = State#rep_state{
        stats = sum_stats([Stats, StatsInc]),
        current_through_seq = NewThroughSeq,
        seqs_in_progress = NewSeqsInProgress,
        highest_seq_done = NewHighestDone
    },
    {noreply, NewState};

handle_cast({add_stats, StatsInc}, #rep_state{stats = Stats} = State) ->
    {noreply, State#rep_state{stats = sum_stats([Stats, StatsInc])}};

handle_cast(Msg, State) ->
    ?LOG_ERROR("Replicator received an unexpected asynchronous call: ~p", [Msg]),
    {stop, unexpected_async_message, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


terminate(normal, #rep_state{rep_details = #rep{id = RepId} = Rep,
    checkpoint_history = CheckpointHistory} = State) ->
    terminate_cleanup(State),
    couch_replication_notifier:notify({finished, RepId, CheckpointHistory}),
    couch_replication_manager:replication_completed(Rep);

terminate(shutdown, State) ->
    % cancelled replication throught ?MODULE:cancel_replication/1
    terminate_cleanup(State);

terminate(Reason, State) ->
    #rep_state{
        source_name = Source,
        target_name = Target,
        rep_details = #rep{id = {BaseId, Ext} = RepId} = Rep
    } = State,
    ?LOG_ERROR("Replication `~s` (`~s` -> `~s`) failed: ~s",
        [BaseId ++ Ext, Source, Target, to_binary(Reason)]),
    terminate_cleanup(State),
    couch_replication_notifier:notify({error, RepId, Reason}),
    couch_replication_manager:replication_error(Rep, Reason).


terminate_cleanup(State) ->
    couch_task_status:update("Finishing"),
    stop_db_compaction_notifier(State#rep_state.source_db_compaction_notifier),
    stop_db_compaction_notifier(State#rep_state.target_db_compaction_notifier),
    couch_api_wrap:db_close(State#rep_state.source),
    couch_api_wrap:db_close(State#rep_state.target).


do_last_checkpoint(#rep_state{seqs_in_progress = [],
    highest_seq_done = ?LOWEST_SEQ} = State) ->
    {stop, normal, cancel_timer(State)};
do_last_checkpoint(#rep_state{seqs_in_progress = [],
    highest_seq_done = Seq} = State) ->
    case do_checkpoint(State#rep_state{current_through_seq = Seq}) of
    {ok, NewState} ->
        {stop, normal, cancel_timer(NewState)};
    Error ->
        {stop, Error, State}
    end.


start_timer(State) ->
    After = checkpoint_interval(State),
    case timer:apply_after(After, gen_server, cast, [self(), checkpoint]) of
    {ok, Ref} ->
        Ref;
    Error ->
        ?LOG_ERROR("Replicator, error scheduling checkpoint:  ~p", [Error]),
        nil
    end.


cancel_timer(#rep_state{timer = nil} = State) ->
    State;
cancel_timer(#rep_state{timer = Timer} = State) ->
    {ok, cancel} = timer:cancel(Timer),
    State#rep_state{timer = nil}.


init_state(Rep) ->
    #rep{
        source = Src, target = Tgt,
        options = Options, user_ctx = UserCtx
    } = Rep,
    {ok, Source} = couch_api_wrap:db_open(Src, [{user_ctx, UserCtx}]),
    {ok, Target} = couch_api_wrap:db_open(Tgt, [{user_ctx, UserCtx}],
        get_value(create_target, Options, false)),

    {ok, SourceInfo} = couch_api_wrap:get_db_info(Source),
    {ok, TargetInfo} = couch_api_wrap:get_db_info(Target),

    [SourceLog, TargetLog] = find_replication_logs([Source, Target], Rep),

    {StartSeq, History} = compare_replication_logs(SourceLog, TargetLog),
    #doc{body={CheckpointHistory}} = SourceLog,
    State = #rep_state{
        rep_details = Rep,
        source_name = couch_api_wrap:db_uri(Source),
        target_name = couch_api_wrap:db_uri(Target),
        source = Source,
        target = Target,
        history = History,
        checkpoint_history = {[{<<"no_changes">>, true}| CheckpointHistory]},
        start_seq = StartSeq,
        current_through_seq = StartSeq,
        committed_seq = StartSeq,
        source_log = SourceLog,
        target_log = TargetLog,
        rep_starttime = httpd_util:rfc1123_date(),
        src_starttime = get_value(<<"instance_start_time">>, SourceInfo),
        tgt_starttime = get_value(<<"instance_start_time">>, TargetInfo),
        session_id = couch_uuids:random(),
        source_db_compaction_notifier =
            start_db_compaction_notifier(Source, self()),
        target_db_compaction_notifier =
            start_db_compaction_notifier(Target, self()),
        source_monitor = db_monitor(Source),
        target_monitor = db_monitor(Target)
    },
    State#rep_state{timer = start_timer(State)}.


find_replication_logs(DbList, #rep{id = {BaseId, _}} = Rep) ->
    LogId = ?l2b(?LOCAL_DOC_PREFIX ++ BaseId),
    fold_replication_logs(DbList, ?REP_ID_VERSION, LogId, LogId, Rep, []).


fold_replication_logs([], _Vsn, _LogId, _NewId, _Rep, Acc) ->
    lists:reverse(Acc);

fold_replication_logs([Db | Rest] = Dbs, Vsn, LogId, NewId, Rep, Acc) ->
    case couch_api_wrap:open_doc(Db, LogId, [ejson_body]) of
    {error, <<"not_found">>} when Vsn > 1 ->
        OldRepId = couch_replicator_utils:replication_id(Rep, Vsn - 1),
        fold_replication_logs(Dbs, Vsn - 1,
            ?l2b(?LOCAL_DOC_PREFIX ++ OldRepId), NewId, Rep, Acc);
    {error, <<"not_found">>} ->
        fold_replication_logs(
            Rest, ?REP_ID_VERSION, NewId, NewId, Rep, [#doc{id = NewId} | Acc]);
    {ok, Doc} when LogId =:= NewId ->
        fold_replication_logs(
            Rest, ?REP_ID_VERSION, NewId, NewId, Rep, [Doc | Acc]);
    {ok, Doc} ->
        MigratedLog = #doc{id = NewId, body = Doc#doc.body},
        fold_replication_logs(
            Rest, ?REP_ID_VERSION, NewId, NewId, Rep, [MigratedLog | Acc])
    end.


spawn_changes_reader(StartSeq, #httpdb{} = Db, ChangesQueue, Options) ->
    spawn_link(fun() ->
        put(last_seq, StartSeq),
        put(retries_left, Db#httpdb.retries),
        read_changes(StartSeq, Db#httpdb{retries = 0}, ChangesQueue, Options)
    end);
spawn_changes_reader(StartSeq, Db, ChangesQueue, Options) ->
    spawn_link(fun() -> read_changes(StartSeq, Db, ChangesQueue, Options) end).

read_changes(StartSeq, Db, ChangesQueue, Options) ->
    try
        couch_api_wrap:changes_since(Db, all_docs, StartSeq,
            fun(#doc_info{high_seq = Seq} = DocInfo) ->
                ok = couch_work_queue:queue(ChangesQueue, DocInfo),
                put(last_seq, Seq)
            end, Options),
        couch_work_queue:close(ChangesQueue)
    catch exit:{http_request_failed, _, _, _} = Error ->
        case get(retries_left) of
        N when N > 0 ->
            put(retries_left, N - 1),
            LastSeq = get(last_seq),
            Db2 = case LastSeq of
            StartSeq ->
                ?LOG_INFO("Retrying _changes request to source database ~s"
                    " with since=~p in ~p seconds",
                    [couch_api_wrap:db_uri(Db), LastSeq, Db#httpdb.wait / 1000]),
                ok = timer:sleep(Db#httpdb.wait),
                Db#httpdb{wait = 2 * Db#httpdb.wait};
            _ ->
                ?LOG_INFO("Retrying _changes request to source database ~s"
                    " with since=~p", [couch_api_wrap:db_uri(Db), LastSeq]),
                Db
            end,
            read_changes(LastSeq, Db2, ChangesQueue, Options);
        _ ->
            exit(Error)
        end
    end.


checkpoint_interval(_State) ->
    5000.

do_checkpoint(#rep_state{current_through_seq=Seq, committed_seq=Seq} = State) ->
    {ok, State};
do_checkpoint(State) ->
    #rep_state{
        source_name=SourceName,
        target_name=TargetName,
        source = Source,
        target = Target,
        history = OldHistory,
        start_seq = StartSeq,
        current_through_seq = NewSeq,
        source_log = SourceLog,
        target_log = TargetLog,
        rep_starttime = ReplicationStartTime,
        src_starttime = SrcInstanceStartTime,
        tgt_starttime = TgtInstanceStartTime,
        stats = Stats,
        rep_details = #rep{options = Options},
        session_id = SessionId
    } = State,
    case commit_to_both(Source, Target) of
    {source_error, Reason} ->
         {checkpoint_commit_failure,
             <<"Failure on source commit: ", (to_binary(Reason))/binary>>};
    {target_error, Reason} ->
         {checkpoint_commit_failure,
             <<"Failure on target commit: ", (to_binary(Reason))/binary>>};
    {SrcInstanceStartTime, TgtInstanceStartTime} ->
        ?LOG_INFO("recording a checkpoint for `~s` -> `~s` at source update_seq ~p",
            [SourceName, TargetName, NewSeq]),
        StartTime = ?l2b(ReplicationStartTime),
        EndTime = ?l2b(httpd_util:rfc1123_date()),
        NewHistoryEntry = {[
            {<<"session_id">>, SessionId},
            {<<"start_time">>, StartTime},
            {<<"end_time">>, EndTime},
            {<<"start_last_seq">>, StartSeq},
            {<<"end_last_seq">>, NewSeq},
            {<<"recorded_seq">>, NewSeq},
            {<<"missing_checked">>, Stats#rep_stats.missing_checked},
            {<<"missing_found">>, Stats#rep_stats.missing_found},
            {<<"docs_read">>, Stats#rep_stats.docs_read},
            {<<"docs_written">>, Stats#rep_stats.docs_written},
            {<<"doc_write_failures">>, Stats#rep_stats.doc_write_failures}
        ]},
        BaseHistory = [
            {<<"session_id">>, SessionId},
            {<<"source_last_seq">>, NewSeq},
            {<<"replication_id_version">>, ?REP_ID_VERSION}
        ] ++ case get_value(doc_ids, Options) of
        undefined ->
            [];
        _DocIds ->
            % backwards compatibility with the result of a replication by
            % doc IDs in versions 0.11.x and 1.0.x
            % TODO: deprecate (use same history format, simplify code)
            [
                {<<"start_time">>, StartTime},
                {<<"end_time">>, EndTime},
                {<<"docs_read">>, Stats#rep_stats.docs_read},
                {<<"docs_written">>, Stats#rep_stats.docs_written},
                {<<"doc_write_failures">>, Stats#rep_stats.doc_write_failures}
            ]
        end,
        % limit history to 50 entries
        NewRepHistory = {
            BaseHistory ++
            [{<<"history">>, lists:sublist([NewHistoryEntry | OldHistory], 50)}]
        },

        try
            {SrcRevPos, SrcRevId} = update_checkpoint(
                Source, SourceLog#doc{body = NewRepHistory}, source),
            {TgtRevPos, TgtRevId} = update_checkpoint(
                Target, TargetLog#doc{body = NewRepHistory}, target),
            NewState = State#rep_state{
                checkpoint_history = NewRepHistory,
                committed_seq = NewSeq,
                source_log = SourceLog#doc{revs={SrcRevPos, [SrcRevId]}},
                target_log = TargetLog#doc{revs={TgtRevPos, [TgtRevId]}}
            },
            {ok, NewState}
        catch throw:{checkpoint_commit_failure, _} = Failure ->
            Failure
        end;
    {SrcInstanceStartTime, _NewTgtInstanceStartTime} ->
        {checkpoint_commit_failure, <<"Target database out of sync. "
            "Try to increase max_dbs_open at the target's server.">>};
    {_NewSrcInstanceStartTime, TgtInstanceStartTime} ->
        {checkpoint_commit_failure, <<"Source database out of sync. "
            "Try to increase max_dbs_open at the source's server.">>};
    {_NewSrcInstanceStartTime, _NewTgtInstanceStartTime} ->
        {checkpoint_commit_failure, <<"Source and target databases out of "
            "sync. Try to increase max_dbs_open at both servers.">>}
    end.


update_checkpoint(Db, Doc, DbType) ->
    try
        update_checkpoint(Db, Doc)
    catch throw:{checkpoint_commit_failure, Reason} ->
        throw({checkpoint_commit_failure,
            <<"Error updating the ", (to_binary(DbType))/binary,
                " checkpoint document: ", (to_binary(Reason))/binary>>})
    end.

update_checkpoint(Db, Doc) ->
    try
        case couch_api_wrap:update_doc(Db, Doc, [delay_commit]) of
        {ok, PosRevId} ->
            PosRevId;
        {error, Reason} ->
            throw({checkpoint_commit_failure, Reason})
        end
    catch throw:conflict ->
        throw({checkpoint_commit_failure, conflict})
    end.


commit_to_both(Source, Target) ->
    % commit the src async
    ParentPid = self(),
    SrcCommitPid = spawn_link(
        fun() ->
            Result = (catch couch_api_wrap:ensure_full_commit(Source)),
            ParentPid ! {self(), Result}
        end),

    % commit tgt sync
    TargetResult = (catch couch_api_wrap:ensure_full_commit(Target)),

    SourceResult = receive
    {SrcCommitPid, Result} ->
        unlink(SrcCommitPid),
        receive {'EXIT', SrcCommitPid, _} -> ok after 0 -> ok end,
        Result;
    {'EXIT', SrcCommitPid, Reason} ->
        {error, Reason}
    end,
    case TargetResult of
    {ok, TargetStartTime} ->
        case SourceResult of
        {ok, SourceStartTime} ->
            {SourceStartTime, TargetStartTime};
        SourceError ->
            {source_error, SourceError}
        end;
    TargetError ->
        {target_error, TargetError}
    end.


compare_replication_logs(SrcDoc, TgtDoc) ->
    #doc{body={RepRecProps}} = SrcDoc,
    #doc{body={RepRecPropsTgt}} = TgtDoc,
    case get_value(<<"session_id">>, RepRecProps) ==
            get_value(<<"session_id">>, RepRecPropsTgt) of
    true ->
        % if the records have the same session id,
        % then we have a valid replication history
        OldSeqNum = get_value(<<"source_last_seq">>, RepRecProps, ?LOWEST_SEQ),
        OldHistory = get_value(<<"history">>, RepRecProps, []),
        {OldSeqNum, OldHistory};
    false ->
        SourceHistory = get_value(<<"history">>, RepRecProps, []),
        TargetHistory = get_value(<<"history">>, RepRecPropsTgt, []),
        ?LOG_INFO("Replication records differ. "
                "Scanning histories to find a common ancestor.", []),
        ?LOG_DEBUG("Record on source:~p~nRecord on target:~p~n",
                [RepRecProps, RepRecPropsTgt]),
        compare_rep_history(SourceHistory, TargetHistory)
    end.

compare_rep_history(S, T) when S =:= [] orelse T =:= [] ->
    ?LOG_INFO("no common ancestry -- performing full replication", []),
    {?LOWEST_SEQ, []};
compare_rep_history([{S} | SourceRest], [{T} | TargetRest] = Target) ->
    SourceId = get_value(<<"session_id">>, S),
    case has_session_id(SourceId, Target) of
    true ->
        RecordSeqNum = get_value(<<"recorded_seq">>, S, ?LOWEST_SEQ),
        ?LOG_INFO("found a common replication record with source_seq ~p",
            [RecordSeqNum]),
        {RecordSeqNum, SourceRest};
    false ->
        TargetId = get_value(<<"session_id">>, T),
        case has_session_id(TargetId, SourceRest) of
        true ->
            RecordSeqNum = get_value(<<"recorded_seq">>, T, ?LOWEST_SEQ),
            ?LOG_INFO("found a common replication record with source_seq ~p",
                [RecordSeqNum]),
            {RecordSeqNum, TargetRest};
        false ->
            compare_rep_history(SourceRest, TargetRest)
        end
    end.


has_session_id(_SessionId, []) ->
    false;
has_session_id(SessionId, [{Props} | Rest]) ->
    case get_value(<<"session_id">>, Props, nil) of
    SessionId ->
        true;
    _Else ->
        has_session_id(SessionId, Rest)
    end.


sum_stats([Stats1 | RestStats]) ->
    lists:foldl(
        fun(Stats, Acc) ->
            #rep_stats{
                missing_checked = Stats#rep_stats.missing_checked +
                    Acc#rep_stats.missing_checked,
                missing_found = Stats#rep_stats.missing_found +
                    Acc#rep_stats.missing_found,
                docs_read = Stats#rep_stats.docs_read + Acc#rep_stats.docs_read,
                docs_written = Stats#rep_stats.docs_written +
                    Acc#rep_stats.docs_written,
                doc_write_failures = Stats#rep_stats.doc_write_failures +
                    Acc#rep_stats.doc_write_failures
            }
        end,
        Stats1, RestStats).


db_monitor(#db{} = Db) ->
    couch_db:monitor(Db);
db_monitor(_HttpDb) ->
    nil.
