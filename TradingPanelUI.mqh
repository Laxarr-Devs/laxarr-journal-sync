//+------------------------------------------------------------------+
//|                                            TradingPanelUI.mqh    |
//|  Out-of-line CTradingPanelDialog method bodies (see TradingPanel |
//|  .mq5 for the class declaration and split rationale) for         |
//|  everything about building and reflowing the shared chrome: the  |
//|  full CreatePanel() construction, tab switching, symbol/order-   |
//|  type dropdown population, the collapse/expand and reflow logic  |
//|  that resizes the dialog to match whichever rows are visible,    |
//|  and the periodic self-heal/price-readout ticks.                 |
//+------------------------------------------------------------------+
#ifndef TRADINGPANEL_UI_MQH
#define TRADINGPANEL_UI_MQH

bool CTradingPanelDialog::CreateSharedRow(string rowID, CLabel &lbl, CEdit &edit, string labelText, string defaultValue,
                                           int x, int labelW, int editW, int y)
{
   if(!lbl.Create(m_chart_id, m_name + "Lbl_" + rowID, m_subwin, x, y + 4, x + labelW, y + 24)) return false;
   lbl.Text(labelText); lbl.Color(clrBlack); lbl.FontSize(9);
   if(!AddHidden(lbl)) return false;

   int ex1 = x + labelW + HEADER_FIELD_GAP;
   int ex2 = ex1 + editW;
   if(!edit.Create(m_chart_id, m_name + "Edit_" + rowID, m_subwin, ex1, y, ex2, y + 24)) return false;
   edit.Text(defaultValue); edit.Color(clrBlack); edit.ColorBackground(clrWhite); edit.FontSize(9);
   if(!AddHidden(edit)) return false;

   return true;
}

//--- BUY/SELL tab (and Execute button) styling mirrors whichever direction
//--- the ACTIVE panel is currently staged on (each panel remembers its own).
void CTradingPanelDialog::StyleBuySellButtons()
{
   ENUM_ACTIVE_TAB tab = ActivePanel().GetActiveTab();
   bool isBuy = (tab == TAB_BUY);

   m_btnTabBuy.ColorBackground(isBuy ? C'34,139,34' : C'210,210,210');
   m_btnTabBuy.Color(isBuy ? clrWhite : clrBlack);
   m_btnTabSell.ColorBackground(!isBuy ? C'178,34,34' : C'210,210,210');
   m_btnTabSell.Color(!isBuy ? clrWhite : clrBlack);

   m_btnExecute.Text(isBuy ? "Execute BUY" : "Execute SELL");
   m_btnExecute.ColorBackground(isBuy ? C'34,139,34' : C'178,34,34');
   m_btnExecute.Color(clrWhite);
}

void CTradingPanelDialog::SwitchTab(ENUM_ORDER_KIND kind)
{
   if(kind == m_activeKind) return;

   COrderPanelBase *outgoing = ActivePanel();
   outgoing.Hide();
   outgoing.RemoveChartLines();

   m_activeKind = kind;

   COrderPanelBase *incoming = ActivePanel();
   incoming.Show();
   incoming.ApplyActiveTab(); // redraws with its own remembered direction/visibility, no direction change
   m_btnToggleLines.Text(incoming.LinesVisible() ? "Hide Lines" : "Show Lines");
   StyleBuySellButtons();
   EnforceVolumeRiskLimit(); // the incoming panel has its own SL distance — recheck the ceiling immediately
   ReflowBelowActivePanel(); // the incoming panel may have a different TP2/TP3 state than the outgoing one
}

void CTradingPanelDialog::OnClickToggleRiskCards()
{
   m_riskCardsCollapsed = !m_riskCardsCollapsed;
   ReflowBelowActivePanel(); // repositions/shows-or-hides the cards and everything below them
}

//--- Wipes every chart drawing this EA owns (SL/TP/Entry lines, price tags,
//--- profit/loss zones) across all four order-type panels, and reseeds
//--- SL/TP1-3 completely fresh, as if the EA had just been attached.
//--- Reuses the same reseed path ApplySymbolChange() takes when
//--- re-selecting the current symbol: ResetReferenceFields() clears each
//--- pending-order panel's Limit/Stop price field back to its "not yet
//--- seeded" sentinel, then ApplyActiveTab() re-derives everything from
//--- the live/reference price and current Risk % and redraws the lines.
//--- Deliberately narrow in scope: doesn't touch Volume, Comment, Risk %,
//--- or the order-type/symbol pickers — this is a drawings/SL-TP reset,
//--- not a full CreatePanel() rebuild. No confirmation prompt of its own;
//--- callers that need one (the manual Reset button click) ask before
//--- calling this, and the post-Execute call (see OnClickExecute in
//--- TradingPanelGuardrails.mqh) already sat behind its own trade
//--- confirmation a moment earlier.
void CTradingPanelDialog::ResetPanel()
{
   DestroyLines();

   m_panelMarket.ResetReferenceFields();
   m_panelLimit.ResetReferenceFields();
   m_panelStop.ResetReferenceFields();
   m_panelStopLimit.ResetReferenceFields();

   ActivePanel().ApplyActiveTab(); // recomputes SL/TP1-3 fresh and redraws this panel's lines
   EnforceVolumeRiskLimit();       // the freshly-recalculated SL distance may imply a different Volume
}

//--- Manual Reset button click — confirms first (this discards any
//--- manually-typed SL/TP/Limit/Stop prices the trader hasn't executed
//--- yet), then does the actual work via ResetPanel().
void CTradingPanelDialog::OnClickReset()
{
   int confirm = MessageBox("Remove all chart lines/zones for this EA and recalculate SL/TP from scratch?",
                             "Reset Panel", MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2);
   if(confirm != IDYES) return;

   ResetPanel();
}

void CTradingPanelDialog::PopulateOrderTypeCombo()
{
   m_comboOrderType.AddItem("Market",     (long)ORDER_MARKET);
   m_comboOrderType.AddItem("Limit",      (long)ORDER_LIMIT);
   m_comboOrderType.AddItem("Stop",       (long)ORDER_STOP);
   m_comboOrderType.AddItem("Stop Limit", (long)ORDER_STOPLIMIT);
   m_comboOrderType.Select(0);
}

//--- Fills the dropdown from Market Watch and selects the chart's own
//--- symbol, then synchronously seeds every panel for it. SelectByText()
//--- also fires an async CHARTEVENT_CUSTOM+ON_CHANGE that redundantly but
//--- harmlessly redoes the same work a moment later — see OnSymbolChanged.
void CTradingPanelDialog::PopulateSymbolCombo()
{
   int total = SymbolsTotal(true);
   for(int i = 0; i < total; i++)
      m_comboSymbol.AddItem(SymbolName(i, true));

   if(!m_comboSymbol.SelectByText(_Symbol) && total > 0)
      m_comboSymbol.Select(0);

   ApplySymbolChange();
}

//--- Switches everything this panel calculates (SL/TP, pip/$ math, Execute
//--- Trade) to the picked symbol. Reuses this chart (ChartSetSymbolPeriod)
//--- rather than opening a separate one, so the trading panel stays
//--- attached instead of being left behind on the old symbol. Changing a
//--- chart's own symbol makes MT5 reinitialize any attached program
//--- (OnDeinit then OnInit), so once that call is made there is nothing
//--- safe left to do here — OnInit()'s fresh PopulateSymbolCombo() picks up
//--- the new _Symbol and rebuilds every panel for it. Only the
//--- "reselecting the symbol already active" case (the initial bootstrap
//--- call, or the user re-picking it) takes the normal in-place refresh
//--- path.
void CTradingPanelDialog::ApplySymbolChange()
{
   string newSymbol = m_comboSymbol.Select();
   if(newSymbol == "") return;

   if(newSymbol != _Symbol)
   {
      ChartSetSymbolPeriod(m_chart_id, newSymbol, (ENUM_TIMEFRAMES)_Period);
      return;
   }

   Caption("Order: " + newSymbol + " - Laxarr Risk Manager");
   m_panelMarket.ResetReferenceFields();
   m_panelLimit.ResetReferenceFields();
   m_panelStop.ResetReferenceFields();
   m_panelStopLimit.ResetReferenceFields();

   ActivePanel().ApplyActiveTab();

   StyleBuySellButtons();
   //--- Forced (not the usual PollingIntervalSeconds gate) so the Est.
   //--- Trade Cost line doesn't keep showing the OLD symbol's commission
   //--- estimate for up to a full poll interval after switching.
   RefreshCommissionEstimateIfDue(true);
   UpdatePriceReadout();
}

//--- Best-effort initial BUY/SELL guess, based on where the current price
//--- sits within the chart's own currently visible price range (top half
//--- of the visible candles vs. bottom half), not the panel's screen
//--- position. Below the visible range's midpoint suggests price has
//--- pulled back within the current view, so BUY is the more likely
//--- direction to pre-select; above it, SELL. A starting-tab convenience
//--- only — the trader can always click the other tab, and this never
//--- overrides that manual choice (see its call site in CreatePanel(),
//--- which runs once at initial load). CHART_PRICE_MAX/MIN can legitimately
//--- read 0 (or MAX<=MIN) before the chart has rendered a scale for this
//--- symbol/timeframe; falls back to the constructor's TAB_BUY default
//--- rather than guess wrong off a bogus range.
ENUM_ACTIVE_TAB CTradingPanelDialog::GuessDefaultTabFromPriceRange()
{
   double chartHigh = ChartGetDouble(m_chart_id, CHART_PRICE_MAX, m_subwin);
   double chartLow  = ChartGetDouble(m_chart_id, CHART_PRICE_MIN, m_subwin);
   double refPrice  = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(chartHigh <= chartLow || refPrice <= 0.0) return TAB_BUY;

   double mid = (chartHigh + chartLow) / 2.0;
   return (refPrice < mid) ? TAB_BUY : TAB_SELL;
}

//--- Colors the native title bar and widens it to the dialog's full outer
//--- width, so the Minimize/Close buttons sit visibly on the colored bar
//--- rather than in a leftover strip of the library's default near-white.
//--- m_caption is a private CDialog member with no public color or size
//--- setter, but it's still a plain OBJ_EDIT chart object named
//--- m_name+"Caption" underneath (see Dialog.mqh's CreateCaption()),
//--- reachable directly via ObjectSetInteger rather than forking the
//--- standard library. CreateButtonClose()/CreateButtonMinMax() each
//--- shrink the caption's right edge to reserve room for their icons;
//--- widening XSIZE back out here doesn't fight that, since both buttons
//--- were added to the chart after the caption and already render on top
//--- of it. off=2*CONTROLS_BORDER_WIDTH matches CreateCaption()'s own
//--- un-shrunk x1/x2 formula for a normal (non-indicator-panel) dialog.
void CTradingPanelDialog::RestyleTitleBar()
{
   string captionObjName = m_name + "Caption";
   int off = 2; // 2*CONTROLS_BORDER_WIDTH — see this function's own comment
   ObjectSetInteger(m_chart_id, captionObjName, OBJPROP_BGCOLOR, C'214,222,230');
   ObjectSetInteger(m_chart_id, captionObjName, OBJPROP_COLOR, C'40,41,59');
   ObjectSetInteger(m_chart_id, captionObjName, OBJPROP_XSIZE, (int)Width() - 2 * off);
}

//--- See this method's own declaration in TradingPanel.mq5. "Add" (not
//--- AddHidden) inside this body is the plain inherited CAppDialog::Add —
//--- nothing shadows that name, so this resolves normally.
bool CTradingPanelDialog::AddHidden(CWnd &control)
{
   if(!Add(control)) return false;
   control.Hide();
   return true;
}

//--- Repositions everything below the SL/TP block (Comment, price readout,
//--- Execute/Hide-Lines) to sit right under however many rows the active
//--- panel currently shows, and resizes the dialog window to match — this
//--- is what makes hiding/showing TP2/TP3 actually save screen space
//--- instead of leaving a blank gap.
//--- CWndContainer::Add() only marks a newly-added control visible if it is
//--- fully contained within the client area's bounds at that exact moment
//--- (see CWndContainer::Add() in WndContainer.mqh); otherwise it silently
//--- latches the control invisible, permanently, regardless of any later
//--- Move(). These four are first Create()'d/Add()'ed at CreatePanel() time
//--- using a full 4-row placeholder Y, which sits outside the still-
//--- collapsed (2-row) client area's bounds at that instant, so they are
//--- born invisible. Move() alone never re-asserts visibility; only an
//--- explicit Show() does (the same reason TP2/TP3 rows need SetVisible(),
//--- not just Move(), in OrderPanelBase.mqh's ApplyRowVisible()).
void CTradingPanelDialog::ReflowBelowActivePanel()
{
   int panelBottomY = m_slStartY + ActivePanel().VisibleRowCount() * ROW_HEIGHT_TALL;
   int ox = ContainerOffsetX(), oy = ContainerOffsetY();

   //--- "+ 24" must match CreatePanel's identical gap above the Comment row
   //--- (room for the Est. Trade Cost label docked just above the field).
   int y = panelBottomY + 24;
   m_lblComment.Move(RIGHT_COL_X + ox, y + 4 + oy);
   m_editComment.Move(RIGHT_COL_X + 60 + HEADER_FIELD_GAP + ox, y + oy);
   int commentEx2 = RIGHT_COL_X + FORM_CONTENT_WIDTH;
   int costLabelW = 280;
   m_lblTradeCost.Move(commentEx2 - costLabelW + ox, y - 16 + oy);
   //--- Move() sets XDistance to the box's LEFT edge (the x param above);
   //--- re-point it at the right edge to match ANCHOR_RIGHT_UPPER, set
   //--- once at creation time (see CreatePanel's own comment on why).
   ObjectSetInteger(m_chart_id, m_lblTradeCost.Name(), OBJPROP_XDISTANCE, commentEx2 + ox);
   m_lblComment.Show();
   m_editComment.Show();
   m_lblTradeCost.Show();
   y += ROW_HEIGHT + 8;

   m_lblBigPrice.Move(RIGHT_COL_X + ox, y + oy);
   m_lblBigPrice.Show();
   y += 40;

   //--- Risk limits accordion — see m_riskCardsCollapsed's own comment. The
   //--- toggle button always shows; the three cards only occupy space (and
   //--- are only Show()n, the same CWndContainer::Add() latch concern noted
   //--- above) when expanded. m_btnSync shares this row.
   int riskRowHalfWidth = (FORM_CONTENT_WIDTH - 10) / 2;
   m_btnToggleRiskCards.Move(RIGHT_COL_X + ox, y + oy);
   m_btnToggleRiskCards.Text(m_riskCardsCollapsed ? "Show Risk Limits" : "Hide Risk Limits");
   m_btnToggleRiskCards.Show();
   m_btnSync.Move(RIGHT_COL_X + riskRowHalfWidth + 10 + ox, y + oy);
   m_btnSync.Show();
   y += 26;

   int cardGap = 8;
   int cardW = (FORM_CONTENT_WIDTH - 2 * cardGap) / 3;
   for(int c = 0; c < 3; c++)
   {
      int cx = RIGHT_COL_X + c * (cardW + cardGap);
      if(m_riskCardsCollapsed)
      {
         //--- Hide() alone doesn't stop a control from being hit-tested at
         //--- its last-set position — MQL5's click routing has no
         //--- per-control visibility guard (the same reason OrderPanelBase.mqh
         //--- parks TP2/TP3 rows at ROW_HIDDEN_Y instead of just Hide()ing
         //--- them). Without this Move(), these cards would sit on top of
         //--- whatever grew to occupy their old placeholder Y whenever
         //--- TP2/TP3 being visible pushed the row block further down.
         m_riskCardBg[c].Move(cx + ox, ROW_HIDDEN_Y + oy);
         m_riskCardBg[c].Hide();
         m_riskCardTitle[c].Move(cx + 8 + ox, ROW_HIDDEN_Y + oy);
         m_riskCardTitle[c].Hide();
         for(int l = 0; l < 3; l++)
         {
            m_riskCardLine[c][l].Move(cx + 8 + ox, ROW_HIDDEN_Y + oy);
            m_riskCardLine[c][l].Hide();
         }
         continue;
      }
      m_riskCardBg[c].Move(cx + ox, y + oy);
      m_riskCardBg[c].Show();
      m_riskCardTitle[c].Move(cx + 8 + ox, y + 6 + oy);
      m_riskCardTitle[c].Show();
      for(int l = 0; l < 3; l++)
      {
         int ly = y + 24 + l * 15;
         m_riskCardLine[c][l].Move(cx + 8 + ox, ly + oy);
         m_riskCardLine[c][l].Show();
      }
   }
   if(!m_riskCardsCollapsed) y += RISK_CARD_H + 12;

   int halfWidth = (FORM_CONTENT_WIDTH - 10) / 2;
   m_btnExecute.Move(RIGHT_COL_X + ox, y + oy);
   m_btnToggleLines.Move(RIGHT_COL_X + halfWidth + 10 + ox, y + oy);
   m_btnExecute.Show();
   m_btnToggleLines.Show();
   y += 32;

   //--- y so far is content height measured from the client area's own top
   //--- (Create()/Move() coordinates for our controls are all client-area-
   //--- relative). Size() below sets the outer dialog's total height, which
   //--- also has to cover the title bar sitting above the client area, or
   //--- the window is understated by exactly the title bar's height,
   //--- leaving Execute/Hide-Lines poking past the border. The bottom edge
   //--- needs the same DIALOG_CLIENT_INSET correction the right edge does
   //--- (see DIALOG_WIDTH's comment), since the client area's bottom is
   //--- inset from the outer border by that same fixed amount.
   int titleBarHeight = ClientAreaTop() - Top();
   int newHeight = y + RIGHT_COL_X + DIALOG_CLIENT_INSET + titleBarHeight; // same margin as left/right/top
   Size(DIALOG_WIDTH, newHeight);
   m_bgLabel.Size(DIALOG_WIDTH, newHeight);
   //--- Remembered for the next CreatePanel() call (a symbol/timeframe
   //--- reinit) to size the dialog and its loading overlay immediately —
   //--- see m_lastPanelHeight's own comment in TradingPanel.mq5.
   m_lastPanelHeight = newHeight;

   //--- Size() above can trigger the standard library's own internal
   //--- Alignment bookkeeping for every child control, including the title
   //--- bar (m_caption), which RestyleTitleBar() widens past its library
   //--- default — cheap enough to just always reassert here rather than
   //--- verify whether that reset fires on a height-only resize.
   RestyleTitleBar();
}

//--- Collapses the whole panel down to just the title bar (triggered by
//--- the native minimize button — see OnClickButtonMinMax's override in
//--- TradingPanel.mq5), so it stops covering chart price action while not
//--- in use: the Order/Symbol/Volume/Risk row, the active order-type
//--- panel's own SL/TP rows, Comment, price readout, and Execute/Hide-Lines
//--- are all hidden and the window shrunk to match. Expanding restores it
//--- all and re-derives the correct height via ReflowBelowActivePanel(),
//--- the same as a normal tab switch.
//--- Hiding alone isn't enough: MQL5's click hit-testing has no per-control
//--- visibility guard (the same reason COrderPanelBase::Hide() physically
//--- parks its controls off-screen instead of just calling Hide()) — a
//--- hidden-but-still-positioned Comment/Volume/etc field would otherwise
//--- keep stealing clicks aimed at the chart now exposed underneath it once
//--- the window shrinks. Parking with a relative Shift() (the same
//--- OFFSCREEN_SHIFT_Y constant COrderPanelBase uses) and un-shifting by
//--- the same amount on the way back preserves each control's true
//--- position regardless of any Move() that happened while collapsed.
void CTradingPanelDialog::SetPanelCollapsed(bool collapsed)
{
   //--- Idempotent: a redundant call for the current state must be a
   //--- no-op rather than re-apply the relative Shift() below a second
   //--- time, which would strand controls further off-screen than the next
   //--- single un-shift can recover.
   if(collapsed == m_panelCollapsed) return;
   m_panelCollapsed = collapsed;

   CWnd *shared[40];
   int n = 0;
   shared[n++] = GetPointer(m_lblOrderType);
   shared[n++] = GetPointer(m_comboOrderType);
   shared[n++] = GetPointer(m_btnTabBuy);
   shared[n++] = GetPointer(m_btnTabSell);
   shared[n++] = GetPointer(m_lblPipValue);
   shared[n++] = GetPointer(m_btnReset);
   shared[n++] = GetPointer(m_lblSymbol);
   shared[n++] = GetPointer(m_comboSymbol);
   shared[n++] = GetPointer(m_lblVolume);
   shared[n++] = GetPointer(m_editVolume);
   shared[n++] = GetPointer(m_lblRisk);
   shared[n++] = GetPointer(m_editRisk);
   shared[n++] = GetPointer(m_btnRiskDown);
   shared[n++] = GetPointer(m_btnRiskUp);
   shared[n++] = GetPointer(m_btnRiskLock);
   for(int c = 0; c < 3; c++)
   {
      shared[n++] = GetPointer(m_riskCardBg[c]);
      shared[n++] = GetPointer(m_riskCardTitle[c]);
      for(int l = 0; l < 3; l++)
         shared[n++] = GetPointer(m_riskCardLine[c][l]);
   }
   shared[n++] = GetPointer(m_lblComment);
   shared[n++] = GetPointer(m_editComment);
   shared[n++] = GetPointer(m_lblTradeCost);
   shared[n++] = GetPointer(m_lblBigPrice);
   shared[n++] = GetPointer(m_btnExecute);
   shared[n++] = GetPointer(m_btnToggleLines);
   shared[n++] = GetPointer(m_btnToggleRiskCards);
   shared[n++] = GetPointer(m_btnSync);

   if(collapsed)
   {
      for(int i = 0; i < n; i++) { shared[i].Hide(); shared[i].Shift(0, OFFSCREEN_SHIFT_Y); }
      ActivePanel().Hide();
   }
   else
   {
      for(int i = 0; i < n; i++) { shared[i].Shift(0, -OFFSCREEN_SHIFT_Y); shared[i].Show(); }
      ActivePanel().Show();
   }

   if(collapsed)
   {
      //--- Nothing needs to stay visible in the client area — only the
      //--- native title bar (with its own minimize/close buttons) remains,
      //--- so shrink down to just that plus a sliver of margin.
      int titleBarHeight = ClientAreaTop() - Top();
      int collapsedHeight = titleBarHeight + 2 * DIALOG_CLIENT_INSET;
      Size(DIALOG_WIDTH, collapsedHeight);
      m_bgLabel.Size(DIALOG_WIDTH, collapsedHeight);
   }
   else
   {
      //--- The generic Show() loop above unconditionally re-shows
      //--- everything, including the Risk % spinner buttons. If fixed-lot
      //--- mode is active, EnforceVolumeRiskLimit() immediately re-hides
      //--- them (see ApplyFixedLotMode) rather than leaving them visible
      //--- until the next tick corrects it.
      EnforceVolumeRiskLimit();
      ReflowBelowActivePanel(); // re-derives the correct expanded height/positions from scratch
   }
}

bool CTradingPanelDialog::CreatePanel()
{
   //--- Suppress chart-line drawing (SL/TP/Entry lines/zones/labels — see
   //--- COrderPanelBase::m_suppressVisuals's own comment) for the whole
   //--- build, before anything else runs. Set on all four panels, not just
   //--- whichever ends up active, since a mid-build call can reach any of
   //--- them depending on m_activeKind's state at that instant.
   //--- Un-suppressed at this function's tail, where the active panel's
   //--- lines are actually drawn.
   m_panelMarket.SetSuppressVisuals(true);
   m_panelLimit.SetSuppressVisuals(true);
   m_panelStop.SetSuppressVisuals(true);
   m_panelStopLimit.SetSuppressVisuals(true);

   //--- Fixed, symbol-independent name: this becomes m_name, the prefix
   //--- every line/label/zone/control this EA creates is built from (see
   //--- e.g. m_bgLabel's Create() call right below). It must stay
   //--- independent of _Symbol — a symbol switch (ChartSetSymbolPeriod
   //--- reinitializes the whole EA, see ApplySymbolChange's comment) would
   //--- otherwise rebuild this dialog under a different name, orphaning the
   //--- previous symbol's chart lines/zones/labels: nothing would match
   //--- their names again, so RemoveChartLines()/OnDeinit's cleanup would
   //--- never delete them and they would sit on the chart permanently.
   //--- Caption() right after Create() still shows the live symbol in the
   //--- title bar — a separate, purely cosmetic property from the internal
   //--- object-naming prefix.
   if(!CAppDialog::Create(0, "TradingPanelEA", 0, 30, 30, 30 + DIALOG_WIDTH, 30 + DIALOG_HEIGHT))
      return false;
   Caption("Order: " + _Symbol + " - Laxarr Risk Manager");

   //--- Snap straight to the last expanded height this same ExtPanel object
   //--- ended up at (see m_lastPanelHeight's own comment) instead of the
   //--- hardcoded DIALOG_HEIGHT default, so the trader doesn't see the
   //--- window visibly grow/shrink once ReflowBelowActivePanel() computes
   //--- the real final size at this function's tail. On a typical
   //--- symbol-change reinit that final size matches the pre-reinit size,
   //--- so this is usually exactly right, not just a close guess.
   int loadingHeight = (m_lastPanelHeight > 0) ? m_lastPanelHeight : DIALOG_HEIGHT;
   Size(DIALOG_WIDTH, loadingHeight);

   //--- See RestyleTitleBar's own comment. Called here once up front so the
   //--- title bar is already right the first moment the dialog appears, and
   //--- reapplied at CreatePanel()'s tail alongside its own reflow so it
   //--- stays correct on a reinit too.
   RestyleTitleBar();

   //--- A timeframe (or symbol) change reinitializes the whole EA (OnDeinit
   //--- then OnInit — see this method's comment on ChartSetSymbolPeriod),
   //--- but it's the same running ExtPanel object across that cycle, not a
   //--- fresh one: member variables are not reset just because OnDeinit/
   //--- OnInit ran again. CreatePanel() always constructs the full expanded
   //--- layout regardless, so this flag must always start false here rather
   //--- than inherit whatever it was last session, or
   //--- EnforceVolumeRiskLimit() (called later) would bail out on its first
   //--- line and silently skip the initial Volume computation.
   m_panelCollapsed = false;

   //--- Same stale-member-survives-reinit hazard as m_panelCollapsed above,
   //--- but for the order-type tab: everything below this point hardcodes
   //--- Market as the one panel left visible, and PopulateOrderTypeCombo()
   //--- resets the dropdown to index 0 == ORDER_MARKET. If the trader had
   //--- switched to a different order type right before a symbol-change
   //--- reinit, m_activeKind would otherwise still read that other type
   //--- here, and every ActivePanel()-driven call at this function's tail
   //--- would then operate on a panel that has actually been Hidden,
   //--- pulling its rows back on-screen on top of Market's — the
   //--- multi-panel-overlap failure mode ReapplyRowVisibility's own comment
   //--- warns about.
   //---
   //--- The kind itself is worth preserving across the reinit, though — a
   //--- trader staging a Stop Limit order shouldn't see it silently revert
   //--- to Market just because they picked a different symbol. Captured
   //--- here, before the hardcoded reset below, and re-applied at this
   //--- function's tail via the same SwitchTab() transition a manual
   //--- dropdown pick uses, never by just assigning m_activeKind again.
   ENUM_ORDER_KIND restoreKind = m_activeKind;
   m_activeKind = ORDER_MARKET;

   m_riskPollingHalted = false;
   //--- m_editRisk is about to be recreated with its default "1.0" text
   //--- below — a lock held over from a prior build of this same ExtPanel
   //--- object would otherwise protect that placeholder from ever syncing.
   m_riskLocked = false;

   if(!m_bgLabel.Create(m_chart_id, m_name + "BgLabel", m_subwin, 0, 0, DIALOG_WIDTH, DIALOG_HEIGHT)) return false;
   //--- Explicit empty text: an unconfigured OBJ_LABEL defaults its text to
   //--- the literal word "Label", which would otherwise appear at the
   //--- panel's top-left origin (0,0), exactly where this control sits.
   m_bgLabel.Text("");
   m_bgLabel.ColorBackground(clrWhite);
   m_bgLabel.ColorBorder(C'200,200,200');
   if(!AddHidden(m_bgLabel)) return false;
   //--- Selectable so the terminal's native drag machinery picks it up too,
   //--- not just the caption — see OnBackgroundDragged()'s comment in
   //--- TradingPanel.mq5. Every actual control (edit/button/combo) is added
   //--- after this and fully covers its own area, so clicks on them are
   //--- unaffected; this only catches clicks that would otherwise hit blank
   //--- panel body.
   ObjectSetInteger(m_chart_id, m_bgLabel.Name(), OBJPROP_SELECTABLE, true);

   //--- Order type dropdown + BUY / SELL tabs, one row
   int topY = RIGHT_COL_X; // same margin as the left/right edges, for uniform padding
   if(!m_lblOrderType.Create(m_chart_id, m_name + "LblOrderType", m_subwin, RIGHT_COL_X, topY + 5, RIGHT_COL_X + 36, topY + 25)) return false;
   m_lblOrderType.Text("Order:"); m_lblOrderType.Color(clrBlack); m_lblOrderType.FontSize(9);
   if(!AddHidden(m_lblOrderType)) return false;

   int orderComboX = RIGHT_COL_X + 36 + HEADER_FIELD_GAP;
   int orderComboW = 110;
   if(!m_comboOrderType.Create(m_chart_id, m_name + "ComboOrderType", m_subwin, orderComboX, topY, orderComboX + orderComboW, topY + 24)) return false;
   if(!AddHidden(m_comboOrderType)) return false;

   int tabX = orderComboX + orderComboW + 10;
   int tabWidth = 70;
   if(!m_btnTabBuy.Create(m_chart_id, m_name + "BtnTabBuy", m_subwin, tabX, topY, tabX + tabWidth, topY + 24)) return false;
   m_btnTabBuy.Text("BUY"); m_btnTabBuy.FontSize(9);
   if(!AddHidden(m_btnTabBuy)) return false;

   if(!m_btnTabSell.Create(m_chart_id, m_name + "BtnTabSell", m_subwin, tabX + tabWidth + 5, topY, tabX + tabWidth * 2 + 5, topY + 24)) return false;
   m_btnTabSell.Text("SELL"); m_btnTabSell.FontSize(9);
   if(!AddHidden(m_btnTabSell)) return false;

   //--- Reset button pinned to the top-right corner of the header row (see
   //--- OnClickReset), carved out of the pip-value label's right edge below
   //--- on the same row, so it stays visible regardless of which order
   //--- type/TP rows are showing.
   int resetBtnW = tabWidth; // same size as the BUY/SELL tab buttons
   int resetBtnX = RIGHT_COL_X + FORM_CONTENT_WIDTH - resetBtnW;
   if(!m_btnReset.Create(m_chart_id, m_name + "BtnReset", m_subwin, resetBtnX, topY, resetBtnX + resetBtnW, topY + 24)) return false;
   //--- Same inactive-tab gray/black as SELL shows when BUY is active (see
   //--- StyleBuySellButtons) rather than a one-off color scheme.
   m_btnReset.Text("Reset"); m_btnReset.FontSize(9); m_btnReset.Color(clrBlack); m_btnReset.ColorBackground(C'210,210,210');
   if(!AddHidden(m_btnReset)) return false;

   //--- Free space to the right of BUY/SELL on the same row — $ per pip
   //--- for the current symbol at the current total Volume. Right edge
   //--- pulled in by resetBtnW + a gap so it doesn't run under the Reset
   //--- button above.
   int pipValueX = tabX + tabWidth * 2 + 5 + 10;
   if(!m_lblPipValue.Create(m_chart_id, m_name + "LblPipValue", m_subwin, pipValueX, topY + 5, resetBtnX - 8, topY + 25)) return false;
   m_lblPipValue.FontSize(9); m_lblPipValue.Color(C'90,90,90');
   if(!AddHidden(m_lblPipValue)) return false;

   //--- Shared Symbol (dropdown) / Volume / Risk % row
   int formY = 48;
   if(!m_lblSymbol.Create(m_chart_id, m_name + "LblSymbol", m_subwin, RIGHT_COL_X, formY + 4, RIGHT_COL_X + 40, formY + 24)) return false;
   m_lblSymbol.Text("Symbol:"); m_lblSymbol.Color(clrBlack); m_lblSymbol.FontSize(9);
   if(!AddHidden(m_lblSymbol)) return false;

   int symbolComboX = RIGHT_COL_X + 40 + HEADER_FIELD_GAP;
   int symbolComboW = 100;
   if(!m_comboSymbol.Create(m_chart_id, m_name + "ComboSymbol", m_subwin, symbolComboX, formY, symbolComboX + symbolComboW, formY + 24)) return false;
   if(!AddHidden(m_comboSymbol)) return false;

   int volumeX = symbolComboX + symbolComboW + 10;
   //--- Read-only: fully hands-free position sizing. The trader sets Max
   //--- Risk % and Volume is always exactly what that implies (see
   //--- EnforceVolumeRiskLimit). Greyed to match the "locked" convention
   //--- used for TP1/TP2's Lot fields when their sibling TP is hidden.
   if(!CreateSharedRow("Volume", m_lblVolume, m_editVolume, "Volume:", "0.30", volumeX, 54, 55, formY)) return false;
   m_editVolume.ReadOnly(true);
   m_editVolume.ColorBackground(C'235,235,235');

   int riskX = volumeX + 54 + HEADER_FIELD_GAP + 55 + 10;
   if(!CreateSharedRow("Risk", m_lblRisk, m_editRisk, "Risk %:", "1.0", riskX, 44, 46, formY)) return false;

   int riskSpinX = riskX + 44 + HEADER_FIELD_GAP + 46 + FIELD_GAP;
   if(!m_btnRiskDown.Create(m_chart_id, m_name + "BtnRiskDown", m_subwin, riskSpinX, formY, riskSpinX + SPIN_BTN_W, formY + 24)) return false;
   m_btnRiskDown.Text("-"); m_btnRiskDown.FontSize(9); m_btnRiskDown.Color(clrBlack); m_btnRiskDown.ColorBackground(C'238,238,238');
   if(!AddHidden(m_btnRiskDown)) return false;

   int riskSpinX2 = riskSpinX + SPIN_BTN_W + 2;
   if(!m_btnRiskUp.Create(m_chart_id, m_name + "BtnRiskUp", m_subwin, riskSpinX2, formY, riskSpinX2 + SPIN_BTN_W, formY + 24)) return false;
   m_btnRiskUp.Text("+"); m_btnRiskUp.FontSize(9); m_btnRiskUp.Color(clrBlack); m_btnRiskUp.ColorBackground(C'238,238,238');
   if(!AddHidden(m_btnRiskUp)) return false;

   //--- Third button, same size as the -/+ pair (see SetRiskLocked for what
   //--- this toggles). "L" rather than a lock glyph guarantees identical
   //--- rendering across whatever font the terminal skin uses, with no
   //--- emoji/symbol-font fallback risk on a box this narrow. State is
   //--- communicated by color instead, matching this file's convention of
   //--- a background-color change for locked/read-only fields (e.g.
   //--- m_editVolume above).
   int riskSpinX3 = riskSpinX2 + SPIN_BTN_W + 2;
   if(!m_btnRiskLock.Create(m_chart_id, m_name + "BtnRiskLock", m_subwin, riskSpinX3, formY, riskSpinX3 + SPIN_BTN_W, formY + 24)) return false;
   m_btnRiskLock.Text("L"); m_btnRiskLock.FontSize(9);
   if(!AddHidden(m_btnRiskLock)) return false;
   UpdateRiskLockVisual(); // paints its initial (unlocked) color

   formY += ROW_HEIGHT;

   //--- Per-order-type panels: each gets a fixed 1-row slot for its own extra
   //--- price field(s) (side by side for Stop Limit), then its SL/TP1/TP2/TP3
   //--- rows start at the same Y for all, below a shared column-header row.
   int extraFieldsY = formY;
   int slStartY     = extraFieldsY + ROW_HEIGHT + HEADER_H + HEADER_GAP;
   m_slStartY = slStartY;

   if(!m_panelMarket.Init(m_chart_id, m_name, m_subwin, "Market", GetPointer(m_editVolume), GetPointer(m_editRisk), GetPointer(m_comboSymbol), GetPointer(this))) return false;
   if(!m_panelMarket.CreateFields(extraFieldsY, slStartY)) return false;
   m_panelMarket.BindTrade(GetPointer(trade), GetPointer(m_editComment));

   if(!m_panelLimit.Init(m_chart_id, m_name, m_subwin, "Limit", GetPointer(m_editVolume), GetPointer(m_editRisk), GetPointer(m_comboSymbol), GetPointer(this))) return false;
   if(!m_panelLimit.CreateFields(extraFieldsY, slStartY)) return false;

   if(!m_panelStop.Init(m_chart_id, m_name, m_subwin, "Stop", GetPointer(m_editVolume), GetPointer(m_editRisk), GetPointer(m_comboSymbol), GetPointer(this))) return false;
   if(!m_panelStop.CreateFields(extraFieldsY, slStartY)) return false;

   if(!m_panelStopLimit.Init(m_chart_id, m_name, m_subwin, "StopLimit", GetPointer(m_editVolume), GetPointer(m_editRisk), GetPointer(m_comboSymbol), GetPointer(this))) return false;
   if(!m_panelStopLimit.CreateFields(extraFieldsY, slStartY)) return false;

   m_panelLimit.Hide();
   m_panelStop.Hide();
   m_panelStopLimit.Hide();

   //--- See GuessDefaultTabFromPriceRange's own comment. Set quietly, with
   //--- no redraw, on all four panels here, before PopulateSymbolCombo()
   //--- below triggers the real, redrawing ApplyActiveTab() via
   //--- ApplySymbolChange() — that first real activation is what picks up
   //--- this guessed direction.
   ENUM_ACTIVE_TAB guessedTab = GuessDefaultTabFromPriceRange();
   m_panelMarket.SetDefaultTab(guessedTab);
   m_panelLimit.SetDefaultTab(guessedTab);
   m_panelStop.SetDefaultTab(guessedTab);
   m_panelStopLimit.SetDefaultTab(guessedTab);

   //--- Shared Comment row, Price Readout, Action Buttons — created at a
   //--- placeholder Y; ReflowBelowActivePanel() (called below) moves them
   //--- to their real position based on the active panel's TP2/TP3 state.
   //--- The "+ 24" gap gives the small Est. Trade Cost label (below) room
   //--- to sit directly above the Comment field's right edge without
   //--- crowding the SL/TP block above or the field itself; keep this in
   //--- sync with ReflowBelowActivePanel's identical "+ 24".
   int belowY = slStartY + 4 * ROW_HEIGHT_TALL + 24;
   if(!CreateSharedRow("Comment", m_lblComment, m_editComment, "Comment:", "EA Trade", RIGHT_COL_X, 60, FORM_CONTENT_WIDTH - 60 - HEADER_FIELD_GAP, belowY)) return false;

   //--- Small "≈ cost" readout docked above the right portion of the
   //--- Comment field (see UpdatePriceReadout) — right-aligned to the same
   //--- ex2 CreateSharedRow just used for the Comment edit box above.
   int commentEx2 = RIGHT_COL_X + FORM_CONTENT_WIDTH;
   int costLabelW = 280;
   if(!m_lblTradeCost.Create(m_chart_id, m_name + "LblTradeCost", m_subwin, commentEx2 - costLabelW, belowY - 16, commentEx2, belowY - 2)) return false;
   m_lblTradeCost.FontSize(8); m_lblTradeCost.Color(C'90,90,90');
   if(!AddHidden(m_lblTradeCost)) return false;
   //--- Right-anchored (ANCHOR_RIGHT_UPPER) rather than left-aligned like
   //--- every other label here, so it stays flush with the Comment field's
   //--- right edge regardless of how long its text runs (the spread/
   //--- commission figures vary a lot in digit count). CLabel exposes no
   //--- anchor setter (Controls/Label.mqh only wires OnSetText/OnSetColor/
   //--- OnSetFont/OnSetFontSize), hence the direct ObjectSetInteger this
   //--- file uses elsewhere too (e.g. m_bgLabel's OBJPROP_SELECTABLE) for
   //--- object properties the wrapper doesn't expose. XDistance is
   //--- re-pointed at commentEx2 itself, since the box's x1/x2 above only
   //--- mattered for CWndContainer::Add()'s one-time containment check, not
   //--- for where the text actually renders.
   ObjectSetInteger(m_chart_id, m_lblTradeCost.Name(), OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(m_chart_id, m_lblTradeCost.Name(), OBJPROP_XDISTANCE, commentEx2);

   belowY += ROW_HEIGHT + 8;

   if(!m_lblBigPrice.Create(m_chart_id, m_name + "BigPrice", m_subwin, RIGHT_COL_X, belowY, RIGHT_COL_X + FORM_CONTENT_WIDTH, belowY + 30)) return false;
   m_lblBigPrice.FontSize(16);
   m_lblBigPrice.Color(clrBlack);
   if(!AddHidden(m_lblBigPrice)) return false;
   belowY += 40;

   //--- Risk limits accordion, collapsed by default (see
   //--- m_riskCardsCollapsed), toggled by m_btnToggleRiskCards. Created at
   //--- this placeholder Y, same as Comment/BigPrice/Execute above;
   //--- ReflowBelowActivePanel() (called below) does the real positioning
   //--- based on the current collapsed/expanded state. Three framed cards,
   //--- one per section of the web app's own Risk Parameters page (Position
   //--- Sizing / Account Guardrails / Advice Targets); CPanel, not CLabel,
   //--- is what actually renders a background fill/border in MQL5.
   //--- Shares its row with m_btnSync (manual risk/trade-history sync — see
   //--- OnClickSync), the same halfWidth split Execute/ToggleLines use
   //--- below.
   int riskRowHalfWidth = (FORM_CONTENT_WIDTH - 10) / 2;
   if(!m_btnToggleRiskCards.Create(m_chart_id, m_name + "BtnToggleRiskCards", m_subwin, RIGHT_COL_X, belowY, RIGHT_COL_X + riskRowHalfWidth, belowY + 22)) return false;
   m_btnToggleRiskCards.Text("Show Risk Limits");
   m_btnToggleRiskCards.Color(clrBlack);
   m_btnToggleRiskCards.ColorBackground(C'230,230,230');
   m_btnToggleRiskCards.FontSize(8);
   if(!AddHidden(m_btnToggleRiskCards)) return false;

   if(!m_btnSync.Create(m_chart_id, m_name + "BtnSync", m_subwin, RIGHT_COL_X + riskRowHalfWidth + 10, belowY, RIGHT_COL_X + FORM_CONTENT_WIDTH, belowY + 22)) return false;
   m_btnSync.Text("Sync Risk/Trades");
   m_btnSync.Color(clrBlack);
   m_btnSync.ColorBackground(C'230,230,230');
   m_btnSync.FontSize(8);
   if(!AddHidden(m_btnSync)) return false;

   {
      string cardTitles[3] = {"Position Sizing", "Account Guardrails", "Advice Targets"};
      int cardGap = 8;
      int cardW = (FORM_CONTENT_WIDTH - 2 * cardGap) / 3;

      for(int c = 0; c < 3; c++)
      {
         int cx = RIGHT_COL_X + c * (cardW + cardGap);
         string idx = IntegerToString(c);

         if(!m_riskCardBg[c].Create(m_chart_id, m_name + "RiskCardBg" + idx, m_subwin, cx, belowY, cx + cardW, belowY + RISK_CARD_H)) return false;
         m_riskCardBg[c].ColorBackground(C'250,250,250');
         m_riskCardBg[c].ColorBorder(C'222,222,222');
         m_riskCardBg[c].BorderType(BORDER_FLAT);
         if(!AddHidden(m_riskCardBg[c])) return false;

         if(!m_riskCardTitle[c].Create(m_chart_id, m_name + "RiskCardTitle" + idx, m_subwin, cx + 8, belowY + 6, cx + cardW - 8, belowY + 20)) return false;
         m_riskCardTitle[c].Text(cardTitles[c]);
         m_riskCardTitle[c].FontSize(8);
         m_riskCardTitle[c].Color(clrBlack);
         if(!AddHidden(m_riskCardTitle[c])) return false;

         for(int l = 0; l < 3; l++)
         {
            int ly = belowY + 24 + l * 15;
            if(!m_riskCardLine[c][l].Create(m_chart_id, m_name + "RiskCardLine" + idx + "_" + IntegerToString(l), m_subwin, cx + 8, ly, cx + cardW - 8, ly + 14)) return false;
            m_riskCardLine[c][l].FontSize(8);
            m_riskCardLine[c][l].Color(C'90,90,90');
            if(!AddHidden(m_riskCardLine[c][l])) return false;
         }
      }
      m_riskCardLine[0][0].Text("Loading...");
   }

   int halfWidth = (FORM_CONTENT_WIDTH - 10) / 2;

   if(!m_btnExecute.Create(m_chart_id, m_name + "BtnExecute", m_subwin, RIGHT_COL_X, belowY, RIGHT_COL_X + halfWidth, belowY + 32)) return false;
   m_btnExecute.Text("Execute Trade");
   m_btnExecute.Color(clrWhite);
   m_btnExecute.ColorBackground(C'0,102,204');
   m_btnExecute.FontSize(9);
   if(!AddHidden(m_btnExecute)) return false;

   if(!m_btnToggleLines.Create(m_chart_id, m_name + "BtnToggleLines", m_subwin, RIGHT_COL_X + halfWidth + 10, belowY, RIGHT_COL_X + FORM_CONTENT_WIDTH, belowY + 32)) return false;
   m_btnToggleLines.Text("Show Lines"); // panels start with m_linesVisible(false) — see OrderPanelBase constructor
   m_btnToggleLines.Color(clrWhite);
   m_btnToggleLines.ColorBackground(C'128,128,128');
   m_btnToggleLines.FontSize(9);
   if(!AddHidden(m_btnToggleLines)) return false;

   PopulateOrderTypeCombo();
   PopulateSymbolCombo(); // fills the dropdown, selects this chart's symbol, seeds all 4 panels for it
   StyleBuySellButtons();
   //--- One-shot fetch so the risk-limits readout and any Max Risk %
   //--- auto-fill/cap are in place before the first Volume computation just
   //--- below. Never a hard dependency: EnforceVolumeRiskLimit() still runs
   //--- unconditionally right after, so the panel is fully usable even if
   //--- this fetch fails (bad API key, WebRequest not yet whitelisted,
   //--- backend unreachable). Not repeated afterward — see
   //--- RefreshRiskParametersIfDue for why this only runs here and from the
   //--- "Sync" button.
   RefreshRiskParametersIfDue();
   EnforceVolumeRiskLimit(); // sets the initial Volume from the seeded SL distance and Max Risk %
   ReflowBelowActivePanel(); // sets the correct initial (collapsed) height

   //--- Re-assert SL/TP row visibility for the active panel once the whole
   //--- dialog (including the resize just above) has settled — see
   //--- ReapplyRowVisibility's own comment. A symbol switch via the
   //--- dropdown reinitializes the whole EA, so this runs on every switch,
   //--- not just the first load. Deliberately not called on the other
   //--- three (already parked off-screen by Hide() a few lines up):
   //--- ApplyRowVisible's Move() is absolute and knows nothing about that
   //--- relative off-screen shift, so calling it on a hidden panel would
   //--- pull its rows back on-screen and overlap the active panel's.
   ActivePanel().ReapplyRowVisibility();

   //--- Same CWndContainer::Add() latch bug ReapplyRowVisibility() and the
   //--- Comment/BigPrice/Execute block guard against. On a normal
   //--- first-time attach these top-row controls are Add()'d well within
   //--- the client area's bounds, so the latch never trips, but on a
   //--- timeframe/symbol-change reinit the panel can pop back open with
   //--- this entire row missing. Explicit Show() reliably clears it,
   //--- whatever the precise trigger. Also re-run periodically by
   //--- SelfHealLayoutIfDue() — see ReassertHeaderControlsVisible for why a
   //--- chart/terminal-window minimize+restore needs the same fix outside
   //--- of a full CreatePanel() rebuild.
   ReassertHeaderControlsVisible();

   //--- ReassertHeaderControlsVisible() deliberately does not call a real
   //--- .Show() on either combobox — see ReassertComboEdgeVisible:
   //--- CComboBox::Show() forcibly closes an open dropdown, which is wrong
   //--- for that function's other caller (SelfHealLayoutIfDue(), running
   //--- every ~5s with no idea whether the trader has one open). That risk
   //--- doesn't exist here, since this is CreatePanel()'s one-time initial
   //--- build, so a real .Show() is what's needed now that AddHidden()
   //--- starts every control Hidden, comboboxes included.
   m_comboOrderType.Show();
   m_comboSymbol.Show();

   //--- Same gap, different control: nothing else in this file ever calls
   //--- m_bgLabel.Show(). Not obviously visible when missed (a hidden
   //--- CLabel/OBJ_LABEL has no fill of its own, so the panel's appearance
   //--- is unaffected), but it silently breaks dragging the panel by its
   //--- body (OnBackgroundDragged) rather than just the caption, since a
   //--- hidden object isn't a valid drag target.
   m_bgLabel.Show();

   //--- Restores whatever order type was active before this reinit (see
   //--- restoreKind's own comment near the top of this function). The
   //--- dialog above was fully built Market-first regardless, so this is
   //--- now a normal tab switch away from that stable state, via the same
   //--- SwitchTab() path OnOrderTypeChanged() uses, plus syncing the
   //--- dropdown itself. Order values match m_comboOrderType's AddItem
   //--- order 1:1 (see PopulateOrderTypeCombo), so the enum casts straight
   //--- to an index.
   if(restoreKind != ORDER_MARKET)
   {
      m_comboOrderType.Select((int)restoreKind);
      SwitchTab(restoreKind);
      //--- Same belt-and-suspenders re-assert as ReapplyRowVisibility above
      //--- for Market — the restored panel's rows were just as freshly
      //--- Add()'d during this same CreatePanel() call, so they're just as
      //--- exposed to the same construction-time latch bug.
      ActivePanel().ReapplyRowVisibility();
   }

   //--- Un-suppress all four before drawing anything, or
   //--- ActivePanel().RefreshVisuals() just below would still no-op. Only
   //--- the active panel actually needs its lines drawn now; the other
   //--- three stay lineless until SwitchTab() activates one of them.
   m_panelMarket.SetSuppressVisuals(false);
   m_panelLimit.SetSuppressVisuals(false);
   m_panelStop.SetSuppressVisuals(false);
   m_panelStopLimit.SetSuppressVisuals(false);
   ActivePanel().RefreshVisuals(); // draws SL/TP/Entry now, if LinesVisible() — suppressed until this exact point

   return true;
}

//--- Re-asserts Show() on the Order-type/BUY-SELL/pip-value/Reset row and
//--- the Symbol/Volume/Risk% row, without touching any control's position:
//--- the same CWndContainer::Add() visibility-latch guard CreatePanel()
//--- has always needed for a timeframe/symbol reinit, now also called from
//--- SelfHealLayoutIfDue(). That periodic self-heal was only ever
//--- re-asserting the SL/TP rows and everything ReflowBelowActivePanel()
//--- covers (Comment/BigPrice/risk cards/Execute/ToggleLines); this header
//--- block above them was never included, which is why a chart or
//--- terminal window being minimized and restored (MT5 has no event for
//--- this) could leave it stuck missing until the trader manually
//--- collapsed/expanded the panel itself.
void CTradingPanelDialog::ReassertHeaderControlsVisible()
{
   m_lblOrderType.Show();
   //--- Not m_comboOrderType.Show()/m_comboSymbol.Show() — see
   //--- ReassertComboEdgeVisible: a plain Show() call here would silently
   //--- close the trader's dropdown mid-selection every time this ran,
   //--- since SelfHealLayoutIfDue's ~5s tick has no idea whether one is
   //--- currently open.
   ReassertComboEdgeVisible(m_comboOrderType);
   m_btnTabBuy.Show();
   m_btnTabSell.Show();
   m_lblPipValue.Show();
   m_btnReset.Show();
   m_lblSymbol.Show();
   ReassertComboEdgeVisible(m_comboSymbol);
   m_lblVolume.Show();
   m_editVolume.Show();
   m_lblRisk.Show();
   m_editRisk.Show();
   //--- Not m_btnRiskDown/m_btnRiskUp here — their visibility is
   //--- mode-dependent (hidden in fixed-lot mode) and already correctly set
   //--- by EnforceVolumeRiskLimit(); blanket-showing them here would
   //--- wrongly override that in fixed-lot mode.
}

//--- CComboBox::Show() (Controls/ComboBox.mqh) unconditionally runs
//--- `m_list.Hide()` as part of resetting the control to its closed
//--- resting state — exactly right for a deliberate collapse/expand
//--- (SetPanelCollapsed's own shared[] Show() loop), but wrong for
//--- ReassertHeaderControlsVisible, which runs every ~5s from
//--- SelfHealLayoutIfDue() with no idea whether the trader currently has
//--- the dropdown open; a plain .Show() there would silently snap it shut
//--- mid-selection.
//--- CComboBox exposes no public getter for its private m_list and no
//--- Show() variant that skips the list, so this re-asserts visibility
//--- directly on the combo's own always-on-screen sub-objects instead, via
//--- the "Edit"/"Drop" name suffixes CComboBox's own CreateEdit()/
//--- CreateButton() use, leaving the separate list child object untouched
//--- either way.
void CTradingPanelDialog::ReassertComboEdgeVisible(CComboBox &combo)
{
   ObjectSetInteger(m_chart_id, combo.Name() + "Edit", OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   ObjectSetInteger(m_chart_id, combo.Name() + "Drop", OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
}

void CTradingPanelDialog::DestroyLines()
{
   m_panelMarket.RemoveChartLines();
   m_panelLimit.RemoveChartLines();
   m_panelStop.RemoveChartLines();
   m_panelStopLimit.RemoveChartLines();
}

void CTradingPanelDialog::UpdatePriceReadout()
{
   string sym = m_comboSymbol.Select();
   if(sym == "") return;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   //--- Spread in pips, the same "1 pip = 10 points" convention used
   //--- elsewhere in this EA (see e.g. OrderPanelBase.mqh's PriceToPips/
   //--- PipsToPrice), shown between Bid/Ask.
   double spreadPips = (ask - bid) / SymbolInfoDouble(sym, SYMBOL_POINT) / 10.0;
   m_lblBigPrice.Text(DoubleToString(bid, digits) + "   " + DoubleToString(spreadPips, 1) + " pips   " + DoubleToString(ask, digits));

   if(m_lastReadoutBid > 0.0 && bid != m_lastReadoutBid)
      m_lblBigPrice.Color(bid > m_lastReadoutBid ? clrForestGreen : clrCrimson);
   m_lastReadoutBid = bid;

   //--- Per 1.0 lot, NOT scaled by current Volume — a stable instrument
   //--- reference (matches how "pip value" is normally quoted), rather
   //--- than a figure that changes every time Volume does.
   double pipValuePerLot = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE) * 10.0;
   m_lblPipValue.Text("Pip Value (1 lot): " + AccountInfoString(ACCOUNT_CURRENCY) + " " + DoubleToString(pipValuePerLot, 2));

   //--- Est. Trade Cost = live spread cost (exact, from the two live
   //--- figures above) + a commission estimate (necessarily a look-back
   //--- guess — see EstimateCommissionPerLot), both scaled to the current
   //--- Volume. Guarded on m_commissionEstSymbol == sym so a not-yet-
   //--- refreshed cache from a recent symbol switch is never shown as if it
   //--- were current.
   double volume = StringToDouble(m_editVolume.Text());
   double spreadCost = spreadPips * pipValuePerLot * volume;
   string curr = AccountInfoString(ACCOUNT_CURRENCY);
   if(m_hasCommissionEstimate && m_commissionEstSymbol == sym)
   {
      double commCost = MathAbs(m_commissionPerLotEstimate) * volume;
      m_lblTradeCost.Text("≈ Cost: " + curr + " " + DoubleToString(spreadCost + commCost, 2) +
                           " (spread " + DoubleToString(spreadCost, 2) +
                           " + comm ≈" + DoubleToString(commCost, 2) + ")");
   }
   else
   {
      m_lblTradeCost.Text("≈ Cost: " + curr + " " + DoubleToString(spreadCost, 2) + " spread (comm unknown)");
   }
}

//--- Periodic self-heal, called from the global OnTimer. MQL5 has no event
//--- for "the OS/RDP session changed display resolution", so there is
//--- nothing to react to directly, but on a VPS, an RDP reconnect changing
//--- resolution/DPI mid-session has been observed to leave the panel's
//--- middle rows not showing until the trader manually minimizes/restores
//--- it. That symptom matches the CWndContainer::Add() visibility-latch
//--- bug documented on ReapplyRowVisibility() elsewhere in this
//--- file/OrderPanelBase.mqh; minimize/restore "fixes" it purely as a side
//--- effect of forcing a fresh Show() pass. This re-runs that same Show()
//--- pass on a timer instead of waiting for the trader to notice. It does
//--- not fix a genuine native MT5-terminal click-coordinate desync, since
//--- that is the terminal's own DPI handling — only the visibility/
//--- position half.
void CTradingPanelDialog::SelfHealLayoutIfDue()
{
   ulong nowTick = GetTickCount64();
   if(nowTick - m_lastSelfHealTick < 5000) return; // milliseconds; ~every 5s
   m_lastSelfHealTick = nowTick;

   //--- Both calls below fight a deliberately collapsed panel:
   //--- ReflowBelowActivePanel() resizes the window back to its expanded
   //--- height, and ReapplyRowVisibility()'s Move() is absolute — it knows
   //--- nothing about the relative off-screen Shift() Hide() uses for a
   //--- collapsed panel's order-type rows, so it would yank those rows back
   //--- on-screen. Skip entirely while collapsed; SetPanelCollapsed(false)
   //--- already re-derives everything correctly the moment the trader
   //--- expands it again.
   if(m_panelCollapsed) return;

   ReflowBelowActivePanel();
   ActivePanel().ReapplyRowVisibility();
   //--- See ReassertHeaderControlsVisible — without this, a chart/terminal-
   //--- window minimize+restore could leave the Order-type/Symbol/Volume/
   //--- Risk% header row stuck missing, since neither call above touches it.
   ReassertHeaderControlsVisible();
}

void CTradingPanelDialog::OnLineMoved(string objName)
{
   ActivePanel().OnLineMoved(objName);
   EnforceVolumeRiskLimit(); // real-time: dragging SL moves the risk-based ceiling
}

#endif // TRADINGPANEL_UI_MQH
