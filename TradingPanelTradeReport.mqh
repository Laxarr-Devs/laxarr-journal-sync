//+------------------------------------------------------------------+
//|                              TradingPanelTradeReport.mqh          |
//|  Out-of-line CTradingPanelDialog method bodies (see TradingPanel  |
//|  .mq5 for the class declaration and split rationale) for:         |
//|    1. Candle context — POST /mt5/candles/ — one OHLCV series per  |
//|       closed trade (its open_time..close_time window), decimated  |
//|       by how long the trade was held (see                        |
//|       CandleTimeframeForDuration). Called from                   |
//|       BuildAndPostClosedTrades in TradingPanelTradeSync.mqh, once |
//|       per closed row, gated on EnableCandleReporting.             |
//|    2. Position close handling — CheckForPositionCloseAndHandle    |
//|       filters OnTradeTransaction's firehose down to the single    |
//|       deal that actually closes a position, then does two         |
//|       independent things: (a) always sets m_closeSyncPending so   |
//|       OnTimer runs SyncClosedTradesIfDue shortly after, keeping   |
//|       the Trade-row/journal data current without a manual Sync    |
//|       click; (b) when EnableTransactionReporting is on, POSTs to  |
//|       /mt5/trade-transactions/ — BuildClosedPositionLifecycleJson |
//|       rebuilds that position's order/deal history from MT5        |
//|       history into the same JSON shape a live per-event stream    |
//|       would have used, queued and flushed/retried from OnTimer    |
//|       via FlushPendingTradePostsIfDue at most one WebRequest per  |
//|       tick, never sent synchronously from OnTradeTransaction.     |
//+------------------------------------------------------------------+
#ifndef TRADINGPANEL_TRADEREPORT_MQH
#define TRADINGPANEL_TRADEREPORT_MQH

//--- Minimal JSON string escaping. Every other payload built elsewhere in
//--- this EA only interpolates broker-controlled strings (symbol names),
//--- which cannot contain a raw '"'. The free-text fields here (order/
//--- result comments) are user- or broker-supplied and can, so this
//--- guards against one bad comment corrupting an entire batch's JSON.
string CTradingPanelDialog::EscapeJsonString(string s)
{
   string result = "";
   int len = StringLen(s);
   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(s, i);
      if(ch == '"')       result += "\\\"";
      else if(ch == '\\') result += "\\\\";
      else if(ch == '\n') result += "\\n";
      else if(ch == '\r') result += "\\r";
      else if(ch == '\t') result += "\\t";
      else if(ch < 0x20)  continue; // strip other control chars
      else                result += StringSubstr(s, i, 1);
   }
   return result;
}

//+------------------------------------------------------------------+
//| 1. Candle context                                                 |
//+------------------------------------------------------------------+

//--- Decimation ladder: <1h -> M1, 1-5h -> M5, 5-10h -> M15, 10h-2d -> M30,
//--- 2d-5d -> H1, >5d -> no candles at all (MAX_CANDLE_TRADE_DURATION_DAYS,
//--- see TradingPanel.mq5) — beyond 5 days the payload isn't worth
//--- sending. Every bucket's upper bound is exclusive (exactly 5h lands in
//--- M15, not M5).
bool CTradingPanelDialog::CandleTimeframeForDuration(datetime openTime, datetime closeTime, ENUM_TIMEFRAMES &tf)
{
   long durationSec = (long)(closeTime - openTime);

   if(durationSec > MAX_CANDLE_TRADE_DURATION_DAYS * 86400)
      return false;

   if(durationSec < 3600)       { tf = PERIOD_M1;  return true; } // < 1h
   if(durationSec < 5 * 3600)   { tf = PERIOD_M5;  return true; } // 1h - 5h
   if(durationSec < 10 * 3600)  { tf = PERIOD_M15; return true; } // 5h - 10h
   if(durationSec < 2 * 86400)  { tf = PERIOD_M30; return true; } // 10h - 2d
   tf = PERIOD_H1;
   return true; // 2d - 5d (already excluded > 5d above)
}

string CTradingPanelDialog::TimeframeLabel(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      default:         return "M1";
   }
}

//--- One POST per closed trade, not batched across a whole sync cycle like
//--- the trade-sync JSON array itself, so a single request's payload size
//--- stays bounded to one trade's candle count. Independent of trade-sync
//--- success/failure — candles are stored backend-side keyed by their own
//--- (broker_account, ticket), not synchronously FK'd to that Trade row.
void CTradingPanelDialog::BuildAndPostTradeCandles(string symbol, string ticket, datetime openTime, datetime closeTime)
{
   ENUM_TIMEFRAMES tf;
   if(!CandleTimeframeForDuration(openTime, closeTime, tf))
   {
      if(EnableLogging) Print("Candle report: ticket ", ticket, " held longer than ", MAX_CANDLE_TRADE_DURATION_DAYS,
            " days - skipping candle context.");
      return;
   }

   //--- The closed trade's symbol may not be the chart's current symbol or
   //--- already in Market Watch — CopyRates silently returns nothing for a
   //--- symbol that isn't selected.
   if(!SymbolSelect(symbol, true))
   {
      if(EnableLogging) Print("Candle report: SymbolSelect failed for ", symbol, " (ticket ", ticket, ") - skipping.");
      return;
   }

   //--- CopyRates' start_time bound excludes any bar already in progress at
   //--- that exact moment — it only returns bars whose own start time is
   //--- >= start_time. openTime almost never lands exactly on a period
   //--- boundary, so without backing off by one full period, the bar
   //--- containing the trade's actual entry tick would be silently
   //--- excluded. Symmetrically, CopyRates only returns fully finalized
   //--- bars, so a bar covering time still in progress isn't in MT5's
   //--- history yet. Because this runs immediately after the trade closes
   //--- (the same OnTimer tick that detected it via
   //--- SyncClosedTradesIfDue), the bar covering the close moment is often
   //--- still forming — the retry below waits for it rather than stopping
   //--- short of the trade's own final move. Bounded to 3 short waits
   //--- (~2.25s worst case, only when needed).
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = 0;
   int periodSeconds = PeriodSeconds(tf);
   datetime fetchFrom = openTime - periodSeconds;
   for(int attempt = 0; attempt < 4; attempt++)
   {
      copied = CopyRates(symbol, tf, fetchFrom, closeTime, rates);
      if(copied > 0 && rates[copied - 1].time + periodSeconds > closeTime)
         break; // last bar's own period already extends past the close moment
      if(attempt < 3) Sleep(750);
   }
   if(copied <= 0)
   {
      if(EnableLogging) Print("Candle report: CopyRates returned ", copied, " row(s) for ", symbol, " ",
            TimeframeLabel(tf), " (ticket ", ticket, ") - skipping.");
      return;
   }

   //--- Safety net beyond the duration cap above: should be unreachable
   //--- given the ladder's bucketing, but guards against silently sending
   //--- a truncated series instead of the real one.
   if(copied > MAX_CANDLE_ROWS_PER_TRADE)
   {
      Print("Candle report: ticket ", ticket, " produced ", copied, " candle row(s) (> ", MAX_CANDLE_ROWS_PER_TRADE,
            ") at ", TimeframeLabel(tf), " - skipping rather than sending a truncated series.");
      return;
   }

   int symDigits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   string json = "{";
   json += "\"account_no\":\"" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\",";
   json += "\"ticket\":\"" + ticket + "\",";
   json += "\"symbol\":\"" + symbol + "\",";
   json += "\"broker_server\":\"" + EscapeJsonString(AccountInfoString(ACCOUNT_SERVER)) + "\",";
   json += "\"timeframe\":\"" + TimeframeLabel(tf) + "\",";
   json += "\"candles\":[";
   for(int i = 0; i < copied; i++)
   {
      if(i > 0) json += ",";
      json += "{";
      json += "\"timestamp\":\"" + ToIso8601(rates[i].time) + "\",";
      json += "\"open\":\"" + DoubleToString(rates[i].open, symDigits) + "\",";
      json += "\"high\":\"" + DoubleToString(rates[i].high, symDigits) + "\",";
      json += "\"low\":\"" + DoubleToString(rates[i].low, symDigits) + "\",";
      json += "\"close\":\"" + DoubleToString(rates[i].close, symDigits) + "\",";
      json += "\"tick_volume\":\"" + IntegerToString(rates[i].tick_volume) + "\",";
      json += "\"spread\":\"" + IntegerToString(rates[i].spread) + "\",";
      json += "\"real_volume\":\"" + IntegerToString(rates[i].real_volume) + "\"";
      json += "}";
   }
   json += "]}";

   string url = ApiBaseUrl + "candles/";
   string headers = "Content-Type: application/json\r\nX-API-Key: " + ApiKey + "\r\n";
   char data[];
   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1);
   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("POST", url, headers, 5000, data, result, resultHeaders);

   if(status == -1)
   {
      int err = GetLastError();
      if(EnableLogging) Print("Candle report failed: WebRequest error ", err, " for ticket ", ticket,
            " (", symbol, " ", TimeframeLabel(tf), ", ", copied, " row(s))");
      return;
   }

   if(EnableLogging) Print("Candle report: sent ", copied, " ", TimeframeLabel(tf), " candle(s) for ticket ", ticket,
         " (", symbol, "), HTTP ", status);
}

//+------------------------------------------------------------------+
//| 2. Closed-position lifecycle capture                              |
//+------------------------------------------------------------------+

//--- Filters OnTradeTransaction's firehose (fires for every order/deal/
//--- position event on the account) down to just "a position fully
//--- closed": TRADE_TRANSACTION_DEAL_ADD alone isn't enough, since it
//--- fires identically for an opening deal, a partial close, and the
//--- final close. DEAL_ENTRY_OUT/OUT_BY narrows to a closing deal
//--- specifically; PositionSelectByTicket then failing confirms nothing of
//--- the position remains open (a partial close would still leave it
//--- selectable).
//---
//--- A confirmed close triggers two independent things, each gated on its
//--- own input: m_closeSyncPending is set unconditionally (checked from
//--- OnTimer — see its own comment) so SyncClosedTradesIfDue runs shortly
//--- after any close, keeping the Trade-row/journal data current without
//--- waiting for a manual Sync click; the lifecycle payload below is only
//--- built/queued when EnableTransactionReporting is on, since that's a
//--- separate, optional raw-event audit feed. Deliberately no WebRequest
//--- directly in this callback — see BuildClosedPositionLifecycleJson and
//--- FlushPendingTradePostsIfDue for why the actual sends happen later,
//--- from OnTimer.
void CTradingPanelDialog::CheckForPositionCloseAndHandle(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   //--- Diagnostic tracing: every early return below logs why, so a real
   //--- close's path through this filter is visible in the Experts log.
   //--- This fires on every transaction the account produces, not just
   //--- closes, so keep EnableLogging off in production unless actively
   //--- diagnosing close detection.
   if(StringLen(ApiKey) == 0)
   {
      if(EnableLogging) Print("[lifecycle debug] skipped: ApiKey is empty.");
      return; // no point building a payload that can only fail to send
   }
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
   {
      if(EnableLogging) Print("[lifecycle debug] ignored: trans.type=", EnumToString(trans.type), " (not DEAL_ADD).");
      return;
   }
   if(trans.position == 0)
   {
      if(EnableLogging) Print("[lifecycle debug] ignored: deal ", trans.deal, " has no position.");
      return;
   }
   if(!HistoryDealSelect(trans.deal))
   {
      if(EnableLogging) Print("[lifecycle debug] deal ", trans.deal, " not yet visible in history - skipping.");
      return; // not visible in history yet — rare
   }

   long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY)
   {
      if(EnableLogging) Print("[lifecycle debug] deal ", trans.deal, " (position ", trans.position, ") entry=",
            EnumToString((ENUM_DEAL_ENTRY)dealEntry), " - an open/add-to, not a close.");
      return; // an opening/add-to deal, not a close
   }

   if(PositionSelectByTicket(trans.position))
   {
      if(EnableLogging) Print("[lifecycle debug] position ", trans.position, " still open after deal ", trans.deal,
            " - a partial close, waiting for the final one.");
      return; // still open — a partial close, not the final one
   }

   if(EnableLogging) Print("[lifecycle debug] position ", trans.position, " confirmed closed by deal ", trans.deal,
         " - triggering trade sync and building lifecycle payload.");

   //--- Trade sync (the Trade-row/journal data, separate from the raw
   //--- lifecycle event feed below) is deferred to the next OnTimer tick
   //--- rather than called directly here: BuildAndPostClosedTrades can fire
   //--- multiple blocking WebRequest calls (one for the trade batch, one
   //--- per trade for candles, each with its own retry sleeps) — too much
   //--- for this synchronous callback.
   m_closeSyncPending = true;

   if(!EnableTransactionReporting) return; // lifecycle event feed opted out — the sync trigger above still applies

   string payload = BuildClosedPositionLifecycleJson(trans.position, trans.deal, result);
   if(payload == "")
   {
      if(EnableLogging) Print("[lifecycle debug] position ", trans.position,
            ": BuildClosedPositionLifecycleJson returned empty - HistorySelectByPosition found nothing to send.");
      return; // HistorySelectByPosition found nothing (shouldn't happen, but see that function's own comment)
   }

   int n = ArraySize(m_pendingTradePosts);
   if(n >= MAX_TRADE_POST_QUEUE)
   {
      //--- Queue full (backend unreachable for a while) — drop the oldest
      //--- entry to make room rather than growing without bound. Logged
      //--- every time so a trader can tell from the Experts log if a
      //--- position's lifecycle report was lost.
      if(EnableLogging) Print("Trade lifecycle queue full (", MAX_TRADE_POST_QUEUE, ") - dropping oldest entry.");
      for(int i = 0; i < n - 1; i++)
         m_pendingTradePosts[i] = m_pendingTradePosts[i + 1];
      n--;
      ArrayResize(m_pendingTradePosts, n);
   }

   SPendingTradePost post;
   post.payload         = payload;
   post.attempts        = 0;
   post.nextAttemptTime = TimeCurrent(); // due immediately — sent on the very next OnTimer tick
   ArrayResize(m_pendingTradePosts, n + 1);
   m_pendingTradePosts[n] = post;
   if(EnableLogging) Print("[lifecycle debug] position ", trans.position, ": payload queued (", StringLen(payload),
         " chars) - will send on the next OnTimer tick.");
}

//--- Rebuilds a closed position's whole order/deal history from MT5 itself
//--- (HistorySelectByPosition) into the same flat JSON array shape
//--- /mt5/trade-transactions/ already expects from the live per-event
//--- payload this replaces — same field names, same enum vocabulary for
//--- "type" (ORDER_ADD / DEAL_ADD) — so the backend needs no changes. One
//--- row per order and per deal that ever belonged to this position, in
//--- the order MT5's history returns them.
//---
//--- retcode/result_comment are the broker's response to a specific send:
//--- transient, live-callback-only data MT5's history never persists, so
//--- they are populated only for triggerDeal (the one close this callback
//--- has a live MqlTradeResult for); every other reconstructed row leaves
//--- them blank. Similarly, price_sl/price_tp/price_trigger are order/
//--- position-level concepts, not deal-level ones, so deal rows leave them
//--- blank too, matching what a live TRADE_TRANSACTION_DEAL_ADD event
//--- would produce.
string CTradingPanelDialog::BuildClosedPositionLifecycleJson(long positionId, long triggerDeal, const MqlTradeResult &triggerResult)
{
   if(!HistorySelectByPosition(positionId)) return "";

   long accountLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   string json = "[";
   bool first = true;

   int orderTotal = HistoryOrdersTotal();
   for(int i = 0; i < orderTotal; i++)
   {
      ulong ticket = HistoryOrderGetTicket(i);
      if(ticket == 0) continue;

      if(!first) json += ",";
      first = false;

      string symbol = HistoryOrderGetString(ticket, ORDER_SYMBOL);
      int digits = (symbol != "") ? (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS) : 8;

      json += "{";
      json += "\"account_no\":\"" + IntegerToString(accountLogin) + "\",";
      json += "\"type\":\"ORDER_ADD\",";
      json += "\"order\":\"" + IntegerToString((long)ticket) + "\",";
      json += "\"deal\":\"0\",";
      json += "\"position\":\"" + IntegerToString(positionId) + "\",";
      json += "\"position_by\":\"0\",";
      json += "\"symbol\":\"" + symbol + "\",";
      json += "\"order_type\":\"" + EnumToString((ENUM_ORDER_TYPE)HistoryOrderGetInteger(ticket, ORDER_TYPE)) + "\",";
      json += "\"order_state\":\"" + EnumToString((ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE)) + "\",";
      json += "\"deal_type\":\"\",";
      json += "\"price\":\"" + DoubleToString(HistoryOrderGetDouble(ticket, ORDER_PRICE_OPEN), digits) + "\",";
      json += "\"price_sl\":\"" + DoubleToString(HistoryOrderGetDouble(ticket, ORDER_SL), digits) + "\",";
      json += "\"price_tp\":\"" + DoubleToString(HistoryOrderGetDouble(ticket, ORDER_TP), digits) + "\",";
      json += "\"price_trigger\":\"" + DoubleToString(HistoryOrderGetDouble(ticket, ORDER_PRICE_STOPLIMIT), digits) + "\",";
      json += "\"volume\":\"" + DoubleToString(HistoryOrderGetDouble(ticket, ORDER_VOLUME_INITIAL), 2) + "\",";
      json += "\"magic\":\"" + IntegerToString(HistoryOrderGetInteger(ticket, ORDER_MAGIC)) + "\",";
      json += "\"comment\":\"" + EscapeJsonString(HistoryOrderGetString(ticket, ORDER_COMMENT)) + "\",";
      json += "\"retcode\":\"\",";
      json += "\"result_comment\":\"\",";
      json += "\"event_time\":\"" + ToIso8601((datetime)HistoryOrderGetInteger(ticket, ORDER_TIME_DONE)) + "\"";
      json += "}";
   }

   int dealTotal = HistoryDealsTotal();
   for(int i = 0; i < dealTotal; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      if(!first) json += ",";
      first = false;

      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      int digits = (symbol != "") ? (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS) : 8;
      bool isTrigger = ((long)ticket == triggerDeal);

      json += "{";
      json += "\"account_no\":\"" + IntegerToString(accountLogin) + "\",";
      json += "\"type\":\"DEAL_ADD\",";
      json += "\"order\":\"" + IntegerToString(HistoryDealGetInteger(ticket, DEAL_ORDER)) + "\",";
      json += "\"deal\":\"" + IntegerToString((long)ticket) + "\",";
      json += "\"position\":\"" + IntegerToString(positionId) + "\",";
      json += "\"position_by\":\"" + IntegerToString(HistoryDealGetInteger(ticket, DEAL_POSITION_ID)) + "\",";
      json += "\"symbol\":\"" + symbol + "\",";
      json += "\"order_type\":\"\",";
      json += "\"order_state\":\"\",";
      json += "\"deal_type\":\"" + EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE)) + "\",";
      json += "\"price\":\"" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PRICE), digits) + "\",";
      json += "\"price_sl\":\"\",";
      json += "\"price_tp\":\"\",";
      json += "\"price_trigger\":\"\",";
      json += "\"volume\":\"" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_VOLUME), 2) + "\",";
      json += "\"magic\":\"" + IntegerToString(HistoryDealGetInteger(ticket, DEAL_MAGIC)) + "\",";
      json += "\"comment\":\"" + EscapeJsonString(HistoryDealGetString(ticket, DEAL_COMMENT)) + "\",";
      json += "\"retcode\":\"" + (isTrigger ? IntegerToString(triggerResult.retcode) : "") + "\",";
      json += "\"result_comment\":\"" + (isTrigger ? EscapeJsonString(triggerResult.comment) : "") + "\",";
      json += "\"event_time\":\"" + ToIso8601((datetime)HistoryDealGetInteger(ticket, DEAL_TIME)) + "\"";
      json += "}";
   }

   json += "]";
   return first ? "" : json; // first never flipped to false -> nothing was actually appended
}

//--- Sends (or retries) at most one queued closed-position lifecycle
//--- payload per call, deliberately not a loop over the whole queue.
//--- WebRequest blocks for up to 5s on failure/timeout; bounding each
//--- OnTimer tick to one such call spreads several near-simultaneous
//--- position closes across several ticks instead of compounding into one
//--- long freeze. A failed send is rescheduled MAX(PollingIntervalSeconds,
//--- 10) seconds out (see MAX_TRADE_POST_ATTEMPTS's own comment in
//--- TradingPanel.mq5) rather than retried immediately, for the same
//--- reason.
void CTradingPanelDialog::FlushPendingTradePostsIfDue()
{
   int total = ArraySize(m_pendingTradePosts);
   if(total == 0) return;

   int idx = -1;
   for(int i = 0; i < total; i++)
   {
      if(m_pendingTradePosts[i].nextAttemptTime <= TimeCurrent()) { idx = i; break; }
   }
   if(idx < 0) return; // nothing due yet - every queued entry is still waiting out its retry delay

   string url = ApiBaseUrl + "trade-transactions/";
   string headers = "Content-Type: application/json\r\nX-API-Key: " + ApiKey + "\r\n";
   char data[];
   StringToCharArray(m_pendingTradePosts[idx].payload, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1);
   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("POST", url, headers, 5000, data, result, resultHeaders);
   m_pendingTradePosts[idx].attempts++;

   if(status != -1)
   {
      //--- WebRequest returning != -1 only means the HTTP round-trip itself
      //--- succeeded — it says nothing about whether the backend actually
      //--- accepted/stored the payload (a 200 with an error body, or a
      //--- 400/403 with a specific reason, are all "success" by this
      //--- check). The response body is where the actual outcome lives
      //--- (see api_sync_trade_transactions/
      //--- TradeTransactionService.ingest_from_json in the backend, which
      //--- always returns a JSON {status, message, ...} object).
      string responseBody = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      if(EnableLogging) Print("Trade lifecycle post: sent, HTTP ", status, " (attempt ", m_pendingTradePosts[idx].attempts,
            "). Response body: ", responseBody);
      for(int i = idx; i < total - 1; i++)
         m_pendingTradePosts[i] = m_pendingTradePosts[i + 1];
      ArrayResize(m_pendingTradePosts, total - 1);
      return;
   }

   int err = GetLastError();
   if(m_pendingTradePosts[idx].attempts >= MAX_TRADE_POST_ATTEMPTS)
   {
      Print("Trade lifecycle post: giving up after ", m_pendingTradePosts[idx].attempts, " attempt(s) - WebRequest error ", err,
            " for ", url, ". Dropping this entry.");
      for(int i = idx; i < total - 1; i++)
         m_pendingTradePosts[i] = m_pendingTradePosts[i + 1];
      ArrayResize(m_pendingTradePosts, total - 1);
      return;
   }

   int retryDelaySec = MathMax(PollingIntervalSeconds, 10);
   m_pendingTradePosts[idx].nextAttemptTime = TimeCurrent() + retryDelaySec;
   if(EnableLogging) Print("Trade lifecycle post failed: WebRequest error ", err, " for ", url,
         " - retry ", m_pendingTradePosts[idx].attempts, "/", MAX_TRADE_POST_ATTEMPTS, " in ", retryDelaySec, "s.");
}

#endif // TRADINGPANEL_TRADEREPORT_MQH
