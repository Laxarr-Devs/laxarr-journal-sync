//+------------------------------------------------------------------+
//|                                    TradingPanelGuardrails.mqh    |
//|  Out-of-line CTradingPanelDialog method bodies (see TradingPanel |
//|  .mq5 for the class declaration and split rationale) for the     |
//|  account-wide risk guardrails: max daily loss (checked every     |
//|  tick, independent of Execute), consecutive-loss cooldown, and   |
//|  the pre-Execute blocking check — plus the Execute click flow    |
//|  itself (confirmation dialog, then lock/guardrail wiring).       |
//+------------------------------------------------------------------+
#ifndef TRADINGPANEL_GUARDRAILS_MQH
#define TRADINGPANEL_GUARDRAILS_MQH

//--- Volume is read-only and always held at the risk-based ceiling (see
//--- EnforceVolumeRiskLimit, called every tick), so it needs no
//--- over-limit check here. Account-level limits (max open positions,
//--- max daily loss) are a separate gate, checked fresh via
//--- CheckRiskLimitsBlocking.
void CTradingPanelDialog::OnClickExecute()
{
   if(EnableLogging) Print("Execute clicked (", EnumToString(m_activeKind), ", ", ActivePanel().GetActiveTab() == TAB_BUY ? "BUY" : "SELL", ")");
   string blockReason = CheckRiskLimitsBlocking();
   if(blockReason != "")
   {
      MessageBox(blockReason, "Trade Blocked", MB_ICONWARNING);
      return;
   }

   //--- MB_DEFBUTTON2 makes "No" the default button, so an accidental
   //--- Enter/Space cannot fire a real trade.
   int confirm = MessageBox(BuildTradeConfirmationMessage(), "Confirm Trade",
                             MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2);
   if(confirm != IDYES)
   {
      if(EnableLogging) Print("Execute cancelled by trader at confirmation prompt.");
      return;
   }

   ActivePanel().OnExecute();
   //--- Hide this panel's chart lines so the just-filled SL/TP/Entry lines
   //--- don't linger as if the order were still pending. Set before
   //--- ResetPanel() so its reseed redraws nothing (RefreshVisuals checks
   //--- m_linesVisible); lines stay hidden until ToggleLines is used again.
   ActivePanel().SetLinesVisible(false);
   m_btnToggleLines.Text("Show Lines");
   //--- The custom Risk % has been consumed by the trade it was set for —
   //--- release the lock so the field resumes tracking the account default.
   SetRiskLocked(false);
   //--- The trade has used up this panel's staged SL/TP/Limit/Stop levels —
   //--- clear the chart drawings and reseed fresh SL/TP1-3 (see ResetPanel
   //--- in TradingPanelUI.mqh).
   ResetPanel();
}

//--- Summarizes exactly what Execute is about to place. PriceOf/PipsOf/
//--- MoneyOf/LotOf/RRof are the same accessors the on-screen Price/Pips/
//--- $/Lot/R:R columns read from, so this message can never diverge from
//--- what the trader was looking at. Built with StringFormat; safe here
//--- since none of the substituted values contain a raw '%' character.
string CTradingPanelDialog::BuildTradeConfirmationMessage()
{
   COrderPanelBase *panel = ActivePanel();
   string dir = (panel.GetActiveTab() == TAB_BUY) ? "BUY" : "SELL";
   string sym = panel.CurrentSymbol();
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   int volDigits = VolumeDigits(sym);

   string msg = StringFormat("%s %s %s\n", OrderKindLabel(m_activeKind), dir, sym);
   msg += StringFormat("Entry: %s\n", DoubleToString(panel.GetReferencePrice(), digits));
   msg += StringFormat("Volume: %s lots   |   Risk: %s%%\n\n",
                        DoubleToString(panel.Lots(), volDigits),
                        DoubleToString(StringToDouble(m_editRisk.Text()), 2));

   msg += StringFormat("SL: %s   (%s pips, potential loss %s %s)\n",
                        DoubleToString(panel.PriceOf(ROW_SL), digits),
                        DoubleToString(MathAbs(panel.PipsOf(ROW_SL)), 1),
                        AccountInfoString(ACCOUNT_CURRENCY),
                        DoubleToString(panel.MoneyOf(ROW_SL), 2));

   for(int i = ROW_TP1; i <= ROW_TP3; i++)
   {
      if(!panel.IsRowEnabled(i)) continue;
      msg += StringFormat("%s: %s   (%s pips, %s lots, potential profit %s %s, %sR)\n",
                           RowLabel(i),
                           DoubleToString(panel.PriceOf(i), digits),
                           DoubleToString(MathAbs(panel.PipsOf(i)), 1),
                           DoubleToString(panel.LotOf(i), volDigits),
                           AccountInfoString(ACCOUNT_CURRENCY),
                           DoubleToString(panel.MoneyOf(i), 2),
                           DoubleToString(panel.RRof(i), 2));
   }

   msg += "\nExecute this trade?";
   return msg;
}

//--- Sum of today's realized P&L (closed deals, broker-server day) plus
//--- every open position's current floating P&L.
double CTradingPanelDialog::ComputeTodayPnL()
{
   datetime dayStart = TimeCurrent() - (TimeCurrent() % 86400);
   double realized = 0.0;

   if(HistorySelect(dayStart, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         {
            realized += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                      + HistoryDealGetDouble(ticket, DEAL_SWAP)
                      + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         }
      }
   }

   double floating = 0.0;
   int posTotal = PositionsTotal();
   for(int i = 0; i < posTotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   return realized + floating;
}

//--- Closes every open position on the account, not just this EA's own —
//--- Max Daily Loss protects the whole account regardless of what opened
//--- each position. Iterates back-to-front since PositionClose() shrinks
//--- PositionsTotal() as it succeeds; a forward loop would skip positions
//--- shifted into an already-visited index.
void CTradingPanelDialog::CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!trade.PositionClose(ticket))
         Print("Failed to close position #", ticket, " while enforcing max daily loss: ",
               trade.ResultRetcodeDescription());
   }
}

//--- Called every tick (see OnTick), independent of Execute, since the
//--- limit can be breached purely by floating P&L widening. Idempotent
//--- once positions are closed (PositionsTotal() is then 0). Not gated on
//--- m_panelCollapsed — this is a risk action, not a UI update, and must
//--- keep running while the panel is minimized.
void CTradingPanelDialog::EnforceDailyLossLimit()
{
   if(!m_riskParamsLoaded || m_maxDailyLossPercent <= 0.0) return;
   if(PositionsTotal() == 0) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl = ComputeTodayPnL();
   if(equity <= 0.0 || pnl >= 0.0) return;

   double lossPercent = MathAbs(pnl) / equity * 100.0;
   if(lossPercent < m_maxDailyLossPercent) return;

   Print(StringFormat("Max daily loss limit breached (%.2f%% / %.2f%% limit, P&L %s) - closing all open positions.",
                       lossPercent, m_maxDailyLossPercent, DoubleToString(pnl, 2)));
   CloseAllPositions();
}

//--- Consecutive losing closed deals today, most recent first, stopping
//--- at the first non-loss (win or breakeven) or the start of today's
//--- history. Counts individual closed deals rather than grouped
//--- positions, since each TP leg is its own position/ticket (see
//--- MarketExecutionPanel::OnExecute).
int CTradingPanelDialog::ComputeTodayLossStreak()
{
   datetime dayStart = TimeCurrent() - (TimeCurrent() % 86400);
   if(!HistorySelect(dayStart, TimeCurrent())) return 0;

   int total = HistoryDealsTotal();
   int streak = 0;
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

      double dealPnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                      + HistoryDealGetDouble(ticket, DEAL_SWAP)
                      + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(dealPnl < 0.0) streak++;
      else break; // win or breakeven ends the streak
   }
   return streak;
}

//--- Returns "" if clear to trade, or a human-readable reason if a
//--- backend-configured account limit blocks it. Checked once, immediately
//--- before Execute places anything (see OnClickExecute). Fails open: if
//--- risk parameters were never successfully fetched (missing API key,
//--- WebRequest not whitelisted, backend unreachable), trading is not
//--- blocked — this is a safety layer on top of an already-working manual
//--- EA, not a hard dependency. UpdateRiskLimitsLabel() surfaces that
//--- state on the panel.
string CTradingPanelDialog::CheckRiskLimitsBlocking()
{
   if(!m_riskParamsLoaded)
   {
      Print("Risk limit check skipped: risk parameters never successfully loaded - trading is not blocked.");
      return "";
   }

   //--- Fixed-lot mode: the lot size is externally configured and cannot
   //--- be adjusted from here, so a violation can only be reported, not
   //--- corrected. Checked first as the most directly relevant to the
   //--- trade about to be placed.
   if(IsFixedLotMode() && m_maxRiskPerTradePercent > 0.0)
   {
      double impliedRisk = ComputeImpliedRiskPercent(NormalizedFixedLotVolume());
      if(impliedRisk > m_maxRiskPerTradePercent + 0.0000001)
      {
         string reason = StringFormat(
            "Fixed lot size (%s lots) implies %.2f%% risk at the current stop loss, exceeding the %.2f%% max risk per trade.",
            DoubleToString(NormalizedFixedLotVolume(), VolumeDigits(m_comboSymbol.Select())), impliedRisk, m_maxRiskPerTradePercent
         );
         Print("Execute blocked: ", reason);
         return reason;
      }
   }

   //--- 0 means the limit is off, not "block always".
   if(m_maxOpenPositions > 0 && PositionsTotal() >= m_maxOpenPositions)
   {
      string reason = StringFormat("Max open positions reached (%d/%d).", PositionsTotal(), m_maxOpenPositions);
      Print("Execute blocked: ", reason);
      return reason;
   }

   //--- 0 means the limit is off, not "no loss allowed".
   if(m_maxDailyLossPercent > 0.0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double pnl = ComputeTodayPnL();
      if(pnl < 0.0 && equity > 0.0)
      {
         double lossPercent = MathAbs(pnl) / equity * 100.0;
         if(lossPercent >= m_maxDailyLossPercent)
         {
            string reason = StringFormat("Max daily loss reached (%.2f%% / %.2f%% limit).", lossPercent, m_maxDailyLossPercent);
            Print("Execute blocked: ", reason, " (today's P&L: ", DoubleToString(pnl, 2), ")");
            return reason;
         }
      }
   }

   //--- Cooldown: N consecutive losing closed deals today (see
   //--- ComputeTodayLossStreak) blocks every new trade for the rest of the
   //--- day. Resets naturally at the next broker-server midnight since the
   //--- streak is recomputed from today's history rather than persisted.
   if(m_maxConsecutiveLosses > 0)
   {
      int streak = ComputeTodayLossStreak();
      if(streak >= m_maxConsecutiveLosses)
      {
         string reason = StringFormat(
            "Cooldown active: %d consecutive losing trade(s) today (limit %d) - no new trades until tomorrow.",
            streak, m_maxConsecutiveLosses
         );
         Print("Execute blocked: ", reason);
         return reason;
      }
   }

   //--- Every enabled TP's risk:reward must clear the configured minimum.
   //--- Checked last since it's specific to this trade's shape rather than
   //--- an account-wide halt like the checks above.
   if(m_minRiskRewardRatio > 0.0)
   {
      for(int i = ROW_TP1; i <= ROW_TP3; i++)
      {
         if(!ActivePanel().IsRowEnabled(i)) continue;
         double rr = ActivePanel().RRof(i);
         if(rr <= 0.0) continue; // no valid SL distance yet
         if(rr < m_minRiskRewardRatio - 0.0000001)
         {
            string reason = StringFormat(
               "%s risk:reward (%.2fR) is below the target minimum of %.2fR.",
               RowLabel(i), rr, m_minRiskRewardRatio
            );
            Print("Execute blocked: ", reason);
            return reason;
         }
      }
   }

   if(EnableLogging) Print("Risk limit check passed - Execute is not blocked.");
   return "";
}

#endif // TRADINGPANEL_GUARDRAILS_MQH
