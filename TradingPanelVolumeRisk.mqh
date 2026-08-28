//+------------------------------------------------------------------+
//|                                    TradingPanelVolumeRisk.mqh    |
//|  Out-of-line CTradingPanelDialog method bodies (see TradingPanel |
//|  .mq5 for the class declaration and split rationale) for the     |
//|  hands-free position-sizing engine: Volume is always exactly     |
//|  what Max Risk % implies for the active panel's current SL       |
//|  distance (or the mirror image in fixed-lot mode), plus the      |
//|  Risk % manual-override lock (engages on a manual edit, releases |
//|  on a successful Execute or an explicit unlock click).           |
//+------------------------------------------------------------------+
#ifndef TRADINGPANEL_VOLUMERISK_MQH
#define TRADINGPANEL_VOLUMERISK_MQH

//--- Volume is read-only (see EnforceVolumeRiskLimit), so there is no
//--- dedicated Volume-edit branch here.
void CTradingPanelDialog::OnEndEdit(string objName)
{
   ActivePanel().OnEndEdit(objName);
   //--- A manual edit of Risk % itself is the "trader chose a custom
   //--- value" moment m_riskLocked protects — see its own comment.
   if(objName == m_editRisk.Name())
      SetRiskLocked(true);
   ApplyRiskCeiling();       // clamp a typed Max Risk % to the backend's ceiling, if any
   EnforceVolumeRiskLimit(); // a typed SL or Risk % change may have moved the risk-based ceiling
}

//--- 0.1-point steps: the field displays 2 decimals, and typical Risk %
//--- values run 0.5-5%, where a 0.1 nudge is small without requiring many
//--- clicks. Floored at 0. Routes through the same
//--- ApplyRiskCeiling/EnforceVolumeRiskLimit pair as OnEndEdit, so a spin
//--- click cannot produce a state typing wouldn't also reach.
void CTradingPanelDialog::AdjustRiskPercent(double delta)
{
   //--- Defense-in-depth: the spinner buttons are hidden in fixed-lot mode
   //--- (see EnforceVolumeRiskLimit), but MQL5 hit-testing has no
   //--- per-control visibility guard — a stray click landing here must
   //--- still be a no-op rather than overwrite a value that is a
   //--- read-only, backend-driven readout in that mode.
   if(IsFixedLotMode()) return;
   double newRisk = MathMax(StringToDouble(m_editRisk.Text()) + delta, 0.0);
   m_editRisk.Text(DoubleToString(newRisk, 2));
   SetRiskLocked(true); // a spin click is as much a manual override as typing
   ApplyRiskCeiling();
   EnforceVolumeRiskLimit();
}

//--- See m_riskLocked's own comment. Called from AdjustRiskPercent and
//--- OnEndEdit (lock=true, on a manual edit), m_btnRiskLock's click
//--- handler (toggles either way), and OnClickExecute on a successful
//--- trade (lock=false, the custom value has done its job). Idempotent.
void CTradingPanelDialog::SetRiskLocked(bool locked)
{
   m_riskLocked = locked;
   if(EnableLogging) Print("Risk % lock ", (locked ? "engaged" : "released"), " (", DoubleToString(StringToDouble(m_editRisk.Text()), 2), "%)");
   UpdateRiskLockVisual();
   //--- Repaint immediately rather than waiting for the next OnTick's
   //--- EnforceVolumeRiskLimit pass.
   if(!IsFixedLotMode())
      m_editRisk.ColorBackground(m_riskLocked ? C'255,250,205' : clrWhite);
}

//--- Amber while locked, matching this file's convention of using color
//--- rather than text to carry field state; plain grey (matching the
//--- -/+ spinner buttons) while unlocked.
void CTradingPanelDialog::UpdateRiskLockVisual()
{
   m_btnRiskLock.ColorBackground(m_riskLocked ? C'255,193,7' : C'238,238,238');
}

//--- Position size that puts exactly Max Risk % of equity at stake for the
//--- active panel's current SL distance: Volume = risk amount / (SL pips *
//--- pip value per lot), floored to the symbol's volume step (a ceiling
//--- must round down, never up), then floored again at the broker's
//--- minimum lot. Returns 0 if it can't be computed yet (no SL distance).
double CTradingPanelDialog::ComputeMaxVolume()
{
   double slPips = MathAbs(ActivePanel().PipsOf(ROW_SL));
   string sym = m_comboSymbol.Select();
   double maxRisk = AccountInfoDouble(ACCOUNT_EQUITY) * (MathMax(StringToDouble(m_editRisk.Text()), 0.0) / 100.0);
   double pipValue = (sym != "") ? SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE) * 10.0 : 0.0;
   if(sym == "" || slPips <= 0.0 || pipValue <= 0.0 || maxRisk <= 0.0) return 0.0;

   double maxVolume = maxRisk / (slPips * pipValue);

   double volStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(volStep > 0.0) maxVolume = MathFloor(maxVolume / volStep + 0.00000001) * volStep;
   return MathMax(maxVolume, VolumeMin(sym));
}

//--- Rounded to the nearest volume step, not floored: unlike
//--- ComputeMaxVolume's ceiling, this is a fixed value explicitly
//--- configured by the trader/admin, so nearest-step is more faithful to
//--- their intent. Floored at the broker's minimum lot regardless.
double CTradingPanelDialog::NormalizedFixedLotVolume()
{
   string sym = m_comboSymbol.Select();
   double vol = m_fixedLotSize;
   double volStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(volStep > 0.0) vol = MathRound(vol / volStep) * volStep;
   return MathMax(vol, VolumeMin(sym));
}

//--- Mirror of ComputeMaxVolume: given a volume (the fixed lot size), what
//--- % of equity does the active panel's current SL distance put at
//--- stake? Returns 0 if it can't be computed yet.
double CTradingPanelDialog::ComputeImpliedRiskPercent(double volume)
{
   double slPips = MathAbs(ActivePanel().PipsOf(ROW_SL));
   string sym = m_comboSymbol.Select();
   double pipValue = (sym != "") ? SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE) * 10.0 : 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(sym == "" || slPips <= 0.0 || pipValue <= 0.0 || equity <= 0.0 || volume <= 0.0) return 0.0;

   double riskAmount = volume * slPips * pipValue;
   return riskAmount / equity * 100.0;
}

void CTradingPanelDialog::WriteVolumeAndSync(double volume)
{
   m_editVolume.Text(DoubleToString(volume, VolumeDigits(m_comboSymbol.Select())));
   //--- Use RefreshForVolumeChange(), not the generic OnEndEdit fallback:
   //--- that path ends in a full RefreshVisuals() which moves every
   //--- SL/TP/Entry line even though Volume never moves any of them, which
   //--- can fight an in-progress line drag. It also rescales the
   //--- TP1/TP2/TP3 Lot split proportionally to the new total (see
   //--- RescaleLotSplit), preserving whatever split the trader already
   //--- set rather than resetting to equal shares.
   ActivePanel().RefreshForVolumeChange();
}

//--- When Volume can't give every enabled TP at least the broker's minimum
//--- lot once split, force TP2/TP3 off and disable their toggles until
//--- Volume grows enough again. maxTPCount is how many TP slots (TP1..3)
//--- the current Volume can support; applied to all four order-type
//--- panels (only the active one gets the visual update — see
//--- ApplyVolumeConstraint) so switching tabs never reveals a stale,
//--- invalid TP2/TP3 state.
void CTradingPanelDialog::EnforceTPAvailabilityForVolume()
{
   string sym = m_comboSymbol.Select();
   double volMin = VolumeMin(sym);
   if(volMin <= 0.0) return;

   double volume = StringToDouble(m_editVolume.Text());
   int maxTPCount = (int)MathFloor(volume / volMin + 0.00000001);
   maxTPCount = MathMax(MathMin(maxTPCount, 3), 1);

   m_panelMarket.ApplyVolumeConstraint(maxTPCount, m_activeKind == ORDER_MARKET);
   m_panelLimit.ApplyVolumeConstraint(maxTPCount, m_activeKind == ORDER_LIMIT);
   m_panelStop.ApplyVolumeConstraint(maxTPCount, m_activeKind == ORDER_STOP);
   m_panelStopLimit.ApplyVolumeConstraint(maxTPCount, m_activeKind == ORDER_STOPLIMIT);

   ReflowBelowActivePanel(); // TP2/TP3 visibility may have changed for the active panel; cheap even when it didn't
}

//--- Fixed-lot mode inverts the usual relationship: Volume becomes the
//--- fixed, externally-configured value, and Risk % becomes the derived
//--- readout (see ComputeImpliedRiskPercent) of what that lot size
//--- implies against the current SL distance. The field is made read-only
//--- with its spinner hidden (defense-in-depth backed by
//--- AdjustRiskPercent's own guard), and turns red whenever the implied
//--- risk exceeds the account's configured ceiling; CheckRiskLimitsBlocking
//--- is what actually blocks Execute for that — this is just the live
//--- readout.
void CTradingPanelDialog::ApplyFixedLotMode()
{
   double fixedVol = NormalizedFixedLotVolume();
   double currentVolume = StringToDouble(m_editVolume.Text());
   if(MathAbs(currentVolume - fixedVol) > 0.0000001)
      WriteVolumeAndSync(fixedVol);

   double impliedRisk = ComputeImpliedRiskPercent(fixedVol);
   bool overCeiling = (m_maxRiskPerTradePercent > 0.0) && (impliedRisk > m_maxRiskPerTradePercent + 0.0000001);

   m_editRisk.ReadOnly(true);
   m_editRisk.ColorBackground(C'235,235,235');
   m_editRisk.Text(DoubleToString(impliedRisk, 2));
   m_editRisk.Color(overCeiling ? clrRed : clrBlack);
   m_btnRiskDown.Hide();
   m_btnRiskUp.Hide();
   //--- The lock is meaningless here — the field isn't a manually-edited
   //--- value in this mode at all, it's a computed readout — so hide it
   //--- alongside the spinner it's grouped with rather than leave a
   //--- clickable button with no effect.
   m_btnRiskLock.Hide();
}

//--- Volume is always exactly the risk-based ceiling; there is no manual
//--- override or "customized" state (the trader's only manual lever is
//--- the per-TP Lot split, which RefreshForVolumeChange's RescaleLotSplit
//--- call preserves proportionally whenever the total changes). Because
//--- the field is read-only, this is safe to call from every tick (see
//--- OnTick) as well as the explicit SL/Risk %-change hooks
//--- (OnEvent/OnLineMoved/OnEndEdit/SwitchTab): a tick-driven rewrite
//--- cannot collide with in-progress typing when typing into the field
//--- isn't possible. The per-tick call is what propagates "the max lot
//--- size changes with price" — Market's SL pip distance shifts with the
//--- live reference price with no explicit SL edit involved.
void CTradingPanelDialog::EnforceVolumeRiskLimit()
{
   //--- Via EnforceTPAvailabilityForVolume, this ends in an unconditional
   //--- ReflowBelowActivePanel() call that resizes the window back to its
   //--- expanded dimensions, fighting a collapsed panel's shrunk size.
   //--- Nothing needs updating while nothing's visible; it becomes correct
   //--- again the moment SetPanelCollapsed(false) runs its own
   //--- ReflowBelowActivePanel().
   if(m_panelCollapsed) return;

   if(IsFixedLotMode())
   {
      ApplyFixedLotMode();
      EnforceTPAvailabilityForVolume();
      return;
   }

   //--- Not (or not yet) fixed-lot — restore Risk % to its normal editable
   //--- state (a harmless no-op if it already was).
   m_editRisk.ReadOnly(false);
   //--- Amber background is the lock's "engaged" indicator (see
   //--- SetRiskLocked); this per-tick reapply must preserve it rather than
   //--- always forcing white, or the tint would vanish on the tick right
   //--- after SetRiskLocked painted it.
   m_editRisk.ColorBackground(m_riskLocked ? C'255,250,205' : clrWhite);
   m_editRisk.Color(clrBlack);
   m_btnRiskDown.Show();
   m_btnRiskUp.Show();
   m_btnRiskLock.Show();
   UpdateRiskLockVisual();

   double maxVolume = ComputeMaxVolume();
   if(maxVolume <= 0.0) return;

   double currentVolume = StringToDouble(m_editVolume.Text());
   if(MathAbs(currentVolume - maxVolume) > 0.0000001)
      WriteVolumeAndSync(maxVolume);

   EnforceTPAvailabilityForVolume();
}

//--- Caps, but never raises, the trader's Max Risk % field at the
//--- account's configured ceiling. Only touches the field when it is
//--- genuinely over the limit, never unconditionally on every poll, so it
//--- cannot fight the trader mid-edit. This field stays editable, unlike
//--- Volume — the trader can still choose anything up to the ceiling.
void CTradingPanelDialog::ApplyRiskCeiling()
{
   //--- Fixed-lot mode: the field is a read-only readout driven entirely
   //--- by EnforceVolumeRiskLimit/ApplyFixedLotMode, which already colors
   //--- it red on a ceiling violation instead of silently clamping the
   //--- displayed number. Clamping here would mask the violation
   //--- CheckRiskLimitsBlocking needs the trader to see.
   if(IsFixedLotMode()) return;
   if(m_maxRiskPerTradePercent <= 0.0) return; // 0 = no ceiling configured
   double current = StringToDouble(m_editRisk.Text());
   if(current > m_maxRiskPerTradePercent + 0.0000001)
   {
      if(EnableLogging) Print(StringFormat("Max Risk %% capped: %.2f%% exceeded the account ceiling of %.2f%%",
                          current, m_maxRiskPerTradePercent));
      m_editRisk.Text(DoubleToString(m_maxRiskPerTradePercent, 2));
   }
}

#endif // TRADINGPANEL_VOLUMERISK_MQH
