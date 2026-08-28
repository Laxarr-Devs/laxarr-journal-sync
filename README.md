# Trading Panel (MT5 Expert Advisor)

A **risk management tool** for MetaTrader 5 — an on-chart order-entry
panel built around risk-based position sizing, account guardrails, and
live SL/TP/Entry chart visualization, rather than an autonomous trading
bot. It supports Market, Limit, Stop, and Stop Limit orders, each with up
to three take-profit levels.

**Platform:** Windows only. MetaTrader 5's MQL5 runtime and MetaEditor are
Windows-native, so this EA requires a Windows installation of the
terminal (a Windows VM/VPS works for Mac or Linux users).

**Trade execution:** Manual only. Every order requires the trader to
click Execute and confirm a popup — nothing is submitted on the trader's
behalf without that explicit action. The one exception is the Max Daily
Loss guardrail: if configured, it will automatically close all open
positions the moment the limit is breached, independent of any click,
since protecting the account against further loss is the entire point of
that guardrail.

## File overview

### `TradingPanel.mq5`
The EA's entry point. Declares the `CTradingPanelDialog` class (member
variables, control declarations, and small inline handlers), wires up
MT5's `OnInit`/`OnDeinit`/`OnTick`/`OnTimer`/`OnTradeTransaction`/
`OnChartEvent` callbacks, and includes the out-of-line method bodies below.
Also holds layout constants for the shared dialog chrome and the four
order-type panels.

### `OrderPanelBase.mqh`
The base class shared by all four order-type panels. Builds the SL/TP1/
TP2/TP3 rows (price, pips, money, risk:reward, and per-TP lot columns, all
editable and spinner-adjustable), keeps those fields in sync with each
other, and draws the corresponding chart visualization: the entry line,
profit/loss shaded zones, and price tags. TP2 and TP3 are hidden by
default — TP1 hosts a button that reveals TP2, and TP2 hosts one that
reveals TP3.

### `MarketExecutionPanel.mqh`
The Market order tab. Uses the live bid/ask as its reference price and is
the only tab currently wired to place real trades, via `CTrade`. Each
enabled take-profit level is submitted as its own independent position,
sharing the same stop loss.

### `LimitOrderPanel.mqh`
The Limit order tab. Adds a "Limit Price" field that seeds the reference
price for SL/TP calculations and the chart visualization.

### `StopOrderPanel.mqh`
The Stop order tab. Adds a "Stop Price" field that seeds the reference
price for SL/TP calculations and the chart visualization.

### `StopLimitOrderPanel.mqh`
The Stop Limit order tab. Adds both "Stop Price" and "Limit Price"
fields; the stop price serves as the reference price.

### `TradingPanelUI.mqh`
Everything about building and reflowing the shared chrome: the full panel
construction (`CreatePanel`), BUY/SELL tab styling, order-type and symbol
dropdown population, the collapse/expand and reflow logic that resizes the
window to match whichever rows are currently visible, the price readout,
and periodic layout self-healing.

### `TradingPanelVolumeRisk.mqh`
The hands-free position-sizing engine. Volume is always computed to match
exactly what the trader's Max Risk % implies for the active panel's
current stop-loss distance (or, in fixed-lot mode, Risk % becomes the
derived readout instead). Also manages the Risk % manual-override lock,
which engages on a manual edit and releases after a trade executes or on
an explicit unlock click.

### `TradingPanelGuardrails.mqh`
Account-wide risk guardrails: a maximum daily loss check (enforced every
tick, independent of the Execute button), a consecutive-loss cooldown, a
pre-Execute blocking check that combines all configured limits, and the
Execute click flow itself — a trade confirmation dialog followed by
guardrail/lock bookkeeping.

### `TradingPanelRiskSync.mqh`
Fetches the trader's configured risk parameters (risk per trade, fixed lot
settings, daily loss limit, max open positions, minimum risk:reward, and
consecutive-loss limit) and renders them as a three-card summary on the
panel. Also cross-checks the account's currency and broker timezone, and
emits a periodic "still alive" heartbeat log line.

### `TradingPanelTradeSync.mqh`
Tracks and reports closed trades. Persists a watermark so only trades
closed since the last sync are sent, back-fills a bounded window of
history on first run, and estimates per-lot commission from the most
recently closed trade for the on-screen cost readout.

### `TradingPanelTradeReport.mqh`
Two related reporting features: building OHLCV candle context around each
closed trade's holding period, and capturing a closed position's full
order/deal lifecycle the moment it closes, queued and retried safely in
the background.

## Key features

- **Four order types** — Market, Limit, Stop, and Stop Limit — sharing one
  consistent SL/TP1/TP2/TP3 interface.
- **Risk-based position sizing** — Volume is derived automatically from
  Max Risk % and the current stop-loss distance, with an optional
  fixed-lot mode.
- **Account guardrails** — maximum daily loss (auto-closes all open
  positions if breached), maximum open positions, consecutive-loss
  cooldown, and minimum risk:reward enforcement.
- **Live chart visualization** — draggable SL/TP/Entry lines, shaded
  profit/loss zones, and price tags that track the viewport.
- **Per-TP lot splitting** — the total position size can be spread across
  up to three take-profit levels, with the split adjustable per level.
