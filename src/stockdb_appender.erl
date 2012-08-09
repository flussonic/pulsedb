-module(stockdb_appender).
-author('Max Lapshin <max@maxidoors.ru>').

-include("../include/stockdb.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("stockdb.hrl").
-include("log.hrl").


-export([open/2, append/2, close/1]).


open(Path, Opts) ->
  case filelib:is_regular(Path) of
    true ->
      open_existing_db(Path, Opts);
    false ->
      create_new_db(Path, Opts)
  end.


close(#dbstate{file = File}) ->
  file:close(File),
  ok.


%% Here we create skeleton for new DB
create_new_db(Path, Opts) ->
  filelib:ensure_dir(Path),
  {ok, File} = file:open(Path, [binary,write,exclusive,raw]),
  {ok, 0} = file:position(File, bof),
  ok = file:truncate(File),

  {stock, Stock} = lists:keyfind(stock, 1, Opts),
  {date, Date} = lists:keyfind(date, 1, Opts),
  State = #dbstate{
    mode = append,
    version = ?STOCKDB_VERSION,
    stock = Stock,
    date = Date,
    path = Path,
    depth = proplists:get_value(depth, Opts, 1),
    scale = proplists:get_value(scale, Opts, 100),
    chunk_size = proplists:get_value(chunk_size, Opts, 5*60)
  },

  {ok, ChunkMapOffset} = write_header(File, State),
  {ok, _CMSize} = write_chunk_map(File, State),

  {ok, State#dbstate{
      file = File,
      chunk_map_offset = ChunkMapOffset
    }}.


open_existing_db(Path, _Opts) ->
  stockdb_reader:open_existing_db(Path, [binary,write,read,raw]).


append(_Event, #dbstate{mode = Mode}) when Mode =/= append ->
  {error, reopen_in_append_mode};

append({trade, Timestamp, _ ,_} = Trade, #dbstate{next_chunk_time = NCT} = State) when Timestamp >= NCT ->
  append(Trade, start_chunk(Timestamp, State));

append({md, Timestamp, _, _} = MD, #dbstate{next_chunk_time = NCT} = State) when Timestamp >= NCT ->
  append(MD, start_chunk(Timestamp, State));


append({trade, Timestamp, Price, Volume}, #dbstate{scale = Scale} = State) ->
  StorePrice = erlang:round(Price * Scale),
  append_trade({trade, Timestamp, StorePrice, Volume}, State);

append({md, _Timestamp, _Bid, _Ask} = MD, #dbstate{scale = Scale, next_md_full = true} = State) ->
  append_full_md(scale_md(MD, Scale), State);

append({md, _Timestamp, _Bid, _Ask} = MD, #dbstate{scale = Scale} = State) ->
  append_delta_md(scale_md(MD, Scale), State).


write_header(File, #dbstate{chunk_size = CS, date = Date, depth = Depth, scale = Scale, stock = Stock, version = Version}) ->
  StockDBOpts = [{chunk_size,CS},{date,Date},{depth,Depth},{scale,Scale},{stock,Stock},{version,Version}],
  {ok, 0} = file:position(File, 0),
  ok = file:write(File, <<"#!/usr/bin/env stockdb\n">>),
  lists:foreach(fun({Key, Value}) ->
        ok = file:write(File, [io_lib:print(Key), ": ", stockdb_format:format_header_value(Key, Value), "\n"])
    end, StockDBOpts),
  ok = file:write(File, "\n"),
  file:position(File, cur).



write_chunk_map(File, #dbstate{chunk_size = ChunkSize}) ->
  ChunkCount = stockdb_raw:number_of_chunks(ChunkSize),

  ChunkMap = [<<0:?OFFSETLEN>> || _ <- lists:seq(1, ChunkCount)],
  Size = ?OFFSETLEN * ChunkCount,

  ok = file:write(File, ChunkMap),
  {ok, Size}.



start_chunk(Timestamp, #dbstate{daystart = undefined, date = Date} = State) ->
  start_chunk(Timestamp, State#dbstate{daystart = daystart(Date)});

start_chunk(Timestamp, State) ->
  #dbstate{
    daystart = Daystart,
    chunk_size = ChunkSize,
    chunk_map = ChunkMap} = State,

  ChunkSizeMs = timer:seconds(ChunkSize),
  ChunkNumber = (Timestamp - Daystart) div ChunkSizeMs,

  % sanity check
  (Timestamp - Daystart) < timer:hours(24) orelse erlang:error({not_this_day, Timestamp}),

  ChunkOffset = current_chunk_offset(State),
  write_chunk_offset(ChunkNumber, ChunkOffset, State),

  NextChunkTime = Daystart + ChunkSizeMs * (ChunkNumber + 1),

  Chunk = {ChunkNumber, Timestamp, ChunkOffset},
  % ?D({new_chunk, Chunk}),
  State#dbstate{
    chunk_map = ChunkMap ++ [Chunk],
    next_chunk_time = NextChunkTime,
    next_md_full = true}.



current_chunk_offset(#dbstate{file = File, chunk_map_offset = ChunkMapOffset} = _State) ->
  {ok, EOF} = file:position(File, eof),
  _ChunkOffset = EOF - ChunkMapOffset.

write_chunk_offset(ChunkNumber, ChunkOffset, #dbstate{file = File, chunk_map_offset = ChunkMapOffset} = _State) ->
  ByteOffsetLen = ?OFFSETLEN div 8,
  ok = file:pwrite(File, ChunkMapOffset + ChunkNumber*ByteOffsetLen, <<ChunkOffset:?OFFSETLEN/integer>>).


append_full_md({md, Timestamp, Bid, Ask} = MD, #dbstate{depth = Depth, file = File} = State) ->
  BidAsk = [setdepth(Bid, Depth), setdepth(Ask, Depth)],
  Data = stockdb_format:encode_full_md(Timestamp, BidAsk),
  {ok, _EOF} = file:position(File, eof),
  ok = file:write(File, Data),
  {ok, State#dbstate{
      last_timestamp = Timestamp,
      last_bidask = BidAsk,
      last_md = MD,
      next_md_full = false}
  }.

append_delta_md({md, Timestamp, Bid, Ask} = MD, #dbstate{depth = Depth, file = File, last_timestamp = LastTS, last_bidask = LastBA} = State) ->
  BidAsk = [setdepth(Bid, Depth), setdepth(Ask, Depth)],
  BidAskDelta = bidask_delta(LastBA, BidAsk),
  Data = stockdb_format:encode_delta_md(Timestamp - LastTS, BidAskDelta),
  {ok, _EOF} = file:position(File, eof),
  ok = file:write(File, Data),
  {ok, State#dbstate{
    last_md = MD,
      last_timestamp = Timestamp,
      last_bidask = BidAsk}
  }.

append_trade({trade, Timestamp, Price, Volume}, #dbstate{file = File} = State) ->
  Data = stockdb_format:encode_trade(Timestamp, Price, Volume),
  {ok, _EOF} = file:position(File, eof),
  ok = file:write(File, Data),
  {ok, State#dbstate{last_timestamp = Timestamp}}.


setdepth(_Quotes, 0) ->
  [];
setdepth([], Depth) ->
  [{0, 0} || _ <- lists:seq(1, Depth)];
setdepth([Q|Quotes], Depth) ->
  [Q|setdepth(Quotes, Depth - 1)].

bidask_delta([[_|_] = Bid1, [_|_] = Ask1], [[_|_] = Bid2, [_|_] = Ask2]) ->
  [bidask_delta1(Bid1, Bid2), bidask_delta1(Ask1, Ask2)].

bidask_delta1(List1, List2) ->
  lists:zipwith(fun({Price1, Volume1}, {Price2, Volume2}) ->
    {Price2 - Price1, Volume2 - Volume1}
  end, List1, List2).


daystart(Date) ->
  DaystartSeconds = calendar:datetime_to_gregorian_seconds({Date, {0,0,0}}) - calendar:datetime_to_gregorian_seconds({{1970,1,1}, {0,0,0}}),
  DaystartSeconds * 1000.

apply_scale(PVList, Scale) when is_integer(Scale) ->
  lists:map(fun({Price, Volume}) ->
        {erlang:round(Price * Scale), Volume}
    end, PVList).



scale_md({md, Timestamp, Bid, Ask}, Scale) ->
  SBid = apply_scale(Bid, Scale),
  SAsk = apply_scale(Ask, Scale),
  {md, Timestamp, SBid, SAsk}.

