//+------------------------------------------------------------------+
//|                                     TradingPanelRiskSync.mqh     |
//|  Out-of-line CTradingPanelDialog method bodies (see TradingPanel |
//|  .mq5 for the class declaration and split rationale) for the     |
//|  backend risk-parameter poll: GET /mt5/last-sync/, the flat-JSON |
//|  string parsing it relies on, the account-currency and           |
//|  broker-timezone auto-verify cross-checks, the risk-limits card  |
//|  display, and the periodic "still alive" heartbeat.              |
//+------------------------------------------------------------------+
#ifndef TRADINGPANEL_RISKSYNC_MQH
#define TRADINGPANEL_RISKSYNC_MQH

//--- Backend responses on this endpoint are deliberately flat, one-level
//--- JSON of quoted string values only (see poller_service.py's own
//--- comment on that contract): never nested, never a bare number/bool/
//--- null literal. That contract is what makes a simple substring scan
//--- safe in place of a full JSON library: find "key", the next ':'
//--- after it, the next '"' after that (skipping any whitespace the
//--- renderer might add after the colon), then read to the closing '"'.
bool CTradingPanelDialog::JsonExtractString(const string json, const string key, string &outValue)
{
   string keyToken = "\"" + key + "\"";
   int keyPos = StringFind(json, keyToken);
   if(keyPos < 0) return false;

   int colonPos = StringFind(json, ":", keyPos + StringLen(keyToken));
   if(colonPos < 0) return false;

   int quoteStart = StringFind(json, "\"", colonPos + 1);
   if(quoteStart < 0) return false;
   quoteStart++;

   int quoteEnd = StringFind(json, "\"", quoteStart);
   if(quoteEnd < 0) return false;

   outValue = StringSubstr(json, quoteStart, quoteEnd - quoteStart);
   return true;
}

//--- MT5 exposes no direct "broker timezone" API. This is the standard
//--- MQL5 technique for deriving the broker (trade) server's current UTC
//--- offset instead: TimeTradeServer() is the server's wall-clock time;
//--- TimeGMT() is the terminal's computed UTC, based on the local
//--- machine's OS timezone. The difference is the server's live UTC
//--- offset, reported to the backend so it can attempt to auto-verify
//--- broker_account.timezone (see verify_and_sync_broker_timezone on the
//--- backend for the conservative matching rules that govern it).
int CTradingPanelDialog::BrokerUtcOffsetMinutes()
{
   return (int)((TimeTradeServer() - TimeGMT()) / 60);
}

//--- GET /mt5/last-sync/ — the lightweight polling endpoint (see
//--- ApiBaseUrl's own comment for the required WebRequest whitelist
//--- step). Preferred over POST /mt5/sync/ for this periodic check since
//--- it needs no trade-history body; the backend returns the account's
//--- risk parameters on every response from this endpoint regardless of
//--- outcome, keyed only on the API key's owner. Returns false on a
//--- transport failure, or if the response didn't carry risk-parameter
//--- fields at all (e.g. an auth failure, whose body is DRF's generic
//--- error shape rather than ours).
bool CTradingPanelDialog::PollRiskParameters()
{
   if(StringLen(ApiKey) == 0)
   {
      m_riskParamsError = "API key not set - polling halted (see EA inputs)";
      //--- Not gated on EnableLogging: with no popup backing this, the log
      //--- is the only way a trader who hits this finds out why nothing is
      //--- working. Same reasoning applies to the other popup-less
      //--- halt/failure reasons below.
      Print("Risk parameter fetch skipped: ApiKey input is empty. Halting polling until the EA reinitializes.");
      m_riskPollingHalted = true;
      return false;
   }

   long accountLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   int brokerOffsetMinutes = BrokerUtcOffsetMinutes();
   string url = ApiBaseUrl + "last-sync/?account_number=" + IntegerToString(accountLogin) +
                "&mt5_utc_offset_minutes=" + IntegerToString(brokerOffsetMinutes);
   string headers = "X-API-Key: " + ApiKey + "\r\n";
   char data[];
   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("GET", url, headers, 5000, data, result, resultHeaders);

   if(status == -1)
   {
      int err = GetLastError();
      if(err == 4060)
      {
         //--- Kept short on-panel (this label has limited width); the full
         //--- instruction goes to the Experts log instead.
         m_riskParamsError = "WebRequest not whitelisted - see Experts log";
         Print("Risk parameter fetch blocked (error 4060): add ", ApiBaseUrl,
               " to Tools > Options > Expert Advisors > Allow WebRequest for listed URL");
      }
      else
      {
         m_riskParamsError = StringFormat("WebRequest failed (error %d) - see Experts log", err);
         Print("Risk parameter fetch failed: WebRequest error ", err, " for ", url);
      }
      return false;
   }

   string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   string val;
   bool any = false;
   //--- Missing fields are collected into one combined line rather than one
   //--- Print per field; under normal operation every field is present and
   //--- this stays silent, firing only when the backend response is
   //--- genuinely malformed.
   string missingFields = "";
   if(JsonExtractString(response, "risk_per_trade_percent", val))     { m_riskPerTradePercent = StringToDouble(val); any = true; } else missingFields += "risk_per_trade_percent ";
   if(JsonExtractString(response, "use_fixed_lot", val))              { m_useFixedLot = (val == "True" || val == "true"); any = true; } else missingFields += "use_fixed_lot ";
   //--- No empty-string-to-sentinel ternary needed below: MQL5's
   //--- StringToDouble("")/StringToInteger("") already return 0, which is
   //--- the "off" sentinel (see the member declarations' own comment) — a
   //--- blank backend field and a literal 0 parse identically.
   if(JsonExtractString(response, "fixed_lot_size", val))             { m_fixedLotSize = StringToDouble(val); any = true; } else missingFields += "fixed_lot_size ";
   if(JsonExtractString(response, "max_risk_per_trade_percent", val)) { m_maxRiskPerTradePercent = StringToDouble(val); any = true; } else missingFields += "max_risk_per_trade_percent ";
   if(JsonExtractString(response, "max_daily_loss_percent", val))     { m_maxDailyLossPercent = StringToDouble(val); any = true; } else missingFields += "max_daily_loss_percent ";
   if(JsonExtractString(response, "max_open_positions", val))         { m_maxOpenPositions = (int)StringToInteger(val); any = true; } else missingFields += "max_open_positions ";
   if(JsonExtractString(response, "min_risk_reward_ratio", val))      { m_minRiskRewardRatio = StringToDouble(val); any = true; } else missingFields += "min_risk_reward_ratio ";
   if(JsonExtractString(response, "max_consecutive_losses", val))     { m_maxConsecutiveLosses = (int)StringToInteger(val); any = true; } else missingFields += "max_consecutive_losses ";
   if(missingFields != "") // not gated: a malformed response is worth surfacing regardless
      Print("Risk parameter fetch: response is missing field(s): ", missingFields);

   //--- account_currency is never used as a display source (every money
   //--- label reads AccountInfoString(ACCOUNT_CURRENCY) directly — see
   //--- OrderPanelBase's own comment on m_hdrMoney). It is used purely as
   //--- a sanity cross-check against MT5's own value: if the web app's
   //--- BrokerAccount.currency setting has drifted from what this MT5
   //--- account is actually denominated in, every risk-sizing figure the
   //--- trader sees is still numerically correct but mislabeled, which is
   //--- worth surfacing rather than trusting either side silently.
   string currencyVal;
   if(JsonExtractString(response, "account_currency", currencyVal) && currencyVal != "")
   {
      string mt5Currency = AccountInfoString(ACCOUNT_CURRENCY);
      if(currencyVal != mt5Currency)
      {
         string mismatchMsg = StringFormat(
            "Currency mismatch: the web app's broker account is set to %s, but this MT5 account is actually denominated in %s. "
            "Fix the broker account's currency in the web app, then restart the EA.",
            currencyVal, mt5Currency
         );
         m_riskParamsError = "Currency mismatch - polling halted (see popup)";
         if(EnableLogging) Print("Risk parameter fetch: ", mismatchMsg, " - halting polling until the EA reinitializes.");
         MessageBox(mismatchMsg, "Account Currency Mismatch", MB_ICONWARNING);
         m_riskPollingHalted = true;
         return false;
      }
   }

   //--- "No BrokerAccount found for this account number" is a config
   //--- problem on the web app side, not a transient failure — retrying
   //--- every PollingIntervalSeconds won't fix it. Checked before the
   //--- "!any" block below because this response still carries every other
   //--- risk-parameter field (see build_risk_parameters_payload's own
   //--- comment; it depends only on the authenticated user, not on this
   //--- account number resolving), so "any" would otherwise be true and
   //--- this error would pass as a normal successful poll. A MessageBox is
   //--- used deliberately here, since this needs the trader to go fix
   //--- something in the web app rather than just read the Experts log.
   //--- Halting (see m_riskPollingHalted) keeps the popup to exactly once
   //--- instead of reappearing every poll cycle.
   string errorCode;
   if(JsonExtractString(response, "error_code", errorCode) && errorCode == "broker_account_not_found")
   {
      string notFoundMsg;
      JsonExtractString(response, "message", notFoundMsg);
      if(notFoundMsg == "") notFoundMsg = "No broker account found for this MT5 account number.";

      m_riskParamsError = "Broker account not found - polling halted (see popup)";
      if(EnableLogging) Print("Risk parameter fetch: ", notFoundMsg, " - halting polling until the EA reinitializes.");
      MessageBox(notFoundMsg, "Broker Account Not Found", MB_ICONWARNING);
      m_riskPollingHalted = true;
      return false;
   }

   if(!any)
   {
      string msg;
      JsonExtractString(response, "message", msg);

      //--- A response with no risk-parameter fields and a 401/403 status is
      //--- DRF's generic auth-failure body: the API key was rejected, not
      //--- some other transient error. Halt polling rather than retrying
      //--- forever with a key that will never start working.
      if(status == 401 || status == 403)
      {
         m_riskParamsError = "API key rejected - polling halted (see EA inputs)";
         Print("Risk parameter fetch: API key rejected (HTTP ", status, ")",
               (msg != "" ? (" (message: " + msg + ")") : ""),
               " - halting polling until the EA reinitializes.");
         m_riskPollingHalted = true;
         return false;
      }

      //--- Kept short on-panel; full body included here since this is a
      //--- genuinely abnormal response (not the routine happy path) and
      //--- worth the detail to diagnose.
      m_riskParamsError = StringFormat("HTTP %d but no risk data - see Experts log", status);
      Print("Risk parameter fetch: response had no risk-parameter fields at all",
            (msg != "" ? (" (message: " + msg + ")") : ""),
            " - is the backend deployment up to date? Body: ", response);
      return false;
   }

   m_riskParamsError = "";
   return true;
}

//--- Mirrors the web app's own Risk Parameters page: three cards (Position
//--- Sizing / Account Guardrails / Advice Targets) in the same grouping,
//--- so a trader who has seen that page recognizes this layout. Uses
//--- plain "+" concatenation rather than StringFormat, since MQL5's
//--- StringFormat mis-parses once a %s-substituted value itself contains a
//--- raw '%' character (e.g. "2.00%", exactly what these percent fields
//--- produce) — everything after that substitution silently vanishes.
//--- Greedy word-wrap for a risk card's three fixed-width line slots
//--- (m_riskCardLine[cardIdx][0..2]): these are plain CLabel controls with
//--- no built-in wrapping, so text longer than the card's ~177px width
//--- (see cardW) would otherwise be clipped by MT5. maxCharsPerLine=24 is
//--- a character-count approximation with a safety margin below "Max Open
//--- Positions: none" (25 chars), the longest string this function
//--- currently renders. Any line still too long after wrapping is
//--- truncated rather than allowed to overflow the card.
void CTradingPanelDialog::SetWrappedCardLines(int cardIdx, string fullText, int maxCharsPerLine)
{
   string words[];
   int wordCount = StringSplit(fullText, ' ', words);

   string lines[3] = {"", "", ""};
   int lineIdx = 0;
   for(int w = 0; w < wordCount && lineIdx < 3; w++)
   {
      string candidate = (lines[lineIdx] == "") ? words[w] : (lines[lineIdx] + " " + words[w]);
      if(StringLen(candidate) <= maxCharsPerLine || lines[lineIdx] == "")
      {
         lines[lineIdx] = candidate;
      }
      else
      {
         lineIdx++;
         if(lineIdx < 3) lines[lineIdx] = words[w];
      }
   }

   for(int l = 0; l < 3; l++)
   {
      string text = lines[l];
      if(StringLen(text) > maxCharsPerLine) text = StringSubstr(text, 0, maxCharsPerLine);
      m_riskCardLine[cardIdx][l].Text(text);
   }
}

void CTradingPanelDialog::UpdateRiskLimitsLabel()
{
   if(!m_riskParamsLoaded)
   {
      SetWrappedCardLines(0, m_riskParamsError != "" ? m_riskParamsError : "Loading...");
      for(int l = 0; l < 3; l++)
         m_riskCardLine[0][l].Color(clrGray);
      for(int c = 1; c < 3; c++)
         for(int l = 0; l < 3; l++)
            m_riskCardLine[c][l].Text("");
      return;
   }

   string riskPct   = DoubleToString(m_riskPerTradePercent, 2) + "%";
   string fixedLot  = !m_useFixedLot ? "Off" : (m_fixedLotSize <= 0.0 ? "On" : (DoubleToString(m_fixedLotSize, 2) + " lots"));
   string maxRisk   = (m_maxRiskPerTradePercent <= 0.0) ? "none" : (DoubleToString(m_maxRiskPerTradePercent, 2) + "%");
   string dailyLoss = (m_maxDailyLossPercent <= 0.0)    ? "none" : (DoubleToString(m_maxDailyLossPercent, 2) + "%");
   string openPos   = (m_maxOpenPositions <= 0)          ? "none" : IntegerToString(m_maxOpenPositions);
   string minRR     = DoubleToString(m_minRiskRewardRatio, 2);
   string maxLosses = (m_maxConsecutiveLosses <= 0)      ? "none" : IntegerToString(m_maxConsecutiveLosses);

   m_riskCardLine[0][0].Text("Risk/Trade: " + riskPct);
   m_riskCardLine[0][1].Text("Fixed Lot: " + fixedLot);
   m_riskCardLine[0][2].Text("");

   m_riskCardLine[1][0].Text("Max Risk/Trade: " + maxRisk);
   m_riskCardLine[1][1].Text("Max Daily Loss: " + dailyLoss);
   m_riskCardLine[1][2].Text("Max Open Positions: " + openPos);

   m_riskCardLine[2][0].Text("Min R:R: " + minRR);
   m_riskCardLine[2][1].Text("Loss Cooldown: " + maxLosses);
   m_riskCardLine[2][2].Text("");

   for(int c = 0; c < 3; c++)
      for(int l = 0; l < 3; l++)
         m_riskCardLine[c][l].Color(C'90,90,90');
}

//--- Not polled on any interval: periodic WebRequest calls were dropped
//--- after they were found to make the panel feel sticky (see the top of
//--- TradingPanel.mq5). Called exactly twice: once from CreatePanel() (the
//--- initial fetch) and once per click of the "Sync" button
//--- (OnClickSync) — never on a timer. m_lastRiskPollTime is kept only as
//--- a "when did this last succeed" readout, not a gate.
void CTradingPanelDialog::RefreshRiskParametersIfDue()
{
   //--- See m_riskPollingHalted's own comment: a missing or rejected API
   //--- key cannot self-correct by retrying, so stop calling WebRequest
   //--- until CreatePanel() runs again on a genuine EA reinitialization.
   if(m_riskPollingHalted) return;

   m_lastRiskPollTime = TimeCurrent();

   if(PollRiskParameters())
   {
      //--- Keep the Risk % field mirroring the account's configured
      //--- default on every successful poll, not just the first, since the
      //--- trader may change risk_per_trade_percent on the web app at any
      //--- time. Skipped in fixed-lot mode, where the field is already a
      //--- read-only readout of the implied risk from the fixed lot size
      //--- (see EnforceVolumeRiskLimit/ApplyFixedLotMode, which manages it
      //--- independently). Also skipped while m_riskLocked — see its own
      //--- comment: a trader-entered custom value must survive poll cycles
      //--- until explicitly unlocked or used in a trade.
      if(!IsFixedLotMode() && !m_riskLocked)
      {
         string newRiskText = DoubleToString(m_riskPerTradePercent, 2);
         //--- Only log and write to the control when the value actually
         //--- changes; otherwise an unchanging risk setting would flood
         //--- the log every PollingIntervalSeconds.
         if(newRiskText != m_editRisk.Text())
         {
            if(EnableLogging) Print("Risk parameters synced - Max Risk % changed to ", newRiskText, "%");
            m_editRisk.Text(newRiskText);
         }
      }
      m_riskParamsLoaded = true;
      ApplyRiskCeiling();
      EnforceVolumeRiskLimit(); // the Risk % field may have just changed
   }
   // else: PollRiskParameters() already logged the specific reason itself
   UpdateRiskLimitsLabel();
}

//--- The panel's "Sync" button (see its own comment in CreatePanel). One
//--- manual click does both: pulls the latest risk parameters, and
//--- back-fills any closed trades since the watermark
//--- (SyncClosedTradesIfDue). Both calls run once and return; neither
//--- polls on a timer. Both are already individually gated on
//--- ApiKey/m_riskPollingHalted — the checks here exist to give the
//--- trader an immediate, specific reason via MessageBox instead of a
//--- silent no-op when Sync is clicked with nothing configured.
void CTradingPanelDialog::OnClickSync()
{
   if(StringLen(ApiKey) == 0)
   {
      MessageBox("Set an API key in the EA inputs before syncing.", "Sync", MB_ICONWARNING);
      return;
   }
   if(m_riskPollingHalted)
   {
      MessageBox("Syncing is halted: " + m_riskParamsError + ". Fix the underlying issue, then reattach the EA.", "Sync", MB_ICONWARNING);
      return;
   }

   if(EnableLogging) Print("Manual sync requested.");
   RefreshRiskParametersIfDue();
   SyncClosedTradesIfDue();
}

//--- One concise "still alive and healthy" line, printed on a much longer
//--- cadence (HEARTBEAT_INTERVAL_SECONDS) than the underlying polling —
//--- the log's answer to "is the EA actually running" without wading
//--- through routine per-poll activity logging. Respects EnableLogging
//--- like every other routine log line in this file.
void CTradingPanelDialog::EmitHeartbeatIfDue()
{
   if(!EnableLogging) return;
   if(TimeCurrent() - m_lastHeartbeatTime < HEARTBEAT_INTERVAL_SECONDS) return;
   m_lastHeartbeatTime = TimeCurrent();

   if(m_riskPollingHalted)
   {
      Print("EA heartbeat: HALTED - ", m_riskParamsError, " (fix the underlying issue, then reattach the EA to resume)");
      return;
   }

   Print("EA heartbeat: running OK - account=", AccountInfoInteger(ACCOUNT_LOGIN),
         ", symbol=", m_comboSymbol.Select(),
         ", risk_params_loaded=", m_riskParamsLoaded,
         ", risk_per_trade=", DoubleToString(m_riskPerTradePercent, 2), "%",
         ", volume=", m_editVolume.Text(),
         ", equity=", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
}

#endif // TRADINGPANEL_RISKSYNC_MQH
