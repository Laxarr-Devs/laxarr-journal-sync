//+------------------------------------------------------------------+
//|                                              OrderPanelBase.mqh |
//|  Shared SL/TP1/TP2/TP3 rows (price + pips + money + R:R, all     |
//|  editable, spinner-adjustable, and kept in sync with each other) |
//|  plus the chart visualization (entry line, profit/loss zones,    |
//|  price tags) for every order type. TP2/TP3 are fully hidden by   |
//|  default; TP1 hosts a button that shows/hides TP2, TP2 hosts one |
//|  that shows/hides TP3 — so reaching TP3 requires TP2 first.      |
//+------------------------------------------------------------------+
#ifndef ORDER_PANEL_BASE_MQH
#define ORDER_PANEL_BASE_MQH

#include <Controls\Dialog.mqh>
#include <Controls\Label.mqh>
#include <Controls\Edit.mqh>
#include <Controls\Button.mqh>
#include <Controls\ComboBox.mqh>

//--- Shared form layout constants (reused by the main dialog too)
#define ROW_X              12
#define LABEL_W            36
#define PRICE_W            76
#define PIPS_W             48
#define MONEY_W            62
#define RR_W               40   // risk:reward ratio column, TP rows only
#define LOT_W              52   // per-TP lot-share column, TP rows only
#define SPIN_BTN_W         16   // each of the side-by-side -/+ spinner buttons
#define SPIN_PAIR_W        34   // "-" and "+" together, full row height (reliable click target)
#define TOGGLE_W           68   // hosts "Show/Hide TPn" text for the NEXT row — a few px wider than the text itself so it isn't flush against the button edges
#define FIELD_GAP          4
#define ROW_HEIGHT         32   // Symbol/Volume/Risk% rows
#define ROW_HEIGHT_TALL    34   // SL/TP1/TP2/TP3 rows (single line: price+pips+money+R:R)
#define HEADER_H           18
#define HEADER_GAP         6
#define OFFSCREEN_SHIFT_Y  6000   // moves a hidden PANEL's controls well outside any real click coordinate
#define ROW_HIDDEN_Y       -9000 // parks an individually-hidden ROW's controls (TP2/TP3), distinct from the above

enum ENUM_ACTIVE_TAB
{
   TAB_BUY,
   TAB_SELL
};

enum ENUM_PANEL_STATE
{
   STATE_IDLE,
   STATE_STAGED_BUY,
   STATE_STAGED_SELL
};

enum ENUM_ROW_ID
{
   ROW_SL   = 0,
   ROW_TP1  = 1,
   ROW_TP2  = 2,
   ROW_TP3  = 3,
   ROW_COUNT = 4
};


//+------------------------------------------------------------------+
//| Base class for one order-type's fields + chart visualization.    |
//| A plain class (not a CWndContainer): every control it creates is |
//| registered directly with the single top-level dialog, since      |
//| nesting a second container inside the dialog double-applies the  |
//| dialog's own position offset to its children.                    |
//+------------------------------------------------------------------+
class COrderPanelBase
{
protected:
   long               m_chart_id;
   int                m_subwin;
   string             m_name;         // unique per-panel prefix for control/object names
   CAppDialog        *m_dialog;       // owning dialog every control is registered with
   CEdit             *m_volumeEdit;   // shared Volume field owned by the main dialog
   CEdit             *m_riskEdit;     // shared Risk % field owned by the main dialog
   CComboBox         *m_symbolCombo;  // shared Symbol picker owned by the main dialog
   ENUM_PANEL_STATE   m_state;
   ENUM_ACTIVE_TAB    m_activeTab;
   bool               m_linesVisible;
   //--- Set on all four panels for the duration of CreatePanel()'s build
   //--- (see SetSuppressVisuals and CreatePanel()'s use of it in
   //--- TradingPanelUI.mqh), so a mid-build symbol-change flow
   //--- (ApplySymbolChange -> ApplyActiveTab -> OnTabActivated ->
   //--- RefreshVisuals) can't draw SL/TP/Entry chart lines/zones/labels
   //--- before the rest of the panel is ready to reveal. These are raw
   //--- chart objects, not CWnd children added via Add()/AddControl, so
   //--- AddHidden/AddControl's "start Hidden" scheme has no effect on
   //--- them — this is the equivalent guard for that separate drawing path.
   bool               m_suppressVisuals;
   int                m_slStartY;     // fixed on-screen Y of the SL row; TP1/TP2/TP3 are offsets from this
   //--- How many TP rows (counting TP1) the shared Volume can currently give
   //--- at least the broker's minimum lot each, once split — set from
   //--- TradingPanel.mq5 (which owns Volume) via ApplyVolumeConstraint().
   //--- 3 = unconstrained. Blocks turning TP2/TP3 on when it's too small to
   //--- give them a meaningful (non-zero) tradeable share.
   int                m_maxTPCount;

   string  m_rowId[ROW_COUNT];
   bool    m_rowEnabled[ROW_COUNT];   // doubles as "row visible": only ROW_TP2 / ROW_TP3 can be off
   CLabel  m_rowLbl[ROW_COUNT];
   CEdit   m_rowPrice[ROW_COUNT];
   CEdit   m_rowPips[ROW_COUNT];
   CEdit   m_rowMoney[ROW_COUNT];
   CLabel  m_rowRR[ROW_COUNT];        // risk:reward ratio, blank on SL
   CEdit   m_rowLot[ROW_COUNT];       // per-TP lot share, blank/read-only on SL
   //--- Only TP2/TP3 get these (see CreateRow) — TP1 stays typing-only, per
   //--- explicit request; SL has no lot figure of its own at all.
   CButton m_rowLotUp[ROW_COUNT], m_rowLotDown[ROW_COUNT];
   CButton m_rowPriceUp[ROW_COUNT],  m_rowPriceDown[ROW_COUNT];
   CButton m_rowPipsUp[ROW_COUNT],   m_rowPipsDown[ROW_COUNT];
   CButton m_rowMoneyUp[ROW_COUNT],  m_rowMoneyDown[ROW_COUNT];
   CButton m_rowToggle[ROW_COUNT];    // only ROW_TP1 / ROW_TP2 exist: button HOSTED on row i, controls row i+1

   //--- Lot allocated to each TP row (ROW_TP1/TP2/TP3 only), always summing to
   //--- Lots() across whichever TP rows are currently visible. TP1 is the
   //--- independent value; TP2/TP3 split whatever's left. See ResetLotSplitEqual/
   //--- RescaleLotSplit/OnLotEdited for how the three stay in sync.
   double  m_tpLot[ROW_COUNT];

   CLabel  m_hdrPrice, m_hdrPips, m_hdrMoney, m_hdrRR, m_hdrLot;

   //--- Every control this panel ever creates, registered automatically by
   //--- AddControl(). Needed because MQL5's click hit-testing checks a
   //--- control's rect with no per-control visibility guard: Hide() alone
   //--- stops rendering but does not stop a hidden control from catching
   //--- clicks aimed at a differently-owned control at the same pixel
   //--- position (all four order-type panels intentionally share the same
   //--- row coordinates). Show()/Hide() below also physically move controls
   //--- on/off screen to prevent that.
   CWnd *m_allControls[96];
   int   m_controlCount;

   void RegisterControl(CWnd *control)
   {
      if(control != NULL && m_controlCount < 96) m_allControls[m_controlCount++] = control;
   }

   //--- Starts every row control Hidden the instant it's added — see
   //--- CTradingPanelDialog::AddHidden's own comment in TradingPanel.mq5,
   //--- so the panel appears fully built on a reinit rather than popping in
   //--- one control at a time. m_dialog is typed CAppDialog*, not
   //--- CTradingPanelDialog*, so it can't see AddHidden itself; hiding
   //--- directly here achieves the same effect. Every control gets
   //--- correctly re-Shown for the active panel at CreatePanel()'s tail via
   //--- ReapplyRowVisibility/ApplyRowVisible.
   bool AddControl(CWnd &control)
   {
      if(m_dialog == NULL) return false;
      bool ok = m_dialog.Add(control);
      if(ok)
      {
         RegisterControl(GetPointer(control));
         control.Hide();
      }
      return ok;
   }

   //--- Fixed on-screen Y for row i, regardless of whether it's currently
   //--- shown — TP2/TP3 never change slot, only their on/off-screen position.
   int RowY(int i) { return m_slStartY + i * ROW_HEIGHT_TALL; }

   //--- CWndContainer::Add() silently shifts every newly-added control by
   //--- the owning container's own on-screen (Left(),Top()) position,
   //--- translating the dialog-relative coordinates Create() was given into
   //--- true chart-absolute ones. CWnd::Move() has no such translation, so
   //--- a later Move(ROW_X, someY) would drop that offset entirely. Re-derive
   //--- the offset fresh on every call from SL's label, which Add() always
   //--- positions correctly and is never itself row-hidden/mis-Move()'d, so
   //--- this self-corrects even if the dialog window gets dragged between
   //--- calls rather than relying on a stale cache.
   int ContainerOffsetX() { return m_rowLbl[ROW_SL].Left() - ROW_X; }
   int ContainerOffsetY() { return m_rowLbl[ROW_SL].Top()  - (RowY(ROW_SL) + 4); }

   //--- Column x-positions, derived once so CreateRow/CreateColumnHeaders agree
   int PriceX()     { return ROW_X + LABEL_W + FIELD_GAP; }
   int PriceSpinX() { return PriceX() + PRICE_W + FIELD_GAP; }
   int PipsX()      { return PriceSpinX() + SPIN_PAIR_W + FIELD_GAP; }
   int PipsSpinX()  { return PipsX() + PIPS_W + FIELD_GAP; }
   int MoneyX()     { return PipsSpinX() + SPIN_PAIR_W + FIELD_GAP; }
   int MoneySpinX() { return MoneyX() + MONEY_W + FIELD_GAP; }
   int LotX()       { return MoneySpinX() + SPIN_PAIR_W + FIELD_GAP; }
   int LotSpinX()   { return LotX() + LOT_W + FIELD_GAP; }
   int RRX()        { return LotSpinX() + SPIN_PAIR_W + FIELD_GAP; }
   int ToggleX()    { return RRX() + RR_W + FIELD_GAP; }

   //--- A "-"/"+" pair side by side, each full row height (24px) — a much more
   //--- reliable click target than a tiny stacked pair.
   bool CreateSpinner(CButton &dec, CButton &inc, string idSuffix, int x, int y)
   {
      if(!dec.Create(m_chart_id, m_name + "_" + idSuffix + "_Dn", m_subwin, x, y, x + SPIN_BTN_W, y + 24)) return false;
      dec.Text("-"); dec.FontSize(9); dec.Color(clrBlack); dec.ColorBackground(C'238,238,238');
      if(!AddControl(dec)) return false;

      int x2 = x + SPIN_BTN_W + 2;
      if(!inc.Create(m_chart_id, m_name + "_" + idSuffix + "_Up", m_subwin, x2, y, x2 + SPIN_BTN_W, y + 24)) return false;
      inc.Text("+"); inc.FontSize(9); inc.Color(clrBlack); inc.ColorBackground(C'238,238,238');
      if(!AddControl(inc)) return false;

      return true;
   }

   //--- Row builder: label, price+spinner, pips+spinner, money+spinner, R:R
   bool CreateRow(int i, string labelText)
   {
      int y = RowY(i);
      string base = m_name + "_" + m_rowId[i];

      if(!m_rowLbl[i].Create(m_chart_id, base + "_Lbl", m_subwin, ROW_X, y + 4, ROW_X + LABEL_W, y + 24)) return false;
      m_rowLbl[i].Text(labelText); m_rowLbl[i].Color(clrBlack); m_rowLbl[i].FontSize(9);
      if(!AddControl(m_rowLbl[i])) return false;

      if(!m_rowPrice[i].Create(m_chart_id, base + "_Price", m_subwin, PriceX(), y, PriceX() + PRICE_W, y + 24)) return false;
      m_rowPrice[i].Text("0.00000"); m_rowPrice[i].Color(clrBlack); m_rowPrice[i].ColorBackground(clrWhite); m_rowPrice[i].FontSize(9);
      if(!AddControl(m_rowPrice[i])) return false;
      if(!CreateSpinner(m_rowPriceDown[i], m_rowPriceUp[i], m_rowId[i] + "_PriceSpin", PriceSpinX(), y)) return false;

      if(!m_rowPips[i].Create(m_chart_id, base + "_Pips", m_subwin, PipsX(), y, PipsX() + PIPS_W, y + 24)) return false;
      m_rowPips[i].Text("0.0"); m_rowPips[i].Color(clrGray); m_rowPips[i].ColorBackground(clrWhite); m_rowPips[i].FontSize(9);
      if(!AddControl(m_rowPips[i])) return false;
      if(!CreateSpinner(m_rowPipsDown[i], m_rowPipsUp[i], m_rowId[i] + "_PipsSpin", PipsSpinX(), y)) return false;

      if(!m_rowMoney[i].Create(m_chart_id, base + "_Money", m_subwin, MoneyX(), y, MoneyX() + MONEY_W, y + 24)) return false;
      m_rowMoney[i].Text("0.00"); m_rowMoney[i].Color(clrGray); m_rowMoney[i].ColorBackground(clrWhite); m_rowMoney[i].FontSize(9);
      if(!AddControl(m_rowMoney[i])) return false;
      if(!CreateSpinner(m_rowMoneyDown[i], m_rowMoneyUp[i], m_rowId[i] + "_MoneySpin", MoneySpinX(), y)) return false;

      if(!m_rowRR[i].Create(m_chart_id, base + "_RR", m_subwin, RRX(), y + 4, RRX() + RR_W, y + 24)) return false;
      m_rowRR[i].Text(""); m_rowRR[i].FontSize(8); m_rowRR[i].Color(clrDimGray);
      if(!AddControl(m_rowRR[i])) return false;

      //--- SL doesn't fire its own trade — MarketExecutionPanel::OnExecute()
      //--- places a SEPARATE trade per enabled TP, each at that TP's own Lot
      //--- and all sharing this SAME SL price — so SL has no per-trade lot
      //--- figure of its own to show (see ApplyRowVisible, which keeps this
      //--- box permanently hidden for SL regardless of the row's own
      //--- visibility). Still created for array/loop uniformity with the
      //--- other rows, just never shown.
      if(!m_rowLot[i].Create(m_chart_id, base + "_Lot", m_subwin, LotX(), y, LotX() + LOT_W, y + 24)) return false;
      m_rowLot[i].FontSize(9);
      if(i == ROW_SL) { m_rowLot[i].Text(""); m_rowLot[i].ReadOnly(true); }
      else             { m_rowLot[i].Text("0.00"); m_rowLot[i].Color(clrBlack); m_rowLot[i].ColorBackground(clrWhite); }
      if(!AddControl(m_rowLot[i])) return false;

      //--- TP2/TP3 only — see m_rowLotUp's own comment.
      if(i == ROW_TP2 || i == ROW_TP3)
         if(!CreateSpinner(m_rowLotDown[i], m_rowLotUp[i], m_rowId[i] + "_LotSpin", LotSpinX(), y)) return false;

      return true;
   }

   //--- Button hosted on row i (only ROW_TP1/ROW_TP2), shows/hides row i+1.
   bool CreateToggleButton(int i)
   {
      int y = RowY(i);
      if(!m_rowToggle[i].Create(m_chart_id, m_name + "_" + m_rowId[i] + "_NextToggle", m_subwin, ToggleX(), y, ToggleX() + TOGGLE_W, y + 24)) return false;
      m_rowToggle[i].FontSize(9);
      if(!AddControl(m_rowToggle[i])) return false;
      ApplyNextToggleLabel(i);
      return true;
   }

   void ApplyNextToggleLabel(int i)
   {
      int controlled = i + 1;
      bool visible = m_rowEnabled[controlled];
      m_rowToggle[i].Text((visible ? "Hide " : "Show ") + m_rowId[controlled]);
      m_rowToggle[i].ColorBackground(visible ? C'210,235,210' : C'235,235,235');
      m_rowToggle[i].Color(visible ? C'0,120,0' : clrDimGray);
   }

   bool CreateColumnHeaders(int y)
   {
      if(!m_hdrPrice.Create(m_chart_id, m_name + "_HdrPrice", m_subwin, PriceX(), y, PriceX() + PRICE_W, y + HEADER_H)) return false;
      m_hdrPrice.Text("Price"); m_hdrPrice.FontSize(9); m_hdrPrice.Color(C'90,90,90');
      if(!AddControl(m_hdrPrice)) return false;

      if(!m_hdrPips.Create(m_chart_id, m_name + "_HdrPips", m_subwin, PipsX(), y, PipsX() + PIPS_W, y + HEADER_H)) return false;
      m_hdrPips.Text("Pips"); m_hdrPips.FontSize(9); m_hdrPips.Color(C'90,90,90');
      if(!AddControl(m_hdrPips)) return false;

      if(!m_hdrMoney.Create(m_chart_id, m_name + "_HdrMoney", m_subwin, MoneyX(), y, MoneyX() + MONEY_W, y + HEADER_H)) return false;
      //--- MT5's OWN account currency, not something threaded in from a
      //--- backend poll response — SYMBOL_TRADE_TICK_VALUE (what every money
      //--- figure in this row is actually built from, see PipValue()) is
      //--- documented as already converted into ACCOUNT_CURRENCY by the
      //--- terminal itself, so this label is guaranteed to match the number
      //--- next to it, correct from the very first frame with no "wait for
      //--- the first poll" gap. See CTradingPanelDialog::PollRiskParameters
      //--- for the backend's account_currency being used purely as a
      //--- mismatch check against this same value, not as its source.
      m_hdrMoney.Text(AccountInfoString(ACCOUNT_CURRENCY)); m_hdrMoney.FontSize(9); m_hdrMoney.Color(C'90,90,90');
      if(!AddControl(m_hdrMoney)) return false;

      if(!m_hdrRR.Create(m_chart_id, m_name + "_HdrRR", m_subwin, RRX(), y, RRX() + RR_W, y + HEADER_H)) return false;
      m_hdrRR.Text("R:R"); m_hdrRR.FontSize(9); m_hdrRR.Color(C'90,90,90');
      if(!AddControl(m_hdrRR)) return false;

      if(!m_hdrLot.Create(m_chart_id, m_name + "_HdrLot", m_subwin, LotX(), y, LotX() + LOT_W, y + HEADER_H)) return false;
      m_hdrLot.Text("Lot"); m_hdrLot.FontSize(9); m_hdrLot.Color(C'90,90,90');
      if(!AddControl(m_hdrLot)) return false;

      return true;
   }

   //--- A single edit field sized/labelled by the caller (used for the
   //--- order-type-specific extra price field(s): Limit/Stop/StopLimit).
   bool CreateSimpleRow(string rowId, CLabel &lbl, CEdit &edit, string labelText, string defaultValue,
                         int x, int labelW, int editW, int y)
   {
      string base = m_name + "_" + rowId;

      if(!lbl.Create(m_chart_id, base + "_Lbl", m_subwin, x, y + 4, x + labelW, y + 24)) return false;
      lbl.Text(labelText); lbl.Color(clrBlack); lbl.FontSize(9);
      if(!AddControl(lbl)) return false;

      int ex1 = x + labelW + FIELD_GAP;
      int ex2 = ex1 + editW;
      if(!edit.Create(m_chart_id, base + "_Edit", m_subwin, ex1, y, ex2, y + 24)) return false;
      edit.Text(defaultValue); edit.Color(clrBlack); edit.ColorBackground(clrWhite); edit.FontSize(9);
      if(!AddControl(edit)) return false;

      return true;
   }

   //--- The symbol/point/digits this panel is currently trading — driven by the
   //--- shared Symbol dropdown, NOT the chart's own _Symbol (which can't be
   //--- reassigned). Named to avoid any ambiguity with the built-in Symbol()/
   //--- Point() globals rather than shadow them. Declared public further
   //--- down (with PriceOf/PipsOf/etc.) — TradingPanel.mq5's confirmation
   //--- dialog needs to read it directly, and MQL5 doesn't care about
   //--- physical declaration order for a class's own internal calls, so
   //--- moving it there costs nothing here.
   double SymbolPoint()   { return SymbolInfoDouble(CurrentSymbol(), SYMBOL_POINT); }
   int    SymbolDigits()  { return (int)SymbolInfoInteger(CurrentSymbol(), SYMBOL_DIGITS); }

   //--- price <-> pips <-> money conversions, all measured from GetReferencePrice()
   double PipValue() { return SymbolInfoDouble(CurrentSymbol(), SYMBOL_TRADE_TICK_VALUE) * 10.0; }

   //--- User-configurable account risk, as a fraction (e.g. "1.0" typed -> 0.01).
   double RiskPercent()
   {
      double v = (m_riskEdit != NULL) ? MathMax(StringToDouble(m_riskEdit.Text()), 0.0) : 1.0;
      return v / 100.0;
   }

   //--- Nudges a chart price a few pixels up on screen (zoom-independent) so a
   //--- price tag can sit clear of the dashed line it describes instead of
   //--- printing directly on top of it. Falls back to the unmodified price if
   //--- the pixel<->price conversion fails for any reason.
   double PriceAbovePixels(datetime t, double price, int pixels)
   {
      int x, y;
      if(!ChartTimePriceToXY(m_chart_id, 0, t, price, x, y)) return price;
      int subWin; datetime tOut; double priceOut;
      if(!ChartXYToTimePrice(m_chart_id, x, y - pixels, subWin, tOut, priceOut)) return price;
      return priceOut;
   }

   //--- Time at the right (rightmost visible) edge of the chart's current
   //--- viewport, used to anchor price tags there instead of a fixed future
   //--- offset. Falls back to extrapolating past bar 0 when the visible right
   //--- edge is blank future space (common with a chart's right offset).
   datetime RightEdgeTime()
   {
      long firstVisible = ChartGetInteger(m_chart_id, CHART_FIRST_VISIBLE_BAR, 0);
      long widthBars    = ChartGetInteger(m_chart_id, CHART_WIDTH_IN_BARS, 0);
      long rightShift   = firstVisible - widthBars + 1;

      datetime t0 = iTime(CurrentSymbol(), (ENUM_TIMEFRAMES)_Period, 0);
      if(t0 <= 0) t0 = TimeCurrent();

      if(rightShift > 0)
      {
         datetime t = iTime(CurrentSymbol(), (ENUM_TIMEFRAMES)_Period, (int)rightShift);
         if(t > 0) return t;
      }

      long barsIntoFuture = (rightShift <= 0) ? -rightShift : 0;
      return t0 + (datetime)(barsIntoFuture * PeriodSeconds());
   }

   double PriceToPips(double price)
   {
      double refPrice = GetReferencePrice();
      if(refPrice <= 0.0 || price <= 0.0) return 0.0;
      double points = MathAbs(price - refPrice) / SymbolPoint();
      double pips = points / 10.0;
      bool isProfit = (m_activeTab == TAB_BUY) ? (price > refPrice) : (price < refPrice);
      return isProfit ? pips : -pips;
   }

   double PipsToPrice(double pips)
   {
      double refPrice = GetReferencePrice();
      if(refPrice <= 0.0) return 0.0;
      double delta = pips * 10.0 * SymbolPoint();
      return (m_activeTab == TAB_BUY) ? (refPrice + delta) : (refPrice - delta);
   }

   //--- SL closes whatever hasn't already exited via an earlier TP, so its $
   //--- is the worst-case figure against the FULL volume; each TP only ever
   //--- closes its OWN Lot share, so its $ must be based on that share, not
   //--- the total — otherwise TP1/TP2/TP3 all show what the whole position
   //--- would net, which overstates every one of them once split.
   double RowLots(int i) { return (i == ROW_SL) ? Lots() : LotOf(i); }

   double PipsToMoney(int i, double pips) { return pips * PipValue() * RowLots(i); }
   double MoneyToPips(int i, double money)
   {
      double denom = PipValue() * RowLots(i);
      return (denom != 0.0) ? money / denom : 0.0;
   }

   //--- SL is conventionally a loss, TP1/2/3 are conventionally a profit — so
   //--- pips/money fields hold plain (unsigned) magnitudes and this supplies
   //--- the implied direction when converting them back to a price.
   double RowSign(int i) { return (i == ROW_SL) ? -1.0 : 1.0; }

   //--- Color (not a +/- character) carries the sign: green = profit, red = loss.
   void ApplyRowColor(int i, double signedValue)
   {
      color clr = (signedValue >= 0.0) ? clrForestGreen : clrRed;
      m_rowPips[i].Color(clr);
      m_rowMoney[i].Color(clr);
   }

   //--- Risk:reward ratio for TP row i (blank for SL): |TP pips| / |SL pips|.
   //--- See the public RRof() below (declared later in this class, but
   //--- callable from here regardless of section order) for the formula
   //--- itself — kept in one place so the on-screen text and the value
   //--- CheckRiskLimitsBlocking checks can never drift apart.
   void UpdateRR(int i)
   {
      if(i == ROW_SL) { m_rowRR[i].Text(""); return; }
      double rr = RRof(i);
      if(rr <= 0.0) { m_rowRR[i].Text("—"); return; }
      m_rowRR[i].Text(DoubleToString(rr, 2) + "R");
   }

   void UpdateAllRR() { for(int i = ROW_TP1; i <= ROW_TP3; i++) UpdateRR(i); }

   //--- Keeps TP1/TP2/TP3 in strictly increasing distance-from-entry order
   //--- (TP1 < TP2 < TP3 for a BUY, TP1 > TP2 > TP3 for a SELL — never equal,
   //--- never inverted), by clamping whichever row was JUST edited to sit
   //--- one point past its inner neighbor rather than pushing the neighbor
   //--- out of the way. Called at the end of every SyncRowFromPrice/Pips/
   //--- Money for a TP row, so it catches direct edits, spinner nudges, and
   //--- chart-line drags alike — RefreshVisuals() (always called right after
   //--- by every one of those paths) then redraws the line at the clamped
   //--- price too, so a dragged line snaps back into valid order visually.
   void EnforceTPOrdering(int i)
   {
      double price = PriceOf(i);
      if(price <= 0.0) return;

      double point = SymbolPoint();
      bool isBuy = (m_activeTab == TAB_BUY);
      double clamped = price;

      //--- A HIDDEN neighbor's stale price (left over from before it was
      //--- toggled off, or never touched at all) must never constrain a
      //--- VISIBLE row — the trader can't see it, so being blocked by it
      //--- would look like nothing at all is stopping the row from moving.
      //--- Only rows the trader can currently see participate.
      if(i == ROW_TP1)
      {
         double tp2 = PriceOf(ROW_TP2);
         if(m_rowEnabled[ROW_TP2] && tp2 > 0.0)
         {
            if(isBuy  && clamped >= tp2) clamped = tp2 - point;
            if(!isBuy && clamped <= tp2) clamped = tp2 + point;
         }
      }
      else if(i == ROW_TP2)
      {
         double tp1 = PriceOf(ROW_TP1);
         double tp3 = PriceOf(ROW_TP3);
         bool tp3Active = m_rowEnabled[ROW_TP3];
         if(isBuy)
         {
            if(tp1 > 0.0 && clamped <= tp1) clamped = tp1 + point;
            if(tp3Active && tp3 > 0.0 && clamped >= tp3) clamped = tp3 - point;
         }
         else
         {
            if(tp1 > 0.0 && clamped >= tp1) clamped = tp1 - point;
            if(tp3Active && tp3 > 0.0 && clamped <= tp3) clamped = tp3 + point;
         }
      }
      else if(i == ROW_TP3)
      {
         double tp2 = PriceOf(ROW_TP2);
         if(m_rowEnabled[ROW_TP2] && tp2 > 0.0)
         {
            if(isBuy  && clamped <= tp2) clamped = tp2 + point;
            if(!isBuy && clamped >= tp2) clamped = tp2 - point;
         }
      }
      else return;

      if(clamped == price) return;

      m_rowPrice[i].Text(DoubleToString(clamped, SymbolDigits()));
      double pips  = PriceToPips(clamped);
      double money = PipsToMoney(i, pips);
      m_rowPips[i].Text(DoubleToString(MathAbs(pips), 1));
      m_rowMoney[i].Text(DoubleToString(MathAbs(money), 2));
      ApplyRowColor(i, pips);
      UpdateAllRR();
   }

   //--- Re-derives pips & money from whatever is currently in the price field.
   //--- Uses the TRUE direction from price vs. reference (not RowSign), so a
   //--- price entered on the "wrong" side still shows the honest sign via color.
   void SyncRowFromPrice(int i)
   {
      double price = PriceOf(i);
      double pips  = PriceToPips(price);
      double money = PipsToMoney(i, pips);
      m_rowPips[i].Text(DoubleToString(MathAbs(pips), 1));
      m_rowMoney[i].Text(DoubleToString(MathAbs(money), 2));
      ApplyRowColor(i, pips);
      UpdateAllRR();
      EnforceTPOrdering(i);
   }

   //--- Re-derives price & money from whatever is currently in the pips field.
   void SyncRowFromPips(int i)
   {
      double magnitude = MathAbs(PipsOf(i));
      double pips  = magnitude * RowSign(i);
      double price = PipsToPrice(pips);
      double money = PipsToMoney(i, pips);
      if(price > 0.0) m_rowPrice[i].Text(DoubleToString(price, SymbolDigits()));
      m_rowPips[i].Text(DoubleToString(magnitude, 1));
      m_rowMoney[i].Text(DoubleToString(MathAbs(money), 2));
      ApplyRowColor(i, pips);
      UpdateAllRR();
      EnforceTPOrdering(i);
   }

   //--- Re-derives price & pips from whatever is currently in the money field.
   void SyncRowFromMoney(int i)
   {
      double magnitude = MathAbs(MoneyOf(i));
      double pipsMag = MathAbs(MoneyToPips(i, magnitude));
      double pips = pipsMag * RowSign(i);
      double price = PipsToPrice(pips);
      if(price > 0.0) m_rowPrice[i].Text(DoubleToString(price, SymbolDigits()));
      m_rowPips[i].Text(DoubleToString(pipsMag, 1));
      m_rowMoney[i].Text(DoubleToString(magnitude, 2));
      ApplyRowColor(i, pips);
      UpdateAllRR();
      EnforceTPOrdering(i);
   }

   void SyncAllRowsFromPrice() { for(int i = 0; i < ROW_COUNT; i++) SyncRowFromPrice(i); }

   //--- SL distance implied by the current Risk % of equity (floored at 50
   //--- points) — shared by the full-panel seed below and by the SL-only
   //--- recompute that fires whenever Risk % itself is edited.
   double RiskBasedSLDistance()
   {
      double tickValue = SymbolInfoDouble(CurrentSymbol(), SYMBOL_TRADE_TICK_VALUE);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmount = equity * RiskPercent();
      double pipValue = tickValue * 10.0;
      double slPoints = MathMax(riskAmount / (Lots() * pipValue), 50.0);
      return slPoints * SymbolPoint();
   }

   //--- Default SL/TP1/TP2/TP3 prices from a reference price, sized off the
   //--- user's Risk % of equity — the same formula Market Execution uses,
   //--- generalized to any reference price so Limit/Stop/StopLimit can seed
   //--- sensible initial values too.
   void ApplyDefaultRiskPrices(double refPrice)
   {
      if(refPrice <= 0.0) return;

      double slDist = RiskBasedSLDistance();

      if(m_activeTab == TAB_BUY)
      {
         m_rowPrice[ROW_SL].Text(DoubleToString(refPrice - slDist, SymbolDigits()));
         m_rowPrice[ROW_TP1].Text(DoubleToString(refPrice + slDist * 1.5, SymbolDigits()));
         m_rowPrice[ROW_TP2].Text(DoubleToString(refPrice + slDist * 2.0, SymbolDigits()));
         m_rowPrice[ROW_TP3].Text(DoubleToString(refPrice + slDist * 2.5, SymbolDigits()));
      }
      else
      {
         m_rowPrice[ROW_SL].Text(DoubleToString(refPrice + slDist, SymbolDigits()));
         m_rowPrice[ROW_TP1].Text(DoubleToString(refPrice - slDist * 1.5, SymbolDigits()));
         m_rowPrice[ROW_TP2].Text(DoubleToString(refPrice - slDist * 2.0, SymbolDigits()));
         m_rowPrice[ROW_TP3].Text(DoubleToString(refPrice - slDist * 2.5, SymbolDigits()));
      }
   }

   //--- Per-TP lot column: TP1 is the independent value; TP2/TP3 always split
   //--- whatever's left of Lots() between them. TP1 auto-locks to the full
   //--- volume whenever TP2 is hidden (nowhere else for the remainder to go),
   //--- and TP2 auto-locks to the full remainder whenever TP3 is hidden — so
   //--- the visible TPs always sum exactly to Lots().
   double LotStep() { return SymbolInfoDouble(CurrentSymbol(), SYMBOL_VOLUME_STEP); }

   //--- Fixed at 2 decimal places everywhere a lot value is displayed,
   //--- regardless of the broker's own SYMBOL_VOLUME_STEP precision.
   int LotDigits() { return 2; }

   //--- Splits (e.g. 0.5 lots / 3) rarely land on a valid step exactly — always
   //--- round DOWN to the nearest tradable step, per the explicit rule for
   //--- this column (never up, which could push a level's lot past its share).
   double RoundDownToStep(double lots)
   {
      double step = LotStep();
      if(step <= 0.0) return lots;
      return MathFloor(lots / step + 0.00000001) * step;
   }

   void SyncLotFieldsFromValues()
   {
      int digits = LotDigits();
      //--- SL isn't its own trade — each TP fires its OWN trade at LotOf(TPn),
      //--- all sharing this SAME SL price (see MarketExecutionPanel::OnExecute).
      //--- Showing the TP lots' sum here read as "one trade of that size",
      //--- which isn't what happens, so SL's Lot field stays blank.
      m_rowLot[ROW_TP1].Text(DoubleToString(m_tpLot[ROW_TP1], digits));
      m_rowLot[ROW_TP2].Text(m_rowEnabled[ROW_TP2] ? DoubleToString(m_tpLot[ROW_TP2], digits) : "");
      m_rowLot[ROW_TP3].Text(m_rowEnabled[ROW_TP3] ? DoubleToString(m_tpLot[ROW_TP3], digits) : "");
   }

   //--- TP1's field is read-only whenever TP2 is hidden (it must hold 100% of
   //--- Lots(), there's no other visible TP to give the rest to); TP2's field
   //--- is read-only whenever TP3 is hidden, for the same reason one level up.
   void UpdateLotFieldLocks()
   {
      bool tp1Locked = !m_rowEnabled[ROW_TP2];
      bool tp2Locked = !m_rowEnabled[ROW_TP3];

      m_rowLot[ROW_TP1].ReadOnly(tp1Locked);
      m_rowLot[ROW_TP1].ColorBackground(tp1Locked ? C'235,235,235' : clrWhite);

      m_rowLot[ROW_TP2].ReadOnly(tp2Locked);
      m_rowLot[ROW_TP2].ColorBackground(tp2Locked ? C'235,235,235' : clrWhite);

      m_rowLot[ROW_TP3].ColorBackground(clrWhite); // TP3 is always editable whenever visible
   }

   //--- Resets the lot split to an equal share among whichever TP rows are
   //--- currently visible. Called on initial creation and whenever TP2/TP3
   //--- are toggled — the split is intentionally NOT preserved across a
   //--- visibility change, so it's always well-defined for the new row set.
   void ResetLotSplitEqual()
   {
      double total = Lots();
      int tpCount = 1 + (m_rowEnabled[ROW_TP2] ? 1 : 0) + (m_rowEnabled[ROW_TP3] ? 1 : 0);

      if(tpCount <= 1)
      {
         m_tpLot[ROW_TP1] = total;
         m_tpLot[ROW_TP2] = 0.0;
         m_tpLot[ROW_TP3] = 0.0;
      }
      else if(tpCount == 2)
      {
         m_tpLot[ROW_TP1] = RoundDownToStep(total / 2.0);
         m_tpLot[ROW_TP2] = total - m_tpLot[ROW_TP1];
         m_tpLot[ROW_TP3] = 0.0;
      }
      else
      {
         m_tpLot[ROW_TP1] = RoundDownToStep(total / 3.0);
         double remaining = total - m_tpLot[ROW_TP1];
         m_tpLot[ROW_TP2] = RoundDownToStep(remaining / 2.0);
         m_tpLot[ROW_TP3] = remaining - m_tpLot[ROW_TP2];
      }

      SyncLotFieldsFromValues();
   }

   //--- Volume changed but the visible TP row set didn't: rescale every share
   //--- to the new total while preserving the CURRENT ratios (TP1's share of
   //--- the whole, and TP2's share of the TP2+TP3 remainder), instead of
   //--- resetting to an equal split.
   void RescaleLotSplit()
   {
      double total = Lots();
      double oldTotal = m_tpLot[ROW_TP1] + m_tpLot[ROW_TP2] + m_tpLot[ROW_TP3];
      if(oldTotal <= 0.0) { ResetLotSplitEqual(); return; }

      int tpCount = 1 + (m_rowEnabled[ROW_TP2] ? 1 : 0) + (m_rowEnabled[ROW_TP3] ? 1 : 0);
      double tp1Ratio = m_tpLot[ROW_TP1] / oldTotal;
      double tp1New = RoundDownToStep(total * tp1Ratio);

      if(tpCount <= 1)
      {
         m_tpLot[ROW_TP1] = total;
         m_tpLot[ROW_TP2] = 0.0;
         m_tpLot[ROW_TP3] = 0.0;
      }
      else if(tpCount == 2)
      {
         m_tpLot[ROW_TP1] = tp1New;
         m_tpLot[ROW_TP2] = total - tp1New;
         m_tpLot[ROW_TP3] = 0.0;
      }
      else
      {
         double remaining = total - tp1New;
         double oldRemaining = m_tpLot[ROW_TP2] + m_tpLot[ROW_TP3];
         double tp2Ratio = (oldRemaining > 0.0) ? (m_tpLot[ROW_TP2] / oldRemaining) : 0.5;
         m_tpLot[ROW_TP1] = tp1New;
         m_tpLot[ROW_TP2] = RoundDownToStep(remaining * tp2Ratio);
         m_tpLot[ROW_TP3] = remaining - m_tpLot[ROW_TP2];
      }

      SyncLotFieldsFromValues();
   }

   //--- User typed directly into a Lot field. TP1 pushes its new value's
   //--- complement onto TP2+TP3 (preserving their existing ratio); TP2/TP3
   //--- seesaw directly against each other. Locked fields (see
   //--- UpdateLotFieldLocks) are ReadOnly at the control level, but this
   //--- guards the same rule in case an edit event reaches it anyway.
   void OnLotEdited(int i)
   {
      double total = Lots();
      double typed = MathMax(StringToDouble(m_rowLot[i].Text()), 0.0);

      if(i == ROW_TP1)
      {
         if(!m_rowEnabled[ROW_TP2]) { SyncLotFieldsFromValues(); return; }
         typed = RoundDownToStep(MathMin(typed, total));
         m_tpLot[ROW_TP1] = typed;
         double remaining = total - typed;

         if(m_rowEnabled[ROW_TP3])
         {
            double oldRemaining = m_tpLot[ROW_TP2] + m_tpLot[ROW_TP3];
            double tp2Ratio = (oldRemaining > 0.0) ? (m_tpLot[ROW_TP2] / oldRemaining) : 0.5;
            m_tpLot[ROW_TP2] = RoundDownToStep(remaining * tp2Ratio);
            m_tpLot[ROW_TP3] = remaining - m_tpLot[ROW_TP2];
         }
         else
         {
            m_tpLot[ROW_TP2] = remaining;
            m_tpLot[ROW_TP3] = 0.0;
         }
      }
      else if(i == ROW_TP2)
      {
         if(!m_rowEnabled[ROW_TP3]) { SyncLotFieldsFromValues(); return; }
         double remaining = total - m_tpLot[ROW_TP1];
         typed = RoundDownToStep(MathMin(typed, remaining));
         m_tpLot[ROW_TP2] = typed;
         m_tpLot[ROW_TP3] = remaining - typed;
      }
      else if(i == ROW_TP3)
      {
         double remaining = total - m_tpLot[ROW_TP1];
         typed = RoundDownToStep(MathMin(typed, remaining));
         m_tpLot[ROW_TP3] = typed;
         m_tpLot[ROW_TP2] = remaining - typed;
      }

      SyncLotFieldsFromValues();

      //--- $ is now derived from each TP's OWN Lot share (see PipsToMoney),
      //--- so a Lot edit can change $ for TP1/TP2/TP3 even though none of
      //--- their prices moved — re-derive it (harmless no-op for whichever
      //--- weren't actually affected) and refresh the chart tags, which
      //--- show that $ figure too.
      SyncRowFromPrice(ROW_TP1);
      SyncRowFromPrice(ROW_TP2);
      SyncRowFromPrice(ROW_TP3);
      RefreshVisuals();
   }

   void RemoveRowChartObjects(int i)
   {
      string lineName  = m_name + "_Line_"  + m_rowId[i];
      string labelName = m_name + "_Label_" + m_rowId[i];
      if(ObjectFind(m_chart_id, lineName)  >= 0) ObjectDelete(m_chart_id, lineName);
      if(ObjectFind(m_chart_id, labelName) >= 0) ObjectDelete(m_chart_id, labelName);
   }

   //--- Nudges a field by `delta` via its spinner, then re-syncs the row exactly
   //--- as if the user had typed the new value in themselves.
   void AdjustPrice(int i, double delta)
   {
      if(!m_rowEnabled[i]) return;
      double price = MathMax(PriceOf(i) + delta, 0.0);
      m_rowPrice[i].Text(DoubleToString(price, SymbolDigits()));
      SyncRowFromPrice(i);
      RefreshVisuals();
   }

   void AdjustPips(int i, double delta)
   {
      if(!m_rowEnabled[i]) return;
      double mag = MathMax(MathAbs(PipsOf(i)) + delta, 0.0);
      m_rowPips[i].Text(DoubleToString(mag, 1));
      SyncRowFromPips(i);
      RefreshVisuals();
   }

   void AdjustMoney(int i, double delta)
   {
      if(!m_rowEnabled[i]) return;
      double mag = MathMax(MathAbs(MoneyOf(i)) + delta, 0.0);
      m_rowMoney[i].Text(DoubleToString(mag, 2));
      SyncRowFromMoney(i);
      RefreshVisuals();
   }

   //--- TP2/TP3 only (see m_rowLotUp). Writes the field then routes through
   //--- OnLotEdited — the exact same seesaw/lock logic a typed edit gets, so
   //--- a spin click can't produce a state hand-typing wouldn't also reach.
   //--- OnLotEdited's own ReadOnly-mirroring guard (see its comment) already
   //--- makes clicking TP2's spinner while it's the locked remainder a safe
   //--- no-op, same as typing into it would be.
   void AdjustLot(int i, double delta)
   {
      if(!m_rowEnabled[i]) return;
      double newLot = MathMax(m_tpLot[i] + delta, 0.0);
      m_rowLot[i].Text(DoubleToString(newLot, LotDigits()));
      OnLotEdited(i);
   }

   //--- Moves + shows/hides every control of row i to its correct place: its
   //--- fixed on-screen slot if the row is visible, or ROW_HIDDEN_Y (parked,
   //--- inert) if not. SL/TP1 are always visible; TP2/TP3 follow m_rowEnabled.
   //--- Every Move() below adds back the offset ContainerOffsetX/Y() found —
   //--- see those methods' comment for why it's needed.
   void ApplyRowVisible(int i)
   {
      bool visible = m_rowEnabled[i];
      int ox = ContainerOffsetX();
      int y = (visible ? RowY(i) : ROW_HIDDEN_Y) + ContainerOffsetY();

      m_rowLbl[i].Move(ROW_X + ox, y + 4);
      m_rowPrice[i].Move(PriceX() + ox, y);
      m_rowPriceDown[i].Move(PriceSpinX() + ox, y);
      m_rowPriceUp[i].Move(PriceSpinX() + SPIN_BTN_W + 2 + ox, y);
      m_rowPips[i].Move(PipsX() + ox, y);
      m_rowPipsDown[i].Move(PipsSpinX() + ox, y);
      m_rowPipsUp[i].Move(PipsSpinX() + SPIN_BTN_W + 2 + ox, y);
      m_rowMoney[i].Move(MoneyX() + ox, y);
      m_rowMoneyDown[i].Move(MoneySpinX() + ox, y);
      m_rowMoneyUp[i].Move(MoneySpinX() + SPIN_BTN_W + 2 + ox, y);
      m_rowRR[i].Move(RRX() + ox, y + 4);
      m_rowLot[i].Move(LotX() + ox, y);
      if(i == ROW_TP2 || i == ROW_TP3)
      {
         m_rowLotDown[i].Move(LotSpinX() + ox, y);
         m_rowLotUp[i].Move(LotSpinX() + SPIN_BTN_W + 2 + ox, y);
      }

      SetVisible(m_rowLbl[i], visible);
      SetVisible(m_rowPrice[i], visible);
      SetVisible(m_rowPriceDown[i], visible);
      SetVisible(m_rowPriceUp[i], visible);
      SetVisible(m_rowPips[i], visible);
      SetVisible(m_rowPipsDown[i], visible);
      SetVisible(m_rowPipsUp[i], visible);
      SetVisible(m_rowMoney[i], visible);
      SetVisible(m_rowMoneyDown[i], visible);
      SetVisible(m_rowMoneyUp[i], visible);
      SetVisible(m_rowRR[i], visible);
      //--- SL never shows a Lot box at all — see CreateRow's comment on why
      //--- it isn't a real per-trade figure the way TP1/TP2/TP3's are.
      SetVisible(m_rowLot[i], visible && i != ROW_SL);
      if(i == ROW_TP2 || i == ROW_TP3)
      {
         SetVisible(m_rowLotDown[i], visible);
         SetVisible(m_rowLotUp[i], visible);
      }

      if(i == ROW_TP1 || i == ROW_TP2)
      {
         m_rowToggle[i].Move(ToggleX() + ox, y);
         SetVisible(m_rowToggle[i], visible);
      }

      if(visible) SyncRowFromPrice(i);
      if(!visible) RemoveRowChartObjects(i);
   }

   void SetVisible(CWnd &control, bool visible) { if(visible) control.Show(); else control.Hide(); }

   //--- Hosted on row i (ROW_TP1 or ROW_TP2): flips whether row i+1 is
   //--- shown. Hiding TP2 forces TP3 off too, since its toggle button just
   //--- went off-screen with it, leaving no way to turn TP3 back on
   //--- otherwise. Turning a row on is refused if Volume can't give it at
   //--- least the broker's minimum lot once split (see m_maxTPCount /
   //--- ApplyVolumeConstraint); this guard is belt-and-suspenders alongside
   //--- the button's own Disable().
   //--- A row being shown again may hold a stale price left over from
   //--- before it was hidden, which the trader could since have invalidated
   //--- by moving its now-visible inner neighbor past it. Without this,
   //--- EnforceTPOrdering (the last-resort safety net, which still runs
   //--- right after) would crush it to within one point of that neighbor —
   //--- valid but a useless, cramped target. Reseed it instead at the same
   //--- proportional spacing (half the current SL distance per TP step) the
   //--- original risk-based defaults use, so it comes back looking like a
   //--- deliberately placed target.
   void ReseedIfStale(int i)
   {
      bool isBuy = (m_activeTab == TAB_BUY);
      double slPips = MathAbs(PipsOf(ROW_SL));
      if(slPips <= 0.0) return; // nothing sensible to base a step on — EnforceTPOrdering's clamp is the fallback
      double step = MathMax(slPips, 10.0) * 0.5 * 10.0 * SymbolPoint();

      if(i == ROW_TP2)
      {
         double tp1 = PriceOf(ROW_TP1);
         double tp2 = PriceOf(ROW_TP2);
         if(tp1 <= 0.0) return;
         bool invalid = (tp2 <= 0.0) || (isBuy ? (tp2 <= tp1) : (tp2 >= tp1));
         if(invalid) m_rowPrice[ROW_TP2].Text(DoubleToString(isBuy ? (tp1 + step) : (tp1 - step), SymbolDigits()));
      }
      else if(i == ROW_TP3)
      {
         double tp2 = PriceOf(ROW_TP2);
         double tp3 = PriceOf(ROW_TP3);
         if(tp2 <= 0.0) return;
         bool invalid = (tp3 <= 0.0) || (isBuy ? (tp3 <= tp2) : (tp3 >= tp2));
         if(invalid) m_rowPrice[ROW_TP3].Text(DoubleToString(isBuy ? (tp2 + step) : (tp2 - step), SymbolDigits()));
      }
   }

   void ToggleNextRow(int i)
   {
      int target = i + 1;
      if(!m_rowEnabled[target] && target > m_maxTPCount) return;
      bool turningOn = !m_rowEnabled[target];
      m_rowEnabled[target] = !m_rowEnabled[target];

      if(target == ROW_TP2 && !m_rowEnabled[ROW_TP2] && m_rowEnabled[ROW_TP3])
      {
         m_rowEnabled[ROW_TP3] = false;
         ApplyRowVisible(ROW_TP3);
         ApplyNextToggleLabel(ROW_TP2); // refresh the TP2-hosted "Hide/Show TP3" text too
      }

      if(turningOn) ReseedIfStale(target);

      //--- Before ApplyRowVisible: its SyncRowFromPrice(target) call computes
      //--- $ from THIS row's Lot share (see PipsToMoney), so the split for
      //--- the new visible-TP-count has to be in place first, or target
      //--- would briefly show $ computed from its old (possibly zero) share.
      ResetLotSplitEqual(); // visible TP set changed — the old split no longer applies
      UpdateLotFieldLocks();

      ApplyRowVisible(target);
      ApplyNextToggleLabel(i);
      RefreshVisuals();
   }

   //--- Native chart objects: horizontal line, filled zone, price tag
   bool CreateOrUpdateLine(string lineName, double price, color lineClr, string description,
                            ENUM_LINE_STYLE style = STYLE_DASH, bool draggable = true)
   {
      price = NormalizeDouble(price, SymbolDigits());
      if(price <= 0.0) return false;

      if(ObjectFind(m_chart_id, lineName) < 0)
         ObjectCreate(m_chart_id, lineName, OBJ_HLINE, 0, 0, price);
      else
         ObjectMove(m_chart_id, lineName, 0, 0, price);

      ObjectSetInteger(m_chart_id, lineName, OBJPROP_COLOR, lineClr);
      ObjectSetInteger(m_chart_id, lineName, OBJPROP_STYLE, style);
      ObjectSetInteger(m_chart_id, lineName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(m_chart_id, lineName, OBJPROP_BACK, true);
      ObjectSetInteger(m_chart_id, lineName, OBJPROP_SELECTABLE, draggable);
      ObjectSetInteger(m_chart_id, lineName, OBJPROP_SELECTED, draggable);
      ObjectSetInteger(m_chart_id, lineName, OBJPROP_HIDDEN, false);
      ObjectSetString(m_chart_id, lineName, OBJPROP_TEXT, description);

      return true;
   }

   bool CreateOrUpdateZone(string zoneName, datetime t1, datetime t2, double priceEntry, double priceTarget, color fillClr)
   {
      priceEntry  = NormalizeDouble(priceEntry, SymbolDigits());
      priceTarget = NormalizeDouble(priceTarget, SymbolDigits());
      if(priceEntry <= 0.0 || priceTarget <= 0.0) return false;

      if(ObjectFind(m_chart_id, zoneName) < 0)
         ObjectCreate(m_chart_id, zoneName, OBJ_RECTANGLE, 0, t1, priceEntry, t2, priceTarget);
      else
      {
         ObjectSetInteger(m_chart_id, zoneName, OBJPROP_TIME, 0, t1);
         ObjectSetDouble(m_chart_id, zoneName, OBJPROP_PRICE, 0, priceEntry);
         ObjectSetInteger(m_chart_id, zoneName, OBJPROP_TIME, 1, t2);
         ObjectSetDouble(m_chart_id, zoneName, OBJPROP_PRICE, 1, priceTarget);
      }

      ObjectSetInteger(m_chart_id, zoneName, OBJPROP_COLOR, fillClr);
      ObjectSetInteger(m_chart_id, zoneName, OBJPROP_FILL, true);
      ObjectSetInteger(m_chart_id, zoneName, OBJPROP_BACK, true);
      ObjectSetInteger(m_chart_id, zoneName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart_id, zoneName, OBJPROP_SELECTED, false);
      ObjectSetInteger(m_chart_id, zoneName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(m_chart_id, zoneName, OBJPROP_WIDTH, 1);

      return true;
   }

   bool CreateOrUpdatePriceLabel(string labelName, datetime t, double price, string text, color clr)
   {
      price = NormalizeDouble(price, SymbolDigits());
      if(price <= 0.0) return false;

      if(ObjectFind(m_chart_id, labelName) < 0)
         ObjectCreate(m_chart_id, labelName, OBJ_TEXT, 0, t, price);
      else
      {
         ObjectSetInteger(m_chart_id, labelName, OBJPROP_TIME, 0, t);
         ObjectSetDouble(m_chart_id, labelName, OBJPROP_PRICE, 0, price);
      }

      ObjectSetString(m_chart_id, labelName, OBJPROP_TEXT, text);
      ObjectSetInteger(m_chart_id, labelName, OBJPROP_COLOR, clr);
      ObjectSetInteger(m_chart_id, labelName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(m_chart_id, labelName, OBJPROP_ANCHOR, ANCHOR_RIGHT);
      //--- BACK=true, matching its sibling line/zone above: chart objects
      //--- stack by creation order within a layer, and this label gets
      //--- recreated/updated continuously, long after the panel's own
      //--- controls were created once at startup. Left BACK=false, it would
      //--- always render in front of the panel regardless of where the
      //--- panel sits. BACK=true puts it in the same background layer as
      //--- CreateOrUpdateLine/CreateOrUpdateZone, so it always draws behind
      //--- the panel no matter the creation order.
      ObjectSetInteger(m_chart_id, labelName, OBJPROP_BACK, true);
      ObjectSetInteger(m_chart_id, labelName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart_id, labelName, OBJPROP_HIDDEN, true);

      return true;
   }

   //--- Hook for subclasses to insert their own price field(s) above the SL row.
   virtual void CreateExtraFields(int y) { /* Market Execution needs none */ }

   //--- Hook for subclasses to react to a BUY/SELL tab switch (e.g. auto-fill SL/TP).
   virtual void OnTabActivated() { SyncAllRowsFromPrice(); RefreshVisuals(); }

public:
   //--- Hook for subclasses to clear their own reference price field(s) back to
   //--- zero on a symbol change, so the existing "seed once, only when zero"
   //--- logic naturally re-seeds from the new symbol next time this panel
   //--- activates. No-op on Market, which has no such field of its own.
   virtual void ResetReferenceFields() {}

   COrderPanelBase() : m_dialog(NULL), m_volumeEdit(NULL), m_riskEdit(NULL), m_symbolCombo(NULL),
                        m_state(STATE_IDLE), m_activeTab(TAB_BUY), m_linesVisible(false), m_suppressVisuals(false), m_controlCount(0),
                        m_maxTPCount(3)
   {
      m_rowId[ROW_SL] = "SL"; m_rowId[ROW_TP1] = "TP1"; m_rowId[ROW_TP2] = "TP2"; m_rowId[ROW_TP3] = "TP3";
      for(int i = 0; i < ROW_COUNT; i++) { m_rowEnabled[i] = true; m_tpLot[i] = 0.0; }
      m_rowEnabled[ROW_TP2] = false; // TP2/TP3 start hidden; user opts in via the toggle
      m_rowEnabled[ROW_TP3] = false;
   }

   bool Init(long chart_id, string dialogName, int subwin, string namePrefix,
             CEdit *volumeEdit, CEdit *riskEdit, CComboBox *symbolCombo, CAppDialog *ownerDialog)
   {
      m_chart_id    = chart_id;
      m_subwin      = subwin;
      m_name        = dialogName + "_" + namePrefix;
      m_dialog      = ownerDialog;
      m_volumeEdit  = volumeEdit;
      m_riskEdit    = riskEdit;
      m_symbolCombo = symbolCombo;
      return true;
   }

   //--- Moves every control back on-screen before showing it. The move must
   //--- happen first so nothing renders at the parked off-screen position.
   //--- Row-hidden TP2/TP3 controls are left exactly where ApplyRowVisible()
   //--- parked them: a relative Shift() by the same amount in both
   //--- directions preserves whatever position a control had.
   void Show()
   {
      for(int i = 0; i < m_controlCount; i++)
      {
         m_allControls[i].Shift(0, -OFFSCREEN_SHIFT_Y);
         m_allControls[i].Show();
      }
      // Re-apply so a row/control that's supposed to be hidden ends up
      // hidden again — Show() above unconditionally shows everything; this
      // corrects TP2/TP3 (row-level hide) and re-hides SL's Lot box (always
      // hidden regardless of the row's own visibility — see ApplyRowVisible).
      ApplyRowVisible(ROW_SL);
      ApplyRowVisible(ROW_TP2);
      ApplyRowVisible(ROW_TP3);
   }

   //--- Hides every control AND parks it far off-screen, so it can never win
   //--- a click hit-test against the differently-owned control that visually
   //--- occupies the same coordinates (see OFFSCREEN_SHIFT_Y comment above).
   void Hide()
   {
      for(int i = 0; i < m_controlCount; i++)
      {
         m_allControls[i].Hide();
         m_allControls[i].Shift(0, OFFSCREEN_SHIFT_Y);
      }
   }

   bool CreateFields(int extraFieldsY, int slStartY)
   {
      m_slStartY = slStartY;
      CreateExtraFields(extraFieldsY);
      if(!CreateColumnHeaders(slStartY - HEADER_H - HEADER_GAP)) return false;

      string labels[ROW_COUNT] = {"SL:", "TP1:", "TP2:", "TP3:"};

      for(int i = 0; i < ROW_COUNT; i++)
      {
         if(!CreateRow(i, labels[i])) return false;
         if(i == ROW_TP1 || i == ROW_TP2)
            if(!CreateToggleButton(i)) return false;
      }

      //--- Must run BEFORE ApplyRowVisible: each row's $ is now derived from
      //--- its OWN Lot share (see PipsToMoney/MoneyToPips), so m_tpLot[] has
      //--- to be populated before ApplyRowVisible's SyncRowFromPrice() calls
      //--- compute the very first $ values, or TP1/TP2/TP3 would briefly
      //--- show $0.00 until something else happened to re-sync them.
      ResetLotSplitEqual();
      UpdateLotFieldLocks();

      for(int i = 0; i < ROW_COUNT; i++) ApplyRowVisible(i);

      return true;
   }

   //--- Virtual seams subclasses fill in
   virtual double GetReferencePrice() { return 0.0; }
   virtual void   OnExecute() { /* order type not yet wired to real execution */ }

   //--- True only for Market (its reference price IS the live bid/ask).
   //--- Limit/Stop/StopLimit's reference price is a fixed target the user
   //--- set — it must NOT drift with live price, that's the whole point of a
   //--- pending order — so they leave this false.
   virtual bool UsesLiveReferencePrice() { return false; }

   //--- Moved here from the protected block above (see its own comment) —
   //--- TradingPanel.mq5's trade-confirmation dialog reads these directly.
   string CurrentSymbol() { return (m_symbolCombo != NULL) ? m_symbolCombo.Select() : ::Symbol(); }
   double Lots()
   {
      double v = (m_volumeEdit != NULL) ? StringToDouble(m_volumeEdit.Text()) : 0.0;
      return (v > 0) ? v : 0.30;
   }

   double PriceOf(int i) { return StringToDouble(m_rowPrice[i].Text()); }
   double PipsOf(int i)  { return StringToDouble(m_rowPips[i].Text()); }
   double MoneyOf(int i) { return StringToDouble(m_rowMoney[i].Text()); }
   double LotOf(int i)   { return m_tpLot[i]; } // TP1/TP2/TP3 only — always sums to Lots() across visible TP rows
   bool   IsRowEnabled(int i) { return m_rowEnabled[i]; }

   //--- Risk:reward ratio for TP row i: |TP pips| / |SL pips|. 0 if there's
   //--- no valid SL distance to divide by. Exposed publicly so the dialog
   //--- can check it against the account's own min-R:R guardrail
   //--- (see TradingPanel.mq5's CheckRiskLimitsBlocking) without duplicating
   //--- the formula UpdateRR() uses to build the on-screen "X.XXR" text.
   double RRof(int i)
   {
      double slPips = MathAbs(PipsOf(ROW_SL));
      if(slPips <= 0.0) return 0.0;
      return MathAbs(PipsOf(i)) / slPips;
   }

   //--- Called from TradingPanel.mq5 (owns the shared Volume field) whenever
   //--- Volume, SL distance, or Max Risk % changes. Forces TP2/TP3 off (and
   //--- disables their toggle buttons) once Volume is too small to give
   //--- every enabled TP at least the broker's minimum lot after splitting.
   //--- isActivePanel gates every visual side effect (ApplyRowVisible/
   //--- RefreshVisuals/button Disable): an inactive panel's controls are
   //--- parked off-screen by Hide() using a relative Shift(), and
   //--- ApplyRowVisible's absolute Move() would silently undo that parking
   //--- if run on it, so only m_rowEnabled/m_maxTPCount (plain data) are
   //--- safe to update regardless. The panel picks up the correct visible
   //--- state on its own next Show().
   void ApplyVolumeConstraint(int maxTPCount, bool isActivePanel)
   {
      m_maxTPCount = maxTPCount;

      bool tp3ForcedOff = (maxTPCount < 3 && m_rowEnabled[ROW_TP3]);
      bool tp2ForcedOff = (maxTPCount < 2 && m_rowEnabled[ROW_TP2]);
      if(tp3ForcedOff) m_rowEnabled[ROW_TP3] = false;
      if(tp2ForcedOff) m_rowEnabled[ROW_TP2] = false;

      if(!isActivePanel) return;

      if(tp3ForcedOff) ApplyRowVisible(ROW_TP3);
      if(tp2ForcedOff) ApplyRowVisible(ROW_TP2);
      if(tp3ForcedOff || tp2ForcedOff) { ResetLotSplitEqual(); RefreshVisuals(); }

      UpdateLotFieldLocks();
      ApplyNextToggleLabel(ROW_TP1);
      ApplyNextToggleLabel(ROW_TP2);

      if(maxTPCount < 2) m_rowToggle[ROW_TP1].Disable(); else m_rowToggle[ROW_TP1].Enable();
      if(maxTPCount < 3) m_rowToggle[ROW_TP2].Disable(); else m_rowToggle[ROW_TP2].Enable();
   }

   //--- SL + TP1 are always the fixed 2, plus however many of TP2/TP3 are
   //--- currently shown — what the dialog needs to know where to place
   //--- everything below the SL/TP block (and how tall to make the window).
   int VisibleRowCount()
   {
      int count = 2;
      if(m_rowEnabled[ROW_TP2]) count++;
      if(m_rowEnabled[ROW_TP3]) count++;
      return count;
   }

   //--- Belt-and-suspenders against CWndContainer::Add()'s "only visible if
   //--- fully contained within the client area at that exact moment, else
   //--- latched invisible forever" behavior (see ReflowBelowActivePanel's
   //--- own comment in TradingPanel.mq5, which fixes the same failure mode
   //--- for Comment/BigPrice/Execute/ToggleLines). CreateFields() already
   //--- calls ApplyRowVisible for every row once during construction; this
   //--- gives the SL/TP rows the same re-assert-once-more-after-resizing
   //--- safety net, called once from CreatePanel()'s tail alongside
   //--- ReflowBelowActivePanel().
   void ReapplyRowVisibility() { for(int i = 0; i < ROW_COUNT; i++) ApplyRowVisible(i); }

   double SL()  { return PriceOf(ROW_SL); }
   double TP1() { return PriceOf(ROW_TP1); }
   double TP2() { return PriceOf(ROW_TP2); }
   double TP3() { return PriceOf(ROW_TP3); }

   ENUM_ACTIVE_TAB GetActiveTab()  { return m_activeTab; }
   bool            LinesVisible()  { return m_linesVisible; }

   //--- See m_suppressVisuals's own comment. Setting true does NOT redraw
   //--- anything itself (RefreshVisuals already no-ops while suppressed);
   //--- setting false doesn't either — the caller (CreatePanel(), at its
   //--- own reveal point) is expected to call RefreshVisuals() explicitly
   //--- right after un-suppressing, same as SetLinesVisible(true) already
   //--- does for the ordinary show-lines case.
   void SetSuppressVisuals(bool suppress) { m_suppressVisuals = suppress; }

   void SetActiveTab(ENUM_ACTIVE_TAB tab)
   {
      m_activeTab = tab;
      ApplyActiveTab();
   }

   //--- Sets the remembered direction WITHOUT recomputing/redrawing —
   //--- for a panel that isn't the active one yet. ApplyActiveTab() (which
   //--- SetActiveTab() above triggers) redraws THIS panel's SL/TP/Entry
   //--- lines, but all 4 order-type panels' lines share identical chart
   //--- object names (see lineName/labelName in CreateOrUpdateLine's own
   //--- call sites — only one panel is ever shown at a time), so calling
   //--- the full SetActiveTab() on an inactive panel would clobber the
   //--- ACTIVE panel's own on-chart lines. This just updates which
   //--- direction the panel will use the next time SwitchTab() actually
   //--- activates it.
   void SetDefaultTab(ENUM_ACTIVE_TAB tab) { m_activeTab = tab; }

   //--- Re-runs whatever the current direction/state already is (e.g. when a
   //--- hidden tab is switched back into view) without changing the direction.
   //--- Also the right place to catch up the lot split to Volume: this panel
   //--- may have been inactive (a different order-type tab shown) while
   //--- Volume changed, since OnEndEdit only reaches the ACTIVE panel.
   void ApplyActiveTab()
   {
      m_state = (m_activeTab == TAB_BUY) ? STATE_STAGED_BUY : STATE_STAGED_SELL;
      RescaleLotSplit();
      OnTabActivated();
   }

   void SetLinesVisible(bool visible)
   {
      m_linesVisible = visible;
      if(m_linesVisible) RefreshVisuals();
      else                RemoveChartLines();
   }

   //--- Volume changing never moves any SL/TP/Entry price — only the $
   //--- figures (money = pips * pip value * Lots()) and the per-TP Lot
   //--- column depend on it. Re-deriving those doesn't need the full
   //--- RefreshVisuals(), which unconditionally ObjectMove()s every line —
   //--- harmless if the user isn't touching one, but repeatedly nudging the
   //--- line someone's mid-drag on fights MT5's native drag tracking.
   //--- RepositionLabels() already rebuilds each price tag's text (which
   //--- includes the $ figure) from the current field values, so it's
   //--- exactly what's needed here without moving anything.
   void RefreshForVolumeChange()
   {
      //--- RescaleLotSplit() first: SyncAllRowsFromPrice()'s $ figures are
      //--- derived from each TP's own Lot share (see PipsToMoney), so the
      //--- split has to reflect the new volume before $ is computed from it,
      //--- not after, or every TP briefly shows $ from its old share.
      RescaleLotSplit();
      SyncAllRowsFromPrice();
      RepositionLabels();
   }

   void RefreshVisuals()
   {
      if(m_state == STATE_IDLE) return;
      //--- See m_suppressVisuals's own comment — a mid-build symbol-change
      //--- reinit can reach here (ApplySymbolChange -> ApplyActiveTab ->
      //--- OnTabActivated) well before CreatePanel()'s own reveal point,
      //--- and these are raw chart objects the "start Hidden" scheme for
      //--- dialog controls has no reach over at all.
      if(m_suppressVisuals) return;

      double refPrice = GetReferencePrice();

      if(!m_linesVisible)
      {
         RemoveChartLines();
         return;
      }

      if(refPrice <= 0.0)
      {
         ChartRedraw(m_chart_id);
         return;
      }

      datetime t1 = TimeCurrent();
      datetime t2 = t1 + PeriodSeconds() * 50;       // zone width — a fixed look-ahead, unrelated to viewport scroll
      datetime labelTime = RightEdgeTime();          // price tags hug the visible right edge instead

      color  lineClr[ROW_COUNT]  = {clrRed, clrForestGreen, clrForestGreen, clrForestGreen};
      string rowLabel[ROW_COUNT] = {"SL", "TP1", "TP2", "TP3"};

      for(int i = 0; i < ROW_COUNT; i++)
      {
         if(!m_rowEnabled[i]) continue;
         double price = PriceOf(i);
         CreateOrUpdateLine(m_name + "_Line_" + m_rowId[i], price, lineClr[i], rowLabel[i] + " Level");
         string tagText = rowLabel[i] + "  " + DoubleToString(price, SymbolDigits()) + "   " +
                           m_rowPips[i].Text() + " pips   " + AccountInfoString(ACCOUNT_CURRENCY) + " " + m_rowMoney[i].Text();
         CreateOrUpdatePriceLabel(m_name + "_Label_" + m_rowId[i], labelTime, PriceAbovePixels(labelTime, price, 12), tagText, lineClr[i]);
      }

      CreateOrUpdateLine(m_name + "_Line_Entry", refPrice, clrDodgerBlue, "Entry Level", STYLE_DOT, false);
      CreateOrUpdatePriceLabel(m_name + "_Label_Entry", labelTime, PriceAbovePixels(labelTime, refPrice, 12), "Entry  " + DoubleToString(refPrice, SymbolDigits()), clrDodgerBlue);

      CreateOrUpdateZone(m_name + "_Zone_Profit", t1, t2, refPrice, PriceOf(ROW_TP1), C'198,239,206');
      CreateOrUpdateZone(m_name + "_Zone_Loss",   t1, t2, refPrice, PriceOf(ROW_SL),  C'255,205,205');

      ChartRedraw(m_chart_id);
   }

   //--- Lightweight periodic refresh (see OnTimer): repositions price tags
   //--- to track the viewport's right edge as the user pans/zooms, reading
   //--- each line's own current on-chart position rather than the input
   //--- field's stored value. Deliberately does not touch the lines
   //--- themselves (no ObjectMove/CreateOrUpdateLine) — doing that from a
   //--- timer would fight an in-progress drag, since MT5 only delivers
   //--- CHARTEVENT_OBJECT_DRAG periodically while the line's true position
   //--- updates continuously, so the input field can be briefly behind the
   //--- line's real position. Also keeps the profit/loss zone rectangles
   //--- glued to SL/TP1/Entry's live positions, not just their labels, so
   //--- the shaded region visibly tracks a line while it's being dragged
   //--- instead of only snapping into place on mouse release.
   void RepositionLabels()
   {
      if(m_state == STATE_IDLE || !m_linesVisible) return;

      datetime labelTime = RightEdgeTime();
      color  lineClr[ROW_COUNT]  = {clrRed, clrForestGreen, clrForestGreen, clrForestGreen};
      string rowLabel[ROW_COUNT] = {"SL", "TP1", "TP2", "TP3"};
      double slPrice = 0.0, tp1Price = 0.0;

      for(int i = 0; i < ROW_COUNT; i++)
      {
         if(!m_rowEnabled[i]) continue;
         string lineName = m_name + "_Line_" + m_rowId[i];
         if(ObjectFind(m_chart_id, lineName) < 0) continue;
         double price = ObjectGetDouble(m_chart_id, lineName, OBJPROP_PRICE);
         if(i == ROW_SL)  slPrice  = price;
         if(i == ROW_TP1) tp1Price = price;
         string tagText = rowLabel[i] + "  " + DoubleToString(price, SymbolDigits()) + "   " +
                           m_rowPips[i].Text() + " pips   " + AccountInfoString(ACCOUNT_CURRENCY) + " " + m_rowMoney[i].Text();
         CreateOrUpdatePriceLabel(m_name + "_Label_" + m_rowId[i], labelTime, PriceAbovePixels(labelTime, price, 12), tagText, lineClr[i]);
      }

      double entryPrice = 0.0;
      string entryLineName = m_name + "_Line_Entry";
      if(ObjectFind(m_chart_id, entryLineName) >= 0)
      {
         entryPrice = ObjectGetDouble(m_chart_id, entryLineName, OBJPROP_PRICE);
         CreateOrUpdatePriceLabel(m_name + "_Label_Entry", labelTime, PriceAbovePixels(labelTime, entryPrice, 12), "Entry  " + DoubleToString(entryPrice, SymbolDigits()), clrDodgerBlue);
      }

      if(entryPrice > 0.0)
      {
         datetime t1 = TimeCurrent();
         datetime t2 = t1 + PeriodSeconds() * 50;
         if(tp1Price > 0.0) CreateOrUpdateZone(m_name + "_Zone_Profit", t1, t2, entryPrice, tp1Price, C'198,239,206');
         if(slPrice  > 0.0) CreateOrUpdateZone(m_name + "_Zone_Loss",   t1, t2, entryPrice, slPrice,  C'255,205,205');
      }

      ChartRedraw(m_chart_id);
   }

   //--- Called every tick (not just the periodic timer, which is only about
   //--- tracking viewport pans/zooms — see RepositionLabels): for Market,
   //--- whose reference price genuinely IS live bid/ask, keeps the Entry
   //--- line, its tag, and the profit/loss zones' entry-side edge tracking
   //--- the market instead of freezing at whatever price was current the
   //--- last time RefreshVisuals() ran a full redraw. No-op for Limit/Stop/
   //--- StopLimit, whose reference price is a fixed target, not live.
   void RepositionEntryIfLive()
   {
      if(!UsesLiveReferencePrice() || m_state == STATE_IDLE || !m_linesVisible) return;

      double refPrice = GetReferencePrice();
      if(refPrice <= 0.0) return;

      string entryLineName = m_name + "_Line_Entry";
      if(ObjectFind(m_chart_id, entryLineName) < 0) return; // nothing drawn yet — a full RefreshVisuals() will create it

      ObjectMove(m_chart_id, entryLineName, 0, 0, refPrice);

      datetime labelTime = RightEdgeTime();
      CreateOrUpdatePriceLabel(m_name + "_Label_Entry", labelTime, PriceAbovePixels(labelTime, refPrice, 12),
                                "Entry  " + DoubleToString(refPrice, SymbolDigits()), clrDodgerBlue);

      datetime t1 = TimeCurrent();
      datetime t2 = t1 + PeriodSeconds() * 50;
      CreateOrUpdateZone(m_name + "_Zone_Profit", t1, t2, refPrice, PriceOf(ROW_TP1), C'198,239,206');
      CreateOrUpdateZone(m_name + "_Zone_Loss",   t1, t2, refPrice, PriceOf(ROW_SL),  C'255,205,205');

      ChartRedraw(m_chart_id);
   }

   void RemoveChartLines()
   {
      string names[12];
      int n = 0;
      for(int i = 0; i < ROW_COUNT; i++)
      {
         names[n++] = m_name + "_Line_"  + m_rowId[i];
         names[n++] = m_name + "_Label_" + m_rowId[i];
      }
      names[n++] = m_name + "_Line_Entry";
      names[n++] = m_name + "_Label_Entry";
      names[n++] = m_name + "_Zone_Profit";
      names[n++] = m_name + "_Zone_Loss";

      for(int i = 0; i < n; i++)
         if(ObjectFind(m_chart_id, names[i]) >= 0) ObjectDelete(m_chart_id, names[i]);

      ChartRedraw(m_chart_id);
   }

   //--- A chart line was dragged: pull its new price back into that row's
   //--- price field, then re-derive pips/money from it. Uses
   //--- RepositionLabels(), the same drag-safe path the timer's periodic
   //--- refresh uses (see OnTimer), rather than the full RefreshVisuals()
   //--- (which recreates every line, both zones, and all labels): MT5 fires
   //--- drag events repeatedly while the mouse is still moving, and two
   //--- independent mechanisms racing to redraw the same zone rectangle
   //--- from slightly different snapshot moments produces a visible
   //--- jerk/shake instead of a smooth follow. RepositionLabels() never
   //--- touches the lines themselves, since the dragged line is already
   //--- exactly where MT5 rendered it — the one exception is a TP-ordering
   //--- clamp (see EnforceTPOrdering): if that rewrote the price to
   //--- something other than where the user dropped the line, the line
   //--- itself needs to be pulled back to match.
   void OnLineMoved(string objName)
   {
      if(ObjectFind(m_chart_id, objName) < 0) return;
      double price = ObjectGetDouble(m_chart_id, objName, OBJPROP_PRICE);

      for(int i = 0; i < ROW_COUNT; i++)
      {
         if(objName == m_name + "_Line_" + m_rowId[i])
         {
            m_rowPrice[i].Text(DoubleToString(price, SymbolDigits()));
            SyncRowFromPrice(i); // may clamp m_rowPrice[i] back into valid TP order

            double finalPrice = PriceOf(i);
            if(MathAbs(finalPrice - price) > SymbolPoint() / 2.0)
               ObjectMove(m_chart_id, objName, 0, 0, finalPrice); // lock the line to the clamped value too

            RepositionLabels();
            return;
         }
      }
   }

   //--- Routes an end-of-edit event to whichever of price/pips/money/lot field
   //--- changed, so only the relevant fields are re-derived from it. Anything
   //--- else (reference price field, Volume, Risk %) re-derives pips/money for
   //--- every row from its (unchanged) price, which stays authoritative, and
   //--- rescales the lot split to the (possibly changed) total volume.
   void OnEndEdit(string objName)
   {
      if(m_state == STATE_IDLE) return;

      for(int i = 0; i < ROW_COUNT; i++)
      {
         string base = m_name + "_" + m_rowId[i];
         if(objName == base + "_Price") { SyncRowFromPrice(i); RefreshVisuals(); return; }
         if(objName == base + "_Pips")  { SyncRowFromPips(i);  RefreshVisuals(); return; }
         if(objName == base + "_Money") { SyncRowFromMoney(i); RefreshVisuals(); return; }
         if(objName == base + "_Lot")   { OnLotEdited(i); return; }
      }

      //--- Risk % itself changed. SL is deliberately NOT moved here — with
      //--- Volume now auto-driven from SL distance + Risk % (see
      //--- TradingPanel.mq5's EnforceVolumeRiskLimit), SL is the free/
      //--- independent variable (wherever the trader's analysis puts it) and
      //--- Volume is what adjusts to respect the risk limit, not the other
      //--- way around.
      SyncAllRowsFromPrice();
      RescaleLotSplit();
      RefreshVisuals();
   }

   //--- Handles this panel's own buttons: spinners on every row, plus the
   //--- TP1/TP2-hosted "show next TP" toggles. Returns true if handled.
   bool OnClick(long lparam)
   {
      for(int i = 0; i < ROW_COUNT; i++)
      {
         if(lparam == m_rowPriceUp[i].Id())   { AdjustPrice(i,  10.0 * SymbolPoint()); return true; }
         if(lparam == m_rowPriceDown[i].Id()) { AdjustPrice(i, -10.0 * SymbolPoint()); return true; }
         if(lparam == m_rowPipsUp[i].Id())    { AdjustPips(i,  1.0); return true; }
         if(lparam == m_rowPipsDown[i].Id())  { AdjustPips(i, -1.0); return true; }
         if(lparam == m_rowMoneyUp[i].Id())   { AdjustMoney(i,  1.0); return true; }
         if(lparam == m_rowMoneyDown[i].Id()) { AdjustMoney(i, -1.0); return true; }
         if((i == ROW_TP2 || i == ROW_TP3) && lparam == m_rowLotUp[i].Id())   { AdjustLot(i,  LotStep()); return true; }
         if((i == ROW_TP2 || i == ROW_TP3) && lparam == m_rowLotDown[i].Id()) { AdjustLot(i, -LotStep()); return true; }
         if((i == ROW_TP1 || i == ROW_TP2) && lparam == m_rowToggle[i].Id()) { ToggleNextRow(i); return true; }
      }
      return false;
   }
};

#endif // ORDER_PANEL_BASE_MQH
