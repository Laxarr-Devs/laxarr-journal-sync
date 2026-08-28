//+------------------------------------------------------------------+
//|                                    TradingPanelTradeSync.mqh     |
//|  Out-of-line CTradingPanelDialog method bodies (see TradingPanel |
//|  .mq5 for the class declaration and split rationale) for         |
//|  closed-trade sync: POST /mt5/sync/. Persists a watermark (an    |
//|  MT5 terminal global variable) tracking how far the account's    |
//|  closed deal history has been sent, backfills a bounded window   |
//|  on first run, and batches every poll cycle to avoid one huge    |
//|  POST.                                                            |
//+------------------------------------------------------------------+
#ifndef TRADINGPANEL_TRADESYNC_MQH
#define TRADINGPANEL_TRADESYNC_MQH

//--- Terminal-global-variable name for the persisted sync watermark,
//--- scoped per account login so multiple accounts on the same terminal
//--- (or the same account across terminal reinstalls, since these
//--- variables are saved to disk) never share one another's progress.
string CTradingPanelDialog::TradeSyncWatermarkVarName()
{
   return "TradingPanelEA_TradeSyncWatermark_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
}

//--- No prior watermark: back-fill up to 1 month of history rather than
//--- starting from "now", so a trader attaching this EA for the first
//--- time (or after resetting the terminal) still sees their recent
//--- closed trades. Capped at 1 month rather than the account's entire
//--- history, since older history is what the separate "Import MT5
//--- Statement" flow is for. Persisted immediately so a terminal restart
//--- before any new trade closes doesn't push the starting point later.
//--- The catch-up itself happens gradually — see MAX_TRADE_SYNC_BATCH in
//--- BuildAndPostClosedTrades — never as one giant first POST.
datetime CTradingPanelDialog::GetTradeSyncWatermark()
{
   string varName = TradeSyncWatermarkVarName();
   if(GlobalVariableCheck(varName))
      return (datetime)GlobalVariableGet(varName);

   datetime backfillStart = TimeCurrent() - TRADE_SYNC_BACKFILL_DAYS * 86400;
   GlobalVariableSet(varName, (double)backfillStart);
   if(EnableLogging) Print("Trade sync: no prior watermark found - backfilling from ", TimeToString(backfillStart, TIME_DATE|TIME_SECONDS),
         " (", TRADE_SYNC_BACKFILL_DAYS, " days ago)");
   return backfillStart;
}

void CTradingPanelDialog::SetTradeSyncWatermark(datetime value)
{
   GlobalVariableSet(TradeSyncWatermarkVarName(), (double)value);
}

//--- MqlDateTime-based ISO-8601 formatting ("YYYY-MM-DDTHH:MM:SS"), for the
//--- backend's parse_broker_datetime (see poller_service.py), which
//--- interprets a naive ISO string as broker-server local time — exactly
//--- what every MT5 history timestamp already is, so no conversion is
//--- needed. Not TimeToString(), whose "YYYY.MM.DD HH:MM:SS" dot-separated
//--- format isn't ISO-8601.
string CTradingPanelDialog::ToIso8601(datetime dt)
{
   MqlDateTime mdt;
   TimeToStruct(dt, mdt);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d", mdt.year, mdt.mon, mdt.day, mdt.hour, mdt.min, mdt.sec);
}

//--- Weighted-average open price and earliest open time for a position,
//--- from its DEAL_ENTRY_IN deal(s) — plural since a position can be built
//--- from more than one fill (e.g. scaling in). Also returns the entry
//--- order's SL/TP as a best-effort read of the position's protective
//--- levels: MT5 keeps no per-deal SL/TP, and a closed position exposes
//--- none either, so the entry order's ORDER_SL/ORDER_TP (set at open) is
//--- the closest approximation available from pure history — it will not
//--- reflect a stop later moved (e.g. trailed) after opening.
//--- Call only between outer-loop passes (see BuildAndPostClosedTrades):
//--- HistorySelectByPosition replaces the terminal's current history
//--- selection, which would corrupt an in-progress HistoryDealGetTicket(i)
//--- loop over a different selection if called from inside one.
void CTradingPanelDialog::ResolvePositionEntry(long positionId, double &openPrice, datetime &openTime, double &sl, double &tp)
{
   openPrice = 0.0;
   openTime  = 0;
   sl = 0.0;
   tp = 0.0;

   double volumeSum = 0.0;
   double priceVolumeSum = 0.0;
   long firstEntryOrder = 0;

   if(!HistorySelectByPosition(positionId)) return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;

      double dealVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      double dealPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);

      volumeSum += dealVolume;
      priceVolumeSum += dealVolume * dealPrice;
      if(openTime == 0 || dealTime < openTime)
      {
         openTime = dealTime;
         firstEntryOrder = (long)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
      }
   }

   if(volumeSum > 0.0) openPrice = priceVolumeSum / volumeSum;

   if(firstEntryOrder != 0 && HistoryOrderSelect((ulong)firstEntryOrder))
   {
      sl = HistoryOrderGetDouble((ulong)firstEntryOrder, ORDER_SL);
      tp = HistoryOrderGetDouble((ulong)firstEntryOrder, ORDER_TP);
   }
}

//--- Scans closed deals since the persisted watermark, builds one JSON
//--- payload row per closing fill (see below for why a partial close gets
//--- its own row), POSTs the batch, and on any actual HTTP response —
//--- success or not — advances the watermark to the newest close time
//--- included. Advancing on a 400 as well as a 200 is deliberate: the
//--- backend bulk_creates every row that parsed cleanly before it decides
//--- the overall response status (see MT5PollerService.sync_trades_from_json),
//--- so a batch with a few bad rows still persists the good ones — never
//--- advancing on 400 would resend those already-persisted rows forever.
//--- Only a transport-level failure (status == -1, no response reached
//--- the backend) holds the watermark back for a clean retry next cycle.
//---
//--- The two-pass structure is required, not stylistic: pass 1 walks the
//--- wide HistorySelect(fromTime, now) range by index and extracts every
//--- field this function needs from each qualifying OUT deal into the
//--- row* parallel arrays below, with nothing re-read from that ticket
//--- afterward. Pass 2 (after pass 1's loop fully completes) calls
//--- ResolvePositionEntry per row, which internally re-selects history via
//--- HistorySelectByPosition. Re-reading OUT-deal properties by ticket
//--- inside pass 2, after that reselection has run for an earlier row,
//--- cannot be relied on to still reflect pass 1's original wide
//--- selection — extracting everything up front in pass 1 avoids
//--- depending on that.
void CTradingPanelDialog::BuildAndPostClosedTrades(datetime fromTime)
{
   if(!HistorySelect(fromTime, TimeCurrent()))
   {
      Print("Trade sync: HistorySelect failed for range starting ", TimeToString(fromTime, TIME_DATE|TIME_SECONDS));
      return;
   }

   //--- Pass 1: collect qualifying closing deals' fields from the wide
   //--- selection. Capped at MAX_TRADE_SYNC_BATCH (see its own comment near
   //--- the top of TradingPanel.mq5) per cycle so a long backlog (a fresh
   //--- backfill, or the EA left detached for a while) can't build one
   //--- huge, possibly-timing-out POST — the remainder is picked up on
   //--- following cycles, since the watermark only advances to whatever
   //--- was actually included in this batch.
   ulong    rowTicket[];     ArrayResize(rowTicket, 0);
   long     rowPositionId[]; ArrayResize(rowPositionId, 0);
   string   rowSymbol[];     ArrayResize(rowSymbol, 0);
   string   rowDirection[];  ArrayResize(rowDirection, 0);
   double   rowVolume[];     ArrayResize(rowVolume, 0);
   double   rowPrice[];      ArrayResize(rowPrice, 0);
   datetime rowTime[];       ArrayResize(rowTime, 0);
   double   rowProfit[];     ArrayResize(rowProfit, 0);
   double   rowSwap[];       ArrayResize(rowSwap, 0);
   double   rowCommission[]; ArrayResize(rowCommission, 0);

   int total = HistoryDealsTotal();
   for(int i = 0; i < total && ArraySize(rowTicket) < MAX_TRADE_SYNC_BATCH; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);

      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL) continue; // skip balance/credit/etc.
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue; // only closing fills
      if(symbol == "") continue;

      int n = ArraySize(rowTicket);
      ArrayResize(rowTicket, n + 1);
      ArrayResize(rowPositionId, n + 1);
      ArrayResize(rowSymbol, n + 1);
      ArrayResize(rowDirection, n + 1);
      ArrayResize(rowVolume, n + 1);
      ArrayResize(rowPrice, n + 1);
      ArrayResize(rowTime, n + 1);
      ArrayResize(rowProfit, n + 1);
      ArrayResize(rowSwap, n + 1);
      ArrayResize(rowCommission, n + 1);

      rowTicket[n]     = dealTicket;
      rowPositionId[n] = (long)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      rowSymbol[n]     = symbol;
      //--- The OUT deal's own type is the opposite of the position it
      //--- closed (a SELL deal closes a BUY position, and vice versa).
      rowDirection[n]  = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";
      rowVolume[n]     = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      rowPrice[n]      = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      rowTime[n]       = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      rowProfit[n]     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      rowSwap[n]       = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      rowCommission[n] = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }

   if(ArraySize(rowTicket) == 0) return; // nothing new to sync this cycle — the normal case, not worth logging every poll

   //--- Pass 2: resolve each row's position-entry data (the only step left
   //--- that touches history selection) and build JSON. Plain "+"
   //--- concatenation throughout (see UpdateRiskLimitsLabel's own comment
   //--- on why StringFormat is avoided once a substituted value could
   //--- contain a character that trips its parser) for consistency.
   string json = "[";
   datetime maxCloseTime = 0;
   long accountLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   int includedRows = 0;

   for(int r = 0; r < ArraySize(rowTicket); r++)
   {
      double openPrice; datetime openTime; double sl; double tp;
      ResolvePositionEntry(rowPositionId[r], openPrice, openTime, sl, tp);
      if(openTime == 0 || openPrice <= 0.0)
      {
         if(EnableLogging) Print("Trade sync: could not resolve entry for position ", rowPositionId[r], " (deal ", rowTicket[r], ") - skipping row");
         continue;
      }

      if(includedRows > 0) json += ",";
      json += "{";
      json += "\"account_no\":\"" + IntegerToString(accountLogin) + "\",";
      //--- Each partial-close fill gets its own row, keyed by its globally
      //--- unique deal ticket, so the backend's per-ticket upsert never
      //--- collides two partial closes of the same position into one row.
      //--- position_id groups them back together as one logical trade on
      //--- the backend/frontend side (see external_trade_id in
      //--- MT5PollerService.sync_trades_from_json).
      json += "\"ticket\":\"" + IntegerToString(rowTicket[r]) + "\",";
      json += "\"position_id\":\"" + IntegerToString(rowPositionId[r]) + "\",";
      json += "\"symbol\":\"" + rowSymbol[r] + "\",";
      json += "\"direction\":\"" + rowDirection[r] + "\",";
      json += "\"volume\":\"" + DoubleToString(rowVolume[r], 2) + "\",";
      json += "\"open_time\":\"" + ToIso8601(openTime) + "\",";
      json += "\"close_time\":\"" + ToIso8601(rowTime[r]) + "\",";
      json += "\"open_price\":\"" + DoubleToString(openPrice, 5) + "\",";
      json += "\"close_price\":\"" + DoubleToString(rowPrice[r], 5) + "\",";
      json += "\"stop_loss\":\"" + (sl > 0.0 ? DoubleToString(sl, 5) : "0") + "\",";
      json += "\"take_profit\":\"" + (tp > 0.0 ? DoubleToString(tp, 5) : "0") + "\",";
      json += "\"profit\":\"" + DoubleToString(rowProfit[r], 2) + "\",";
      json += "\"swap\":\"" + DoubleToString(rowSwap[r], 2) + "\",";
      json += "\"commission\":\"" + DoubleToString(rowCommission[r], 2) + "\"";
      json += "}";

      includedRows++;
      if(rowTime[r] > maxCloseTime) maxCloseTime = rowTime[r];

      //--- Candle context for this same closed trade — see
      //--- BuildAndPostTradeCandles in TradingPanelTradeReport.mqh. A
      //--- separate POST per trade, not batched into the JSON array above,
      //--- so one trade's candle count can never blow up this cycle's main
      //--- trade-sync payload. Independent of trade-sync success/failure
      //--- below — candles are stored keyed by their own (broker_account,
      //--- ticket), not synchronously FK'd to the Trade row.
      if(EnableCandleReporting)
         BuildAndPostTradeCandles(rowSymbol[r], IntegerToString(rowTicket[r]), openTime, rowTime[r]);
   }
   json += "]";

   if(includedRows == 0)
   {
      if(EnableLogging) Print("Trade sync: all ", ArraySize(rowTicket), " candidate row(s) failed entry resolution - nothing to send this cycle");
      return;
   }

   string url = ApiBaseUrl + "sync/";
   string headers = "Content-Type: application/json\r\nX-API-Key: " + ApiKey + "\r\n";
   char data[];
   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   //--- StringToCharArray null-terminates; WebRequest would otherwise
   //--- send that trailing zero byte as part of the body.
   ArrayResize(data, ArraySize(data) - 1);
   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("POST", url, headers, 5000, data, result, resultHeaders);

   if(status == -1)
   {
      int err = GetLastError();
      Print("Trade sync failed: WebRequest error ", err, " for ", url, " - watermark not advanced, will retry next cycle");
      return;
   }

   //--- One combined line for the whole operation, reached only when
   //--- there's something to report (includedRows > 0) — the one
   //--- trade-sync log line that fires under normal operation.
   SetTradeSyncWatermark(maxCloseTime);
   if(EnableLogging) Print("Trade sync: synced ", includedRows, " trade row(s), HTTP ", status,
         ", watermark advanced to ", TimeToString(maxCloseTime, TIME_DATE|TIME_SECONDS));
}

//--- Not polled on any interval — called exactly once per click of the
//--- "Sync" button (OnClickSync), right after RefreshRiskParametersIfDue,
//--- and returns after that one WebRequest. Shares m_riskPollingHalted
//--- with the risk poll rather than tracking its own halt state, since
//--- both calls hit the same ApiKey/X-API-Key auth path, so a missing or
//--- rejected key breaks them identically.
void CTradingPanelDialog::SyncClosedTradesIfDue()
{
   if(m_riskPollingHalted) return;

   m_lastTradeSyncPollTime = TimeCurrent();

   if(StringLen(ApiKey) == 0) return; // PollRiskParameters already halts+logs this case

   datetime watermark = GetTradeSyncWatermark();
   BuildAndPostClosedTrades(watermark);
}

//--- Approximates sym's per-lot commission from the most recently closed
//--- deal's DEAL_COMMISSION. MQL5 has no pre-trade API for a broker's
//--- commission schedule, so this is necessarily a look-back estimate, not
//--- a live quote — the panel always marks it with an "approx" (≈) sign
//--- rather than presenting it as exact. Reads only the closing (OUT)
//--- deal, matching how BuildAndPostClosedTrades' rowCommission treats
//--- commission (an opening deal's own commission, if a broker charges
//--- one, is not folded in either). Returns false (commissionPerLot left
//--- at 0.0) if sym has no closed trade in this account's history yet,
//--- distinct from a genuinely commission-free broker, which returns true
//--- with commissionPerLot 0.0.
bool CTradingPanelDialog::EstimateCommissionPerLot(string sym, double &commissionPerLot)
{
   commissionPerLot = 0.0;
   if(sym == "" || !HistorySelect(0, TimeCurrent())) return false;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != sym) continue;

      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL) continue; // skip balance/credit/etc.
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue; // only closing fills

      double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      if(volume <= 0.0) continue;

      commissionPerLot = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION) / volume;
      return true;
   }
   return false;
}

//--- Refreshes m_commissionPerLotEstimate for the currently selected
//--- symbol. Rate-limited to PollingIntervalSeconds (min 10), the same
//--- gate pattern as RefreshRiskParametersIfDue/SyncClosedTradesIfDue,
//--- since the HistorySelect(0, ...) + backward scan above walks the whole
//--- account history and is too costly to run every OnTick. Also forced
//--- (force=true) from ApplySymbolChange so switching symbols doesn't
//--- leave the readout showing the previous symbol's estimate for up to a
//--- full poll interval. Not gated on m_riskPollingHalted — unlike the
//--- risk/trade-sync polls, this reads only local MT5 history, with no
//--- backend call or ApiKey involved.
void CTradingPanelDialog::RefreshCommissionEstimateIfDue(bool force)
{
   string sym = m_comboSymbol.Select();
   if(sym == "") return;

   bool symbolChanged = (sym != m_commissionEstSymbol);
   int intervalSec = MathMax(PollingIntervalSeconds, 10);
   if(!force && !symbolChanged && (TimeCurrent() - m_lastCommissionEstTime < intervalSec)) return;

   m_commissionEstSymbol = sym;
   m_lastCommissionEstTime = TimeCurrent();
   m_hasCommissionEstimate = EstimateCommissionPerLot(sym, m_commissionPerLotEstimate);
}

#endif // TRADINGPANEL_TRADESYNC_MQH
