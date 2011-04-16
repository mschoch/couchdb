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

-module(couch_compress).

-export([compress/1, decompress/1, is_compressed/1]).

-include("couch_db.hrl").

% binaries compressed with snappy have their first byte set to this value
-define(SNAPPY_PREFIX, 1).
% binaries that are a result of an erlang:term_to_binary/1,2 call have this
% value as their first byte
-define(TERM_PREFIX, 131).


compress(Term) ->
    Bin = ?term_to_bin(Term),
    try
        {ok, CompressedBin} = snappy:compress(Bin),
        <<?SNAPPY_PREFIX, CompressedBin/binary>>
    catch exit:snappy_nif_not_loaded ->
        Bin
    end.


decompress(<<?SNAPPY_PREFIX, Rest/binary>>) ->
    {ok, TermBin} = snappy:decompress(Rest),
    binary_to_term(TermBin);
decompress(<<?TERM_PREFIX, _/binary>> = Bin) ->
    binary_to_term(Bin).


is_compressed(<<?SNAPPY_PREFIX, _/binary>>) ->
    true;
is_compressed(<<?TERM_PREFIX, _/binary>>) ->
    true;
is_compressed(_Term) ->
    false.
