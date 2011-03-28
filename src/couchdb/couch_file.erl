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

-module(couch_file).
-behaviour(gen_server).

-include("couch_db.hrl").

-define(SIZE_BLOCK, 4096).

-record(file, {
    fd,
    writer = nil,
    real_eof = 0,
    eof = 0,
    pos_to_flush_req = dict:new(),
    pid_to_pos = dict:new()
}).

% public API
-export([open/1, open/2, close/1, bytes/1, flush/1, sync/1, truncate/2]).
-export([pread_term/2, pread_iolist/2, pread_binary/2]).
-export([append_binary/2, append_binary_md5/2]).
-export([append_term/2, append_term_md5/2]).
-export([write_header/2, read_header/1]).
-export([delete/2, delete/3, init_delete_dir/1]).

% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

%%----------------------------------------------------------------------
%% Args:   Valid Options are [create] and [create,overwrite].
%%  Files are opened in read/write mode.
%% Returns: On success, {ok, Fd}
%%  or {error, Reason} if the file could not be opened.
%%----------------------------------------------------------------------

open(Filepath) ->
    open(Filepath, []).

open(Filepath, Options) ->
    case gen_server:start_link(couch_file,
            {Filepath, Options, self(), Ref = make_ref()}, []) of
    {ok, Fd} ->
        {ok, Fd};
    ignore ->
        % get the error
        receive
        {Ref, Pid, Error} ->
            case process_info(self(), trap_exit) of
            {trap_exit, true} -> receive {'EXIT', Pid, _} -> ok end;
            {trap_exit, false} -> ok
            end,
            case Error of
            {error, eacces} -> {file_permission_error, Filepath};
            _ -> Error
            end
        end;
    Error ->
        Error
    end.


%%----------------------------------------------------------------------
%% Purpose: To append an Erlang term to the end of the file.
%% Args:    Erlang term to serialize and append to the file.
%% Returns: {ok, Pos} where Pos is the file offset to the beginning the
%%  serialized  term. Use pread_term to read the term back.
%%  or {error, Reason}.
%%----------------------------------------------------------------------

append_term(Fd, Term) ->
    append_binary(Fd, term_to_binary(Term)).
    
append_term_md5(Fd, Term) ->
    append_binary_md5(Fd, term_to_binary(Term)).


%%----------------------------------------------------------------------
%% Purpose: To append an Erlang binary to the end of the file.
%% Args:    Erlang term to serialize and append to the file.
%% Returns: {ok, Pos} where Pos is the file offset to the beginning the
%%  serialized  term. Use pread_term to read the term back.
%%  or {error, Reason}.
%%----------------------------------------------------------------------

append_binary(Fd, Bin) ->
    Size = iolist_size(Bin),
    gen_server:call(Fd, {append_bin,
            [<<0:1/integer,Size:31/integer>>, Bin]}, infinity).
    
append_binary_md5(Fd, Bin) ->
    Size = iolist_size(Bin),
    gen_server:call(Fd, {append_bin,
            [<<1:1/integer,Size:31/integer>>, couch_util:md5(Bin), Bin]}, infinity).


%%----------------------------------------------------------------------
%% Purpose: Reads a term from a file that was written with append_term
%% Args:    Pos, the offset into the file where the term is serialized.
%% Returns: {ok, Term}
%%  or {error, Reason}.
%%----------------------------------------------------------------------


pread_term(Fd, Pos) ->
    {ok, Bin} = pread_binary(Fd, Pos),
    {ok, binary_to_term(Bin)}.


%%----------------------------------------------------------------------
%% Purpose: Reads a binrary from a file that was written with append_binary
%% Args:    Pos, the offset into the file where the term is serialized.
%% Returns: {ok, Term}
%%  or {error, Reason}.
%%----------------------------------------------------------------------

pread_binary(Fd, Pos) ->
    {ok, L} = pread_iolist(Fd, Pos),
    {ok, iolist_to_binary(L)}.


pread_iolist(File, Pos) ->
    {ok, Fd} = gen_server:call(File, get_fd, infinity),
    {RawData, NextPos} = try
        % up to 8Kbs of read ahead
        read_raw_iolist_int(Fd, Pos, 2 * ?SIZE_BLOCK - (Pos rem ?SIZE_BLOCK))
    catch
    _:_ ->
        read_raw_iolist_int(Fd, Pos, 4)
    end,
    <<Prefix:1/integer, Len:31/integer, RestRawData/binary>> =
        iolist_to_binary(RawData),
    case Prefix of
    1 ->
        {Md5, IoList} = extract_md5(
            maybe_read_more_iolist(RestRawData, 16 + Len, NextPos, Fd)),
        case couch_util:md5(IoList) of
        Md5 ->
            {ok, IoList};
        _ ->
            exit({file_corruption, <<"file corruption">>})
        end;
    0 ->
        {ok, maybe_read_more_iolist(RestRawData, Len, NextPos, Fd)}
    end.


%%----------------------------------------------------------------------
%% Purpose: The length of a file, in bytes.
%% Returns: {ok, Bytes}
%%  or {error, Reason}.
%%----------------------------------------------------------------------

% length in bytes
bytes(Fd) ->
    gen_server:call(Fd, bytes, infinity).

%%----------------------------------------------------------------------
%% Purpose: Truncate a file to the number of bytes.
%% Returns: ok
%%  or {error, Reason}.
%%----------------------------------------------------------------------

truncate(Fd, Pos) ->
    gen_server:call(Fd, {truncate, Pos}, infinity).

%%----------------------------------------------------------------------
%% Purpose: Ensure all bytes written to the file are flushed to disk.
%% Returns: ok
%%  or {error, Reason}.
%%----------------------------------------------------------------------

sync(Fd) ->
    gen_server:call(Fd, sync, infinity).

%%----------------------------------------------------------------------
%% Purpose: Ensure that all the data the caller previously asked to write
%% to the file were flushed to disk (not necessarily fsync'ed).
%% Returns: ok
%%----------------------------------------------------------------------

flush(Fd) ->
    gen_server:call(Fd, flush, infinity).

%%----------------------------------------------------------------------
%% Purpose: Close the file.
%% Returns: ok
%%----------------------------------------------------------------------
close(Fd) ->
    couch_util:shutdown_sync(Fd).


delete(RootDir, Filepath) ->
    delete(RootDir, Filepath, true).


delete(RootDir, Filepath, Async) ->
    DelFile = filename:join([RootDir,".delete", ?b2l(couch_uuids:random())]),
    case file:rename(Filepath, DelFile) of
    ok ->
        if (Async) ->
            spawn(file, delete, [DelFile]),
            ok;
        true ->
            file:delete(DelFile)
        end;
    Error ->
        Error
    end.


init_delete_dir(RootDir) ->
    Dir = filename:join(RootDir,".delete"),
    % note: ensure_dir requires an actual filename companent, which is the
    % reason for "foo".
    filelib:ensure_dir(filename:join(Dir,"foo")),
    filelib:fold_files(Dir, ".*", true,
        fun(Filename, _) ->
            ok = file:delete(Filename)
        end, ok).


read_header(Fd) ->
    case gen_server:call(Fd, find_header, infinity) of
    {ok, Bin} ->
        {ok, binary_to_term(Bin)};
    Else ->
        Else
    end.

write_header(Fd, Data) ->
    Bin = term_to_binary(Data),
    Md5 = couch_util:md5(Bin),
    % now we assemble the final header binary and write to disk
    FinalBin = <<Md5/binary, Bin/binary>>,
    gen_server:call(Fd, {write_header, FinalBin}, infinity).




init_status_error(ReturnPid, Ref, Error) ->
    ReturnPid ! {Ref, self(), Error},
    ignore.

% server functions

init({Filepath, Options, ReturnPid, Ref}) ->
   try
       maybe_create_file(Filepath, Options),
       ReadFd = case file:open(Filepath, [read, binary]) of
       {ok, Fd} ->
           Fd;
       Error ->
           throw({error, Error})
       end,
       Writer = spawn_writer(Filepath, Options),
       Size = filelib:file_size(Filepath),
       maybe_track_open_os_files(Options),
       {ok, #file{fd = ReadFd, writer = Writer, real_eof = Size, eof = Size}}
   catch
   throw:{error, Err} ->
       init_status_error(ReturnPid, Ref, Err)
   end.

maybe_create_file(Filepath, Options) ->
    case lists:member(create, Options) of
    true ->
        filelib:ensure_dir(Filepath),
        case file:open(Filepath, [write, binary]) of
        {ok, Fd} ->
            {ok, Length} = file:position(Fd, eof),
            case Length > 0 of
            true ->
                % this means the file already exists and has data.
                % FYI: We don't differentiate between empty files and non-existant
                % files here.
                case lists:member(overwrite, Options) of
                true ->
                    {ok, 0} = file:position(Fd, 0),
                    ok = file:truncate(Fd),
                    ok = file:sync(Fd);
                false ->
                    ok = file:close(Fd),
                    throw({error, file_exists})
                end;
            false ->
                ok
            end;
        Error ->
            throw({error, Error})
        end;
    false ->
        ok
    end.

spawn_writer(Filepath, Options) ->
    case lists:member(read_only, Options) of
    true ->
        nil;
    false ->
        case couch_file_writer:start_link(Filepath) of
        {ok, Pid} ->
            Pid;
        Error ->
            throw({error, {file_writer_creation, Error}})
        end
    end.

maybe_track_open_os_files(FileOptions) ->
    case lists:member(sys_db, FileOptions) of
    true ->
        ok;
    false ->
        couch_stats_collector:track_process_count({couchdb, open_os_files})
    end.

terminate(_Reason, #file{fd = Fd, writer = nil}) ->
    ok = file:close(Fd);
terminate(_Reason, #file{fd = Fd, writer = Writer}) ->
    ok = file:close(Fd),
    ok = couch_file_writer:close(Writer).


handle_call(get_fd, _From, #file{fd = Fd} = File) ->
    {reply, {ok, Fd}, File};

handle_call(bytes, _From, #file{eof = Eof} = File) ->
    {reply, {ok, Eof}, File};

handle_call(sync, _From, #file{writer = Writer, eof = Eof} = File) ->
    % TODO: maybe flush before sync, assume for now the caller has invoked
    % flush before this call
    ok = couch_file_writer:sync(Writer),
    {reply, ok, File#file{real_eof = Eof}};

handle_call({truncate, Pos}, _From, #file{writer = Writer} = File) ->
    ok = couch_file_writer:truncate(Writer, Pos),
    {reply, ok, File#file{eof = Pos, real_eof = Pos}};

handle_call({append_bin, Bin}, {Pid, _} = From, #file{writer = W, eof = Pos} = File) ->
    Blocks = make_blocks(Pos rem ?SIZE_BLOCK, Bin),
    ok = couch_file_writer:write_chunk(W, {Pos, Blocks}),
    gen_server:reply(From, {ok, Pos}),
    File2 = File#file{
        eof = Pos + iolist_size(Blocks),
        pid_to_pos = dict:store(Pid, Pos, File#file.pid_to_pos)
    },
    {noreply, File2};

handle_call({write_header, Bin}, {Pid, _} = From, #file{writer = W, eof = Pos} = File) ->
    BinSize = byte_size(Bin),
    case Pos rem ?SIZE_BLOCK of
    0 ->
        Padding = <<>>;
    BlockOffset ->
        Padding = <<0:(8*(?SIZE_BLOCK-BlockOffset))>>
    end,
    FinalBin = [Padding, <<1, BinSize:32/integer>> | make_blocks(5, [Bin])],
    ok = couch_file_writer:write_chunk(W, {Pos, FinalBin}),
    gen_server:reply(From, ok),
    File2 = File#file{
        eof = Pos + iolist_size(FinalBin),
        pid_to_pos = dict:store(Pid, Pos, File#file.pid_to_pos)
    },
    {noreply, File2};

handle_call(flush, {Pid, _} = From, #file{writer = W} = File) ->
    #file{pid_to_pos = PidPos, pos_to_flush_req = FlushReqs} = File,
    case dict:find(Pid, PidPos) of
    error ->
        {reply, ok, File};
    {ok, Pos} ->
        case couch_file_writer:flush(W, Pos) of
        ok ->
            gen_server:reply(From, ok),
            {noreply, File#file{pid_to_pos = dict:erase(Pid, PidPos)}};
        wait ->
            FlushReqs2 = dict:store(Pos, From, FlushReqs),
            {noreply, File#file{pos_to_flush_req = FlushReqs2}}
        end
    end;

handle_call(find_header, _From, #file{fd = Fd, eof = Pos} = File) ->
    {reply, find_header(Fd, Pos div ?SIZE_BLOCK), File}.

handle_cast(close, Fd) ->
    {stop,normal,Fd}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_info({flushed, Pos}, #file{pos_to_flush_req = FlushReqs} = File) ->
    {Pid, _} = FlushReq = dict:fetch(Pos, FlushReqs),
    gen_server:reply(FlushReq, ok),
    File2 = File#file{
        pos_to_flush_req = dict:erase(Pos, FlushReqs),
        pid_to_pos = dict:erase(Pid, File#file.pid_to_pos)
    },
    {noreply, File2};

handle_info({'EXIT', _, normal}, Fd) ->
    {noreply, Fd};
handle_info({'EXIT', _, Reason}, Fd) ->
    {stop, Reason, Fd}.


find_header(_Fd, -1) ->
    no_valid_header;
find_header(Fd, Block) ->
    case (catch load_header(Fd, Block)) of
    {ok, Bin} ->
        {ok, Bin};
    _Error ->
        find_header(Fd, Block -1)
    end.

load_header(Fd, Block) ->
    {ok, <<1, HeaderLen:32/integer, RestBlock/binary>>} =
        file:pread(Fd, Block * ?SIZE_BLOCK, ?SIZE_BLOCK),
    TotalBytes = calculate_total_read_len(1, HeaderLen),
    case TotalBytes > byte_size(RestBlock) of
    false ->
        <<RawBin:TotalBytes/binary, _/binary>> = RestBlock;
    true ->
        {ok, Missing} = file:pread(
            Fd, (Block * ?SIZE_BLOCK) + 5 + byte_size(RestBlock),
            TotalBytes - byte_size(RestBlock)),
        RawBin = <<RestBlock/binary, Missing/binary>>
    end,
    <<Md5Sig:16/binary, HeaderBin/binary>> =
        iolist_to_binary(remove_block_prefixes(1, RawBin)),
    Md5Sig = couch_util:md5(HeaderBin),
    {ok, HeaderBin}.

maybe_read_more_iolist(Buffer, DataSize, _, _)
    when DataSize =< byte_size(Buffer) ->
    <<Data:DataSize/binary, _/binary>> = Buffer,
    [Data];
maybe_read_more_iolist(Buffer, DataSize, NextPos, Fd) ->
    {Missing, _} =
        read_raw_iolist_int(Fd, NextPos, DataSize - byte_size(Buffer)),
    [Buffer, Missing].

-spec read_raw_iolist_int(#file{}, Pos::non_neg_integer(), Len::non_neg_integer()) ->
    {Data::iolist(), CurPos::non_neg_integer()}.
read_raw_iolist_int(Fd, {Pos, _Size}, Len) -> % 0110 UPGRADE CODE
    read_raw_iolist_int(Fd, Pos, Len);
read_raw_iolist_int(Fd, Pos, Len) ->
    BlockOffset = Pos rem ?SIZE_BLOCK,
    TotalBytes = calculate_total_read_len(BlockOffset, Len),
    {ok, <<RawBin:TotalBytes/binary>>} = file:pread(Fd, Pos, TotalBytes),
    {remove_block_prefixes(BlockOffset, RawBin), Pos + TotalBytes}.

-spec extract_md5(iolist()) -> {binary(), iolist()}.
extract_md5(FullIoList) ->
    {Md5List, IoList} = split_iolist(FullIoList, 16, []),
    {iolist_to_binary(Md5List), IoList}.

calculate_total_read_len(0, FinalLen) ->
    calculate_total_read_len(1, FinalLen) + 1;
calculate_total_read_len(BlockOffset, FinalLen) ->
    case ?SIZE_BLOCK - BlockOffset of
    BlockLeft when BlockLeft >= FinalLen ->
        FinalLen;
    BlockLeft ->
        FinalLen + ((FinalLen - BlockLeft) div (?SIZE_BLOCK -1)) +
            if ((FinalLen - BlockLeft) rem (?SIZE_BLOCK -1)) =:= 0 -> 0;
                true -> 1 end
    end.

remove_block_prefixes(_BlockOffset, <<>>) ->
    [];
remove_block_prefixes(0, <<_BlockPrefix,Rest/binary>>) ->
    remove_block_prefixes(1, Rest);
remove_block_prefixes(BlockOffset, Bin) ->
    BlockBytesAvailable = ?SIZE_BLOCK - BlockOffset,
    case size(Bin) of
    Size when Size > BlockBytesAvailable ->
        <<DataBlock:BlockBytesAvailable/binary,Rest/binary>> = Bin,
        [DataBlock | remove_block_prefixes(0, Rest)];
    _Size ->
        [Bin]
    end.

make_blocks(_BlockOffset, []) ->
    [];
make_blocks(0, IoList) ->
    [<<0>> | make_blocks(1, IoList)];
make_blocks(BlockOffset, IoList) ->
    case split_iolist(IoList, (?SIZE_BLOCK - BlockOffset), []) of
    {Begin, End} ->
        [Begin | make_blocks(0, End)];
    _SplitRemaining ->
        IoList
    end.

%% @doc Returns a tuple where the first element contains the leading SplitAt
%% bytes of the original iolist, and the 2nd element is the tail. If SplitAt
%% is larger than byte_size(IoList), return the difference.
-spec split_iolist(IoList::iolist(), SplitAt::non_neg_integer(), Acc::list()) ->
    {iolist(), iolist()} | non_neg_integer().
split_iolist(List, 0, BeginAcc) ->
    {lists:reverse(BeginAcc), List};
split_iolist([], SplitAt, _BeginAcc) ->
    SplitAt;
split_iolist([<<Bin/binary>> | Rest], SplitAt, BeginAcc) when SplitAt > byte_size(Bin) ->
    split_iolist(Rest, SplitAt - byte_size(Bin), [Bin | BeginAcc]);
split_iolist([<<Bin/binary>> | Rest], SplitAt, BeginAcc) ->
    <<Begin:SplitAt/binary,End/binary>> = Bin,
    split_iolist([End | Rest], 0, [Begin | BeginAcc]);
split_iolist([Sublist| Rest], SplitAt, BeginAcc) when is_list(Sublist) ->
    case split_iolist(Sublist, SplitAt, BeginAcc) of
    {Begin, End} ->
        {Begin, [End | Rest]};
    SplitRemaining ->
        split_iolist(Rest, SplitAt - (SplitAt - SplitRemaining), [Sublist | BeginAcc])
    end;
split_iolist([Byte | Rest], SplitAt, BeginAcc) when is_integer(Byte) ->
    split_iolist(Rest, SplitAt - 1, [Byte | BeginAcc]).
