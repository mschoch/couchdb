%% Copyright 2011,  Filipe David Manana  <fdmanana@apache.org>
%% Web:  http://github.com/fdmanana/snappy-erlang-nif
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%  http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(snappy).

-export([compress/1, decompress/1]).
-export([uncompressed_length/1, is_valid/1]).

-on_load(init/0).


init() ->
    io:format("snappy NIF on_load called.~n"),
    {ok, LibPath} = init:get_argument(native_lib_path),
    Status = erlang:load_nif(hd(hd(LibPath)) ++ "/libsnappy_nif", 0),
    case Status of
        ok -> ok;
        {error, {E, Str}} ->
            error_logger:error_msg("Error loading snappy NIF: ~p, ~s~n", [E,Str]),
            Status
     end.


compress(_IoList) ->
    exit(snappy_nif_not_loaded).


decompress(_IoList) ->
    exit(snappy_nif_not_loaded).


uncompressed_length(_IoList) ->
    exit(snappy_nif_not_loaded).


is_valid(_IoList) ->
    exit(snappy_nif_not_loaded).
