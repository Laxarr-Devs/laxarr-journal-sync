//+------------------------------------------------------------------+
//|                                                 TradingPanel.mq5 |
//|                                  Copyright 2026, MetaTrader 5 EA |
//|                                        Version 23.0                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      ""
#property version   "23.0"

//--- The panel previously exposed several diagnostic master-switch inputs
//--- (EnableRealTradeExecution, EnableBackendIntegration, EnableZOrderFix)
//--- used to isolate a stale "panel feels sticky / titlebar drag sometimes
//--- drags the chart instead" defect. All three have been retired: trade
//--- execution and Z-order proved stable on their own, and the actual
//--- cause was periodic WebRequest polling, which has since been removed
//--- in favor of manual sync (see OnClickSync) and event-driven,
//--- timer-spread retries for closed-position lifecycle POSTs.

//--- Backend connection. MT5 blocks all WebRequest calls to a URL unless
//--- its domain is explicitly whitelisted first: add "https://laxarr.com"
//--- under Tools > Options > Expert Advisors > "Allow WebRequest for
//--- listed URL". Without it, every sync fails (see PollRiskParameters'
//--- own comment in TradingPanelRiskSync.mqh).
input string ApiBaseUrl             = "https://laxarr.com/api/v1/mt5/"; // Backend base URL
input string ApiKey                 = "";                                // From your Laxarr account's API key settings
//--- Risk-parameter fetch and closed-trade sync are not polled on any
//--- interval; both are purely manual, via the panel's "Sync" button (see
//--- OnClickSync). This value now only paces work that stays periodic
//--- because it's local (no WebRequest) or worth spreading out regardless:
//--- RefreshCommissionEstimateIfDue's local history read, and the retry
//--- delay for a failed closed-position lifecycle POST (see
//--- FlushPendingTradePostsIfDue). MQL5 input parameters have no built-in
//--- min/max enforced in the properties dialog, so every use of this value
//--- reads it through MathMax(PollingIntervalSeconds, 10) rather than the
//--- raw input directly; OnInit warns once, at startup, if the configured
//--- value would have been floored.
input int    PollingIntervalSeconds = 10;                                // Refresh/retry cadence for local-only or retry-only work, in seconds (minimum 10)
input bool   EnableLogging          = true;                              // Show EA activity in the Experts log (errors/warnings always show regardless)

//--- Trade candle context + closed-position lifecycle reporting (see
//--- TradingPanelTradeReport.mqh). Independent toggles let a trader
//--- disable either feed without touching the core trade sync above; that
//--- sync is not gated by EnableTransactionReporting — a position close
//--- always triggers it regardless of this input (see
//--- CheckForPositionCloseAndHandle). EnableTransactionReporting: when a
//--- position fully closes, this posts one consolidated payload (every
//--- order/deal that ever belonged to it, rebuilt from MT5 history at that
//--- moment) to a separate raw-event audit feed.
input bool   EnableCandleReporting      = true;                          // POST OHLCV candle context (see below) for each closed trade
input bool   EnableTransactionReporting = true;                          // POST a full order/deal lifecycle summary when a position closes

//--- Closed-trade sync (see SyncClosedTradesIfDue/GetTradeSyncWatermark in
//--- TradingPanelTradeSync.mqh). A first-ever run back-fills up to this
//--- many days of already-closed history, gradually, at up to
//--- MAX_TRADE_SYNC_BATCH rows per poll — never all at once, so a trader
//--- with months of history doesn't fire one huge, possibly-timing-out
//--- POST the moment this EA is attached.
#define TRADE_SYNC_BACKFILL_DAYS 30
#define MAX_TRADE_SYNC_BATCH     15

//--- How often EmitHeartbeatIfDue prints its one-line "still alive and
//--- healthy" summary. Deliberately much longer than PollingIntervalSeconds
//--- (every poll would flood the log over a trading day), but short enough
//--- that a trader glancing at the Experts log can tell within a few
//--- minutes whether the EA has stalled.
#define HEARTBEAT_INTERVAL_SECONDS 300

//--- Trade candle context (see BuildAndPostTradeCandles/
//--- CandleTimeframeForDuration in TradingPanelTradeReport.mqh): a safety
//--- cap on candles-per-trade so an extreme multi-day swing trade can't
//--- build one huge POST even at H1 resolution. Trades held longer than
//--- MAX_CANDLE_TRADE_DURATION_DAYS get no candles rather than a
//--- silently-truncated series.
#define MAX_CANDLE_ROWS_PER_TRADE      2000
#define MAX_CANDLE_TRADE_DURATION_DAYS 5

//--- Closed-position lifecycle queue (see TradingPanelTradeReport.mqh):
//--- one entry per closed position, queued the moment OnTradeTransaction
//--- detects the close and flushed later from OnTimer, never synchronously
//--- from inside that callback (a blocking WebRequest there could stall
//--- MT5's own trade processing). Bounded so a long backend outage can't
//--- grow this without limit; the oldest entry is dropped (with a logged
//--- warning) once full. MAX_TRADE_POST_ATTEMPTS is the first send plus
//--- this many retries, each spaced MAX(PollingIntervalSeconds, 10) apart
//--- (see FlushPendingTradePostsIfDue) rather than back-to-back, since
//--- WebRequest blocks and retrying immediately in a loop would multiply
//--- that freeze instead of spreading it out.
#define MAX_TRADE_POST_QUEUE    50
#define MAX_TRADE_POST_ATTEMPTS 4

#include <Controls\Dialog.mqh>
#include <Controls\Label.mqh>
#include <Controls\Panel.mqh>
#include <Controls\Edit.mqh>
#include <Controls\Button.mqh>
#include <Controls\ComboBox.mqh>
#include <Trade\Trade.mqh>

#include "OrderPanelBase.mqh"
#include "MarketExecutionPanel.mqh"
#include "LimitOrderPanel.mqh"
#include "StopOrderPanel.mqh"
#include "StopLimitOrderPanel.mqh"

CTrade trade;

//--- Layout constants for the shared dialog chrome
//--- (ROW_X / ROW_HEIGHT* / FIELD_GAP come from OrderPanelBase.mqh)
//--- CDialog's client area sits inset from the outer dialog rect by a
//--- fixed CLIENT_INSET on every side (2*CONTROLS_BORDER_WIDTH +
//--- CONTROLS_DIALOG_CLIENT_OFF = 2+2 = 4px, per Dialog.mqh's
//--- CreateClientArea()). Our own ROW_X/RIGHT_COL_X margin is measured
//--- from the client area's edge (via ContainerOffsetX(), which reads the
//--- true rendered position), so the left gap ends up CLIENT_INSET+ROW_X
//--- automatically. DIALOG_WIDTH is a raw compile-time width measured from
//--- the outer edge, so it must add CLIENT_INSET back in on the right or
//--- the right-side gap comes out CLIENT_INSET pixels shorter than the
//--- left.
#define DIALOG_CLIENT_INSET 4
#define DIALOG_WIDTH       (582 + 2 * DIALOG_CLIENT_INSET)
#define DIALOG_HEIGHT      374   // matches the default collapsed state (TP2/TP3 hidden, risk-limits accordion collapsed); ReflowBelowActivePanel() resizes at runtime
#define RIGHT_COL_X        12
//--- RIGHT_COL_X + FORM_CONTENT_WIDTH must equal the SL/TP row block's
//--- right edge (ToggleX()+TOGGLE_W in OrderPanelBase.mqh) so Comment/
//--- Execute/Hide-Lines line up flush with the rows above them instead of
//--- stopping short and leaving a lopsided right margin.
#define FORM_CONTENT_WIDTH 558
//--- One extra spacebar's width of breathing room between a label and its
//--- own field, header rows only (Order Type / Symbol / Volume / Risk % /
//--- Comment) — simple, fixed, on top of OrderPanelBase's own FIELD_GAP (4).
#define HEADER_FIELD_GAP   6
#define RISK_CARD_H        74   // height of each risk-limits card (see m_riskCardBg)

enum ENUM_ORDER_KIND
{
   ORDER_MARKET,
   ORDER_LIMIT,
   ORDER_STOP,
   ORDER_STOPLIMIT
};

//--- One closed position's fully-built JSON payload, queued for
//--- FlushPendingTradePostsIfDue to send (and retry) from OnTimer — see
//--- MAX_TRADE_POST_QUEUE/MAX_TRADE_POST_ATTEMPTS's own comment. Built once
//--- upfront (see BuildClosedPositionLifecycleJson in
//--- TradingPanelTradeReport.mqh) rather than re-derived on every retry, so
//--- a retry is just a plain resend of the same bytes.
struct SPendingTradePost
{
   string   payload;
   int      attempts;
   datetime nextAttemptTime;
};

//+------------------------------------------------------------------+
//| Trading Panel Dialog                                             |
//|                                                                    |
//| This class's member variables and every method SIGNATURE live    |
//| here — the orchestrator. Larger method BODIES are implemented    |
//| out-of-line (MQL5 supports the same ClassName::Method() syntax   |
//| as C++) in topic-focused .mqh files included after the class's   |
//| closing brace below:                                             |
//|   TradingPanelUI.mqh          - layout construction & reflow     |
//|   TradingPanelVolumeRisk.mqh  - hands-free volume + Risk % lock  |
//|   TradingPanelRiskSync.mqh    - backend risk-parameter polling   |
//|   TradingPanelTradeSync.mqh   - closed-trade sync (POST /sync/)  |
//|   TradingPanelGuardrails.mqh  - blocking checks + Execute flow   |
//| Small, tightly-coupled-to-orchestration methods (one-liners, the |
//| event dispatch table, the constructor) stay inline here.         |
//+------------------------------------------------------------------+
class CTradingPanelDialog : public CAppDialog
{
private:
   ENUM_ORDER_KIND m_activeKind;
   int             m_slStartY; // fixed Y of the SL row, shared by every panel — needed to reflow what's below it
   bool            m_panelCollapsed; // whole-panel collapse (distinct from a single order-type panel's own TP2/TP3 collapse)
   //--- Tick-direction flash on the big price readout: green on an uptick,
   //--- red on a downtick, held until the next tick moves it again, for the
   //--- "dancing" real-time feel the panel should have without literal
   //--- on-screen jitter.
   double          m_lastReadoutBid;
   //--- Periodic self-heal (see SelfHealLayoutIfDue). Uses GetTickCount64(),
   //--- not TimeCurrent(), since this must keep firing even while the
   //--- market's closed and no ticks are arriving.
   ulong           m_lastSelfHealTick;
   //--- Risk-based position sizing: Volume is fully hands-free. The trader
   //--- only sets Max Risk %, and Volume is always exactly what that
   //--- implies for the active panel's current SL distance (see
   //--- EnforceVolumeRiskLimit). The Volume field itself is read-only; the
   //--- trader's only manual lever is how the total splits across
   //--- TP1/TP2/TP3 (the Lot column), which stays fully editable.

   //--- Account-wide risk limits fetched from the backend (see
   //--- RefreshRiskParametersIfDue/PollRiskParameters).
   bool     m_riskParamsLoaded;
   //--- Set the moment PollRiskParameters() detects a missing or rejected
   //--- (401/403) API key. Checked at the top of RefreshRiskParametersIfDue
   //--- to stop firing WebRequest entirely from then on, since a bad key
   //--- cannot self-correct by retrying forever. Reset in CreatePanel()
   //--- (same lifecycle as m_panelCollapsed) so the trader gets a fresh
   //--- attempt the next time the EA reinitializes (reattach, recompile, or
   //--- a timeframe/symbol change), e.g. after fixing the ApiKey input.
   bool     m_riskPollingHalted;
   //--- True once the trader has manually typed a Risk % different from the
   //--- account default (auto-set by SetRiskLocked from OnEndEdit), or
   //--- toggled m_btnRiskLock on directly. While true,
   //--- RefreshRiskParametersIfDue's poll-driven sync leaves the field
   //--- alone instead of overwriting the manual value on the next cycle.
   //--- Cleared either by clicking the lock button again or by a
   //--- successful Execute (see OnClickExecute), since a fresh trade has
   //--- used up the custom value and the field resumes tracking the account
   //--- default. Meaningless in fixed-lot mode (the field isn't editable
   //--- there), so both the lock button and this flag's effect are gated on
   //--- !IsFixedLotMode() alongside the spinner buttons.
   bool     m_riskLocked;
   //--- Accordion state for the risk-limits cards (see m_riskCardBg),
   //--- collapsed by default so the panel isn't cluttered with account-wide
   //--- info the trader hasn't asked to see; ReflowBelowActivePanel() reads
   //--- this every time it repositions the block below the SL/TP rows.
   bool     m_riskCardsCollapsed;
   double   m_riskPerTradePercent;
   bool     m_useFixedLot;
   //--- 0 means off/not set for all five of these, matching MQL5's own
   //--- StringToDouble("")/StringToInteger("") (both already 0), so the
   //--- backend's blank-field convention and a trader explicitly entering 0
   //--- collapse into the same sentinel with no separate bookkeeping needed.
   double   m_fixedLotSize;
   double   m_maxRiskPerTradePercent;
   double   m_maxDailyLossPercent;
   int      m_maxOpenPositions;
   double   m_minRiskRewardRatio;
   int      m_maxConsecutiveLosses;
   string   m_riskParamsError;
   //--- "When did this last run" readouts for RefreshRiskParametersIfDue/
   //--- SyncClosedTradesIfDue. No longer rate-limit gates (both are purely
   //--- manual now, via the "Sync" button — see OnClickSync); kept as
   //--- timestamps in case a future readout wants to show "last synced at".
   datetime m_lastRiskPollTime;
   datetime m_lastTradeSyncPollTime;
   //--- Rate-limit gate for EmitHeartbeatIfDue. Deliberately a much longer
   //--- cadence than PollingIntervalSeconds (see HEARTBEAT_INTERVAL_SECONDS),
   //--- since its purpose is to prove the EA is alive at a glance, not to
   //--- report every individual poll.
   datetime m_lastHeartbeatTime;
   //--- Closed-position lifecycle payloads awaiting send/retry — see
   //--- SPendingTradePost's own comment and TradingPanelTradeReport.mqh.
   //--- Appended to synchronously from the OnTradeTransaction callback
   //--- (cheap: building the JSON hits HistorySelectByPosition/
   //--- HistoryDealGet*/HistoryOrderGet*, all local, no WebRequest), and
   //--- drained from OnTimer via FlushPendingTradePostsIfDue, at most one
   //--- WebRequest call per timer tick.
   SPendingTradePost m_pendingTradePosts[];
   //--- Set by CheckForPositionCloseAndHandle (in TradingPanelTradeReport.mqh)
   //--- the instant a position is confirmed closed; consumed and cleared by
   //--- the next OnTimer tick, which then runs a real SyncClosedTradesIfDue
   //--- (the same mechanism the "Sync" button uses), so the journal/
   //--- Trade-row data catches up automatically after every close. A single
   //--- flag, not a queue: SyncClosedTradesIfDue already scans everything
   //--- closed since the watermark in one call, so several closes in quick
   //--- succession still only need one sync.
   bool m_closeSyncPending;
   //--- Cache for the Est. Trade Cost readout's commission estimate. A
   //--- full-history HistorySelect + backward deal scan (see
   //--- EstimateCommissionPerLot) is too costly to run every tick, so it's
   //--- only refreshed on symbol change (ApplySymbolChange) or every
   //--- PollingIntervalSeconds (RefreshCommissionEstimateIfDue), the same
   //--- gate pattern as m_lastRiskPollTime/m_lastTradeSyncPollTime above.
   string   m_commissionEstSymbol;
   bool     m_hasCommissionEstimate;
   double   m_commissionPerLotEstimate;
   datetime m_lastCommissionEstTime;

   //--- Last expanded outer height ReflowBelowActivePanel() actually set
   //--- (persisted there — see its own comment). Not touched by
   //--- SetPanelCollapsed()'s collapsed-height Size() call, since
   //--- CreatePanel() unconditionally forces m_panelCollapsed=false on
   //--- every reinit, so the panel always rebuilds expanded; remembering a
   //--- collapsed height here would remember a size CreatePanel() will
   //--- never actually produce. 0 (the constructed default) means "no
   //--- prior session" — CreatePanel() falls back to DIALOG_HEIGHT. Used to
   //--- size the dialog to its eventual real size immediately, rather than
   //--- growing/shrinking visibly once ReflowBelowActivePanel() runs.
   int m_lastPanelHeight;

   CLabel m_bgLabel;

   //--- Order type picker (replaces the old 4-button sidebar)
   CLabel    m_lblOrderType;
   CComboBox m_comboOrderType;

   //--- Shared, order-agnostic fields
   CLabel    m_lblSymbol, m_lblVolume, m_lblRisk, m_lblComment;
   CComboBox m_comboSymbol;             // Market Watch symbol picker
   CEdit     m_editVolume, m_editRisk, m_editComment;
   //--- Small "≈ cost" readout docked above the right portion of the
   //--- Comment field — see UpdatePriceReadout in TradingPanelUI.mqh.
   CLabel    m_lblTradeCost;
   CButton   m_btnRiskDown, m_btnRiskUp; // spinner for m_editRisk (see AdjustRiskPercent)
   //--- Third small button after the spinner pair — toggles m_riskLocked
   //--- (see SetRiskLocked). Same size as m_btnRiskDown/m_btnRiskUp so the
   //--- three read as one control group.
   CButton   m_btnRiskLock;
   //--- Readout of the fetched account risk limits: three framed cards, one
   //--- per section of the web app's own Risk Parameters page (Position
   //--- Sizing / Account Guardrails / Advice Targets). CPanel, not CLabel,
   //--- for the frame itself: CLabel wraps a plain OBJ_LABEL, which has no
   //--- background-fill/border rendering (its ColorBackground/ColorBorder
   //--- are inherited generic CWndObj setters that Controls/Label.mqh never
   //--- wires to anything), whereas Panel.mqh's OnSetColorBackground/
   //--- OnSetColorBorder do apply to a real OBJ_RECTANGLE_LABEL. Text inside
   //--- each card is plain CLabels layered on top, up to 3 lines per card
   //--- (some left blank), since OBJ_LABEL has no multi-line/wrap support
   //--- either (an embedded "\n" in a label's Text() is not a line break,
   //--- just concatenated text).
   CPanel    m_riskCardBg[3];
   CLabel    m_riskCardTitle[3];
   CLabel    m_riskCardLine[3][3];

   //--- Price Display & Main Actions
   CLabel  m_lblBigPrice;
   CLabel  m_lblPipValue; // $ per pip for the current symbol at the current total Volume
   CButton m_btnTabBuy;
   CButton m_btnTabSell;
   CButton m_btnExecute;
   CButton m_btnToggleLines;
   CButton m_btnToggleRiskCards; // expands/collapses the risk-limits accordion (see m_riskCardsCollapsed)
   //--- Manual risk-parameter fetch + closed-trade sync (see OnClickSync in
   //--- TradingPanelRiskSync.mqh) — shares this row with m_btnToggleRiskCards,
   //--- same half-width split as Execute/ToggleLines below.
   CButton m_btnSync;
   //--- Top-right corner of the header row. Wipes every chart drawing this
   //--- EA owns and reseeds SL/TP1-3 from scratch (see OnClickReset in
   //--- TradingPanelUI.mqh) — a manual escape hatch for "the lines are a
   //--- mess, just give me what I'd see on a fresh attach."
   //--- Styled to match the inactive BUY/SELL tab look (see
   //--- StyleBuySellButtons' C'210,210,210'/clrBlack) rather than a
   //--- distinct color scheme, so it reads as the same family of control.
   CButton m_btnReset;

   //--- One panel per order type; only one is visible/active at a time
   CMarketExecutionPanel m_panelMarket;
   CLimitOrderPanel      m_panelLimit;
   CStopOrderPanel       m_panelStop;
   CStopLimitOrderPanel  m_panelStopLimit;

   COrderPanelBase *ActivePanel()
   {
      switch(m_activeKind)
      {
         case ORDER_LIMIT:     return GetPointer(m_panelLimit);
         case ORDER_STOP:      return GetPointer(m_panelStop);
         case ORDER_STOPLIMIT: return GetPointer(m_panelStopLimit);
         default:               return GetPointer(m_panelMarket);
      }
   }

   //--- Event Handlers
   void OnTabBuy()                    { ActivePanel().SetActiveTab(TAB_BUY);  StyleBuySellButtons(); }
   void OnTabSell()                   { ActivePanel().SetActiveTab(TAB_SELL); StyleBuySellButtons(); }
   //--- See TradingPanelGuardrails.mqh
   void OnClickExecute();

   string OrderKindLabel(ENUM_ORDER_KIND kind)
   {
      switch(kind)
      {
         case ORDER_LIMIT:     return "Limit";
         case ORDER_STOP:      return "Stop";
         case ORDER_STOPLIMIT: return "Stop Limit";
         default:               return "Market";
      }
   }

   //--- See TradingPanelGuardrails.mqh
   string BuildTradeConfirmationMessage();
   void OnClickToggleLines()          { ToggleLines(); }
   //--- See TradingPanelVolumeRisk.mqh
   void OnEndEdit(string objName);

   //--- See TradingPanelUI.mqh
   bool CreateSharedRow(string rowID, CLabel &lbl, CEdit &edit, string labelText, string defaultValue,
                         int x, int labelW, int editW, int y);

   //--- See TradingPanelUI.mqh
   void StyleBuySellButtons();

   //--- See TradingPanelUI.mqh
   void SwitchTab(ENUM_ORDER_KIND kind);

   void ToggleLines()
   {
      COrderPanelBase *panel = ActivePanel();
      bool newState = !panel.LinesVisible();
      panel.SetLinesVisible(newState);
      m_btnToggleLines.Text(newState ? "Hide Lines" : "Show Lines");
   }

   //--- See TradingPanelUI.mqh
   void OnClickToggleRiskCards();

   //--- See TradingPanelUI.mqh
   void OnClickReset();

   //--- See TradingPanelVolumeRisk.mqh
   void AdjustRiskPercent(double delta);

   //--- See TradingPanelVolumeRisk.mqh
   void SetRiskLocked(bool locked);

   void ToggleRiskLock() { SetRiskLocked(!m_riskLocked); }

   //--- See TradingPanelVolumeRisk.mqh
   void UpdateRiskLockVisual();

   //--- See TradingPanelUI.mqh
   void PopulateOrderTypeCombo();

   void OnOrderTypeChanged() { SwitchTab((ENUM_ORDER_KIND)m_comboOrderType.Value()); }

   //--- See TradingPanelUI.mqh
   void PopulateSymbolCombo();

   //--- See TradingPanelUI.mqh
   void ApplySymbolChange();

   void OnSymbolChanged() { ApplySymbolChange(); }

   //--- CWndContainer::Add() silently shifts a newly-added control by the
   //--- owning container's on-screen position, translating the
   //--- dialog-relative coordinates Create() was given into true
   //--- chart-absolute ones. Move() has no such translation. m_bgLabel was
   //--- Create()'d at dialog-relative (0,0) and is never itself Move()'d
   //--- (only Size()'d), so its current on-screen position is the offset;
   //--- re-derive it fresh on every call rather than caching it once, so
   //--- this stays correct even if the user drags the dialog window between
   //--- calls.
   int ContainerOffsetX() { return m_bgLabel.Left(); }
   int ContainerOffsetY() { return m_bgLabel.Top(); }

   //--- See TradingPanelUI.mqh
   void ReflowBelowActivePanel();

   //--- See TradingPanelUI.mqh
   void RestyleTitleBar();

   //--- See TradingPanelUI.mqh — wraps the inherited Add() so every control
   //--- added through it starts Hidden, so the trader sees the panel appear
   //--- fully built rather than watching each control pop in individually
   //--- on a symbol-change reinit. Every one of CreatePanel()'s own ~25
   //--- top-level Add() calls goes through this instead now;
   //--- COrderPanelBase::AddControl does the equivalent for each
   //--- order-type panel's own row controls.
   bool AddHidden(CWnd &control);

   //--- See TradingPanelUI.mqh
   ENUM_ACTIVE_TAB GuessDefaultTabFromPriceRange();

   //--- See TradingPanelUI.mqh
   void SetPanelCollapsed(bool collapsed);

   void TogglePanelCollapse() { SetPanelCollapsed(!m_panelCollapsed); }

   //--- The native minimize button shrinks the dialog down to a sliver that's
   //--- hard to even see, let alone click to restore (CAppDialog::Minimize()/
   //--- m_min_rect). Overriding this (it's declared virtual in CAppDialog)
   //--- redirects that same "-" button to our own collapse instead, which
   //--- stays clearly visible and labeled.
   virtual void OnClickButtonMinMax(void) override { TogglePanelCollapse(); }

public:
   CTradingPanelDialog() : m_activeKind(ORDER_MARKET), m_panelCollapsed(false), m_lastReadoutBid(0.0),
                            m_riskParamsLoaded(false), m_riskPollingHalted(false), m_riskLocked(false), m_riskCardsCollapsed(true), m_riskPerTradePercent(0.0),
                            m_useFixedLot(false), m_fixedLotSize(0.0),
                            m_maxRiskPerTradePercent(0.0), m_maxDailyLossPercent(0.0),
                            m_maxOpenPositions(0), m_minRiskRewardRatio(0.0),
                            m_maxConsecutiveLosses(0), m_riskParamsError(""),
                            m_lastRiskPollTime(0), m_lastTradeSyncPollTime(0), m_lastHeartbeatTime(0), m_lastSelfHealTick(0),
                            m_closeSyncPending(false), m_lastPanelHeight(0),
                            m_commissionEstSymbol(""), m_hasCommissionEstimate(false), m_commissionPerLotEstimate(0.0), m_lastCommissionEstTime(0) {}

   //--- See TradingPanelUI.mqh
   bool CreatePanel();

   //--- See TradingPanelUI.mqh
   void DestroyLines();

   //--- See TradingPanelUI.mqh
   void ResetPanel();

   //--- See TradingPanelUI.mqh
   void UpdatePriceReadout();

   //--- Fixed at 2 decimal places everywhere a lot value is displayed,
   //--- regardless of the broker's own SYMBOL_VOLUME_STEP precision.
   int VolumeDigits(string sym) { return 2; }

   //--- The broker's own floor — Volume is never allowed below this,
   //--- regardless of how small the risk-based ceiling computes to.
   double VolumeMin(string sym) { return (sym != "") ? SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN) : 0.01; }

   //--- See TradingPanelVolumeRisk.mqh
   double ComputeMaxVolume();

   //--- The account is configured for a fixed lot size, not risk-based
   //--- sizing — only once risk parameters have actually loaded (fails open
   //--- to the normal risk-based/editable behavior otherwise, same
   //--- philosophy as CheckRiskLimitsBlocking).
   bool IsFixedLotMode() { return m_riskParamsLoaded && m_useFixedLot && m_fixedLotSize > 0.0; }

   //--- See TradingPanelVolumeRisk.mqh
   double NormalizedFixedLotVolume();

   //--- See TradingPanelVolumeRisk.mqh
   double ComputeImpliedRiskPercent(double volume);

   //--- See TradingPanelVolumeRisk.mqh
   void WriteVolumeAndSync(double volume);

   //--- See TradingPanelVolumeRisk.mqh
   void EnforceTPAvailabilityForVolume();

   //--- See TradingPanelVolumeRisk.mqh
   void ApplyFixedLotMode();

   //--- See TradingPanelVolumeRisk.mqh
   void EnforceVolumeRiskLimit();

   //--- Periodic refresh (see OnTimer): repositions the active panel's price
   //--- tags so they track the viewport's right edge as the user pans/zooms.
   //--- Deliberately does NOT touch the lines themselves — see RepositionLabels().
   void RepositionActivePanelLabels() { ActivePanel().RepositionLabels(); }

   //--- See TradingPanelUI.mqh
   void SelfHealLayoutIfDue();

   //--- See TradingPanelUI.mqh
   void ReassertHeaderControlsVisible();

   //--- See TradingPanelUI.mqh — used by ReassertHeaderControlsVisible for
   //--- m_comboOrderType/m_comboSymbol specifically, instead of Show().
   void ReassertComboEdgeVisible(CComboBox &combo);

   //--- Called every tick (see global OnTick): for Market, whose reference
   //--- price IS live bid/ask, keeps the Entry line/zones tracking it in
   //--- real time instead of freezing at the last full redraw. No-op for
   //--- Limit/Stop/StopLimit — see RepositionEntryIfLive's own comment.
   void RepositionActiveEntryIfLive() { ActivePanel().RepositionEntryIfLive(); }

   //--- Called every OnTimer tick (see global OnTimer). m_closeSyncPending
   //--- is private (set from CheckForPositionCloseAndHandle in
   //--- TradingPanelTradeReport.mqh) — this is the public wrapper that lets
   //--- the global timer function check-and-clear it without needing direct
   //--- member access, same pattern as RepositionActiveEntryIfLive above.
   void RunPendingCloseSyncIfDue()
   {
      if(!m_closeSyncPending) return;
      m_closeSyncPending = false;
      SyncClosedTradesIfDue();
   }

   //--- See TradingPanelUI.mqh
   void OnLineMoved(string objName);

   //--- CAppDialog wires only one object as a native drag handle: its own
   //--- caption label. Every plain CLabel elsewhere on the panel and
   //--- m_bgLabel itself are not selectable, so a click-drag starting there
   //--- finds nothing for the terminal to grab and falls through to the
   //--- default behavior of panning the chart instead.
   //---
   //--- Fix: make m_bgLabel selectable too (see CreatePanel() in
   //--- TradingPanelUI.mqh), so the whole body becomes a second drag handle
   //--- exactly like the caption. BgLabelName()/OnBackgroundDragged() below
   //--- make dragging that object actually move the dialog, the same way
   //--- CAppDialog's own internals do for the caption.
   string BgLabelName() { return m_bgLabel.Name(); }

   //--- Mirrors what CAppDialog does internally when its caption is
   //--- dragged: the terminal has already moved m_bgLabel's underlying
   //--- chart object to a new absolute pixel position (native drag). Read
   //--- that, work out how far it moved from where ContainerOffsetX/Y last
   //--- knew it to be, and Move() the whole dialog by that same delta.
   //--- Move() then repositions every child, bgLabel included, back into
   //--- exact alignment from its own stored layout, the same
   //--- self-correcting relationship ContainerOffsetX/Y already relies on,
   //--- just driven from the body instead of the caption.
   void OnBackgroundDragged()
   {
      int oldBgX = ContainerOffsetX(), oldBgY = ContainerOffsetY();
      int newBgX = (int)ObjectGetInteger(m_chart_id, m_bgLabel.Name(), OBJPROP_XDISTANCE);
      int newBgY = (int)ObjectGetInteger(m_chart_id, m_bgLabel.Name(), OBJPROP_YDISTANCE);
      Move(Left() + (newBgX - oldBgX), Top() + (newBgY - oldBgY));
   }

   //--- See TradingPanelRiskSync.mqh
   bool JsonExtractString(const string json, const string key, string &outValue);

   //--- See TradingPanelRiskSync.mqh
   int BrokerUtcOffsetMinutes();

   //--- See TradingPanelRiskSync.mqh
   bool PollRiskParameters();

   //--- See TradingPanelVolumeRisk.mqh
   void ApplyRiskCeiling();

   //--- See TradingPanelRiskSync.mqh
   void SetWrappedCardLines(int cardIdx, string fullText, int maxCharsPerLine = 24);

   //--- See TradingPanelRiskSync.mqh
   void UpdateRiskLimitsLabel();

   //--- See TradingPanelRiskSync.mqh
   void RefreshRiskParametersIfDue();

   //--- See TradingPanelRiskSync.mqh — the "Sync" button's click handler:
   //--- one manual, one-shot RefreshRiskParametersIfDue + SyncClosedTradesIfDue.
   //--- Neither runs on any timer/polling loop — clicking Sync is the only
   //--- way either ever fires, and each call does exactly one WebRequest
   //--- (or one small sequence of them) and returns, it doesn't keep going.
   void OnClickSync();

   //================================================================
   //  Closed-trade sync — POST /mt5/sync/ — see TradingPanelTradeSync.mqh
   //================================================================
   string TradeSyncWatermarkVarName();
   datetime GetTradeSyncWatermark();
   void SetTradeSyncWatermark(datetime value);
   string ToIso8601(datetime dt);
   void ResolvePositionEntry(long positionId, double &openPrice, datetime &openTime, double &sl, double &tp);
   void BuildAndPostClosedTrades(datetime fromTime);
   void SyncClosedTradesIfDue();

   //--- Est. Trade Cost readout's commission estimate — see
   //--- TradingPanelTradeSync.mqh
   bool EstimateCommissionPerLot(string sym, double &commissionPerLot);
   void RefreshCommissionEstimateIfDue(bool force = false);

   //================================================================
   //  Trade candle context + OnTradeTransaction lifecycle reporting —
   //  see TradingPanelTradeReport.mqh
   //================================================================
   string EscapeJsonString(string s);
   bool   CandleTimeframeForDuration(datetime openTime, datetime closeTime, ENUM_TIMEFRAMES &tf);
   string TimeframeLabel(ENUM_TIMEFRAMES tf);
   void   BuildAndPostTradeCandles(string symbol, string ticket, datetime openTime, datetime closeTime);

   void   CheckForPositionCloseAndHandle(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result);
   string BuildClosedPositionLifecycleJson(long positionId, long triggerDeal, const MqlTradeResult &triggerResult);
   void   FlushPendingTradePostsIfDue();

   //--- See TradingPanelRiskSync.mqh
   void EmitHeartbeatIfDue();

   //--- See TradingPanelGuardrails.mqh
   double ComputeTodayPnL();

   //--- See TradingPanelGuardrails.mqh
   void CloseAllPositions();

   //--- See TradingPanelGuardrails.mqh
   void EnforceDailyLossLimit();

   //--- See TradingPanelGuardrails.mqh
   int ComputeTodayLossStreak();

   string RowLabel(int i)
   {
      if(i == ROW_TP1) return "TP1";
      if(i == ROW_TP2) return "TP2";
      if(i == ROW_TP3) return "TP3";
      return "SL";
   }

   //--- See TradingPanelGuardrails.mqh
   string CheckRiskLimitsBlocking();

   virtual bool OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam) override
   {
      if(id == CHARTEVENT_CUSTOM + ON_CLICK)
      {
         if(lparam == m_btnTabBuy.Id())      { OnTabBuy(); return true; }
         if(lparam == m_btnTabSell.Id())     { OnTabSell(); return true; }
         if(lparam == m_btnExecute.Id())     { OnClickExecute(); return true; }
         if(lparam == m_btnToggleLines.Id()) { OnClickToggleLines(); return true; }
         if(lparam == m_btnToggleRiskCards.Id()) { OnClickToggleRiskCards(); return true; }
         if(lparam == m_btnSync.Id())            { OnClickSync(); return true; }
         if(lparam == m_btnReset.Id())        { OnClickReset(); return true; }
         if(lparam == m_btnRiskDown.Id()) { AdjustRiskPercent(-0.1); return true; }
         if(lparam == m_btnRiskUp.Id())   { AdjustRiskPercent( 0.1); return true; }
         if(lparam == m_btnRiskLock.Id()) { ToggleRiskLock(); return true; }

         if(ActivePanel().OnClick(lparam))
         {
            EnforceVolumeRiskLimit(); // real-time: an SL spinner click moves the risk-based ceiling
            ReflowBelowActivePanel(); // covers the TP2/TP3 show/hide buttons without a panel->dialog callback
            return true;
         }
      }

      if(id == CHARTEVENT_CUSTOM + ON_CHANGE)
      {
         if(lparam == m_comboOrderType.Id()) { OnOrderTypeChanged(); return true; }
         if(lparam == m_comboSymbol.Id())    { OnSymbolChanged(); return true; }
      }

      if(id == CHARTEVENT_CUSTOM + ON_END_EDIT)
      {
         OnEndEdit(sparam);
         return true;
      }

      return CAppDialog::OnEvent(id, lparam, dparam, sparam);
   }
};

//--- Out-of-line method bodies for CTradingPanelDialog above — see each
//--- file's own header comment for what it covers. Must come after the
//--- class declaration is complete (MQL5 requires the class to already be
//--- known before ClassName::Method() definitions referencing it).
#include "TradingPanelUI.mqh"
#include "TradingPanelVolumeRisk.mqh"
#include "TradingPanelRiskSync.mqh"
#include "TradingPanelTradeSync.mqh"
#include "TradingPanelTradeReport.mqh"
#include "TradingPanelGuardrails.mqh"

CTradingPanelDialog ExtPanel;

int OnInit()
{
   //--- White-background chart scheme, no grid. Runs on every (re)init, so
   //--- it's reapplied on first attach, terminal restart, recompile, and
   //--- whenever the chart's symbol/timeframe change reinitializes the EA.
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrWhite);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, clrBlack);
   //--- Candlestick body/border colors matching the reference palette
   //--- (teal-green up, red down). CHART_MODE forces true candlesticks
   //--- regardless of whatever chart type the terminal was in before this
   //--- EA attached, since a Bars/Line chart would otherwise ignore the
   //--- CANDLE_BULL/BEAR colors entirely. CHART_COLOR_CHART_UP/DOWN (the
   //--- wick/border color) is set to the same value as the body fill so
   //--- each candle reads as one solid color rather than an outlined body
   //--- with a different-colored wick.
   ChartSetInteger(0, CHART_MODE, CHART_CANDLES);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, C'38,166,154');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, C'239,83,80');
   ChartSetInteger(0, CHART_COLOR_CHART_UP,    C'38,166,154');
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN,  C'239,83,80');
   //--- Chart shift opens empty space to the right of the latest bar, so
   //--- SL/TP/Entry lines drawn out ahead of price have room to be visible
   //--- instead of running off the right edge of the chart.
   ChartSetInteger(0, CHART_SHIFT, true);

   if(PollingIntervalSeconds < 10)
      Print("PollingIntervalSeconds (", PollingIntervalSeconds, ") is below the 10-second minimum — flooring it to 10.");

   if(!ExtPanel.CreatePanel()) return INIT_FAILED;
   ExtPanel.Run();
   //--- 50ms, not 500ms: RepositionLabels() keeps the profit/loss zone
   //--- glued to a line while it's being dragged (see OnLineMoved's own
   //--- comment); at 500ms the mouse visibly outpaced it, so the zone
   //--- lagged and only caught up when a tick landed. Everything this timer
   //--- drives (a handful of ObjectSet/ObjectGet calls) is cheap enough to
   //--- run this often for a single EA.
   EventSetMillisecondTimer(50);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ExtPanel.DestroyLines();
   ExtPanel.Destroy(reason);
   //--- Final sweep: deletes every chart object whose name starts with
   //--- "TradingPanelEA" (the fixed, symbol-independent prefix every
   //--- control/line/label/zone this EA creates is built from). Catches
   //--- anything the two calls above missed, from any past session, on
   //--- this chart, so the trader doesn't have to manually clean up stray
   //--- lines/zones after removing the EA.
   ObjectsDeleteAll(0, "TradingPanelEA");
}

void OnTick()
{
   ExtPanel.UpdatePriceReadout();
   ExtPanel.RepositionActiveEntryIfLive();
   //--- Volume is read-only, so a live rewrite here can never collide with
   //--- mid-edit typing (see EnforceVolumeRiskLimit's own comment) — this
   //--- is what keeps Volume tracking a Market order's SL pip distance as
   //--- it drifts with the live price, with no explicit SL edit at all.
   ExtPanel.EnforceVolumeRiskLimit();
   //--- Runs every tick independent of Execute — the daily loss limit can
   //--- be breached purely by floating P&L widening, with no click
   //--- involved (see EnforceDailyLossLimit's own comment).
   ExtPanel.EnforceDailyLossLimit();
}

void OnTimer()
{
   ExtPanel.UpdatePriceReadout();
   ExtPanel.RepositionActivePanelLabels();
   //--- Risk-parameter fetch is manual-only — see OnClickSync in
   //--- TradingPanelRiskSync.mqh, wired to the panel's "Sync" button.
   //--- Closed-trade sync (SyncClosedTradesIfDue) is also reachable from
   //--- that same button, but is additionally auto-triggered here shortly
   //--- after any position close (see RunPendingCloseSyncIfDue), so the
   //--- journal/Trade-row data stays current without the trader needing to
   //--- click Sync after every trade.
   ExtPanel.RunPendingCloseSyncIfDue();
   //--- Internally rate-limited to PollingIntervalSeconds (min 10), or
   //--- forced immediately on symbol change (ApplySymbolChange) — see
   //--- RefreshCommissionEstimateIfDue. Purely local (reads trade history,
   //--- no WebRequest).
   ExtPanel.RefreshCommissionEstimateIfDue();
   //--- Internally rate-limited to ~5s — see SelfHealLayoutIfDue (VPS/RDP
   //--- resolution changes can silently disturb the panel's visibility
   //--- state with no MQL5 event to react to).
   ExtPanel.SelfHealLayoutIfDue();
   //--- Internally rate-limited to HEARTBEAT_INTERVAL_SECONDS — see
   //--- EmitHeartbeatIfDue. Purely a Print, no WebRequest.
   ExtPanel.EmitHeartbeatIfDue();
   //--- Sends (or retries) at most one queued closed-position lifecycle
   //--- payload per tick — see FlushPendingTradePostsIfDue.
   ExtPanel.FlushPendingTradePostsIfDue();
}

//--- Fires for every transaction on the account (order placed/modified/
//--- filled, position opened/closed/partially closed, deal added, SL/TP
//--- hit, ...), not just this EA's own trades. See
//--- CheckForPositionCloseAndHandle in TradingPanelTradeReport.mqh: it
//--- filters down to just the deal that actually closes a position, then
//--- (a) sets m_closeSyncPending so OnTimer runs a real closed-trade sync
//--- shortly after, and (b), only when EnableTransactionReporting is on,
//--- builds that position's whole lifecycle from history and queues it for
//--- FlushPendingTradePostsIfDue. No WebRequest directly in this callback
//--- either way (cheap local History*/PositionSelectByTicket calls only) —
//--- a blocking WebRequest here could stall MT5's own trade processing.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   ExtPanel.CheckForPositionCloseAndHandle(trans, request, result);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   ExtPanel.ChartEvent(id, lparam, dparam, sparam);

   //--- Dragging the panel body (see OnBackgroundDragged()) is checked
   //--- ahead of the generic OBJECT_DRAG/OnLineMoved branch below, since
   //--- that branch also fires for this same event and would otherwise
   //--- no-op through a doomed price lookup on a non-price object.
   if(id == CHARTEVENT_OBJECT_DRAG && sparam == ExtPanel.BgLabelName())
   {
      ExtPanel.OnBackgroundDragged();
      return;
   }

   if(id == CHARTEVENT_OBJECT_DRAG || id == CHARTEVENT_OBJECT_CHANGE)
      ExtPanel.OnLineMoved(sparam);
}
