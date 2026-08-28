//+------------------------------------------------------------------+
//|                                         StopLimitOrderPanel.mqh |
//|  Stop Limit order tab. Adds "Stop Price" and "Limit Price"       |
//|  fields; the stop price serves as the reference price for the    |
//|  profit/loss visualization. UI only; not yet wired to place a    |
//|  real pending order.                                             |
//+------------------------------------------------------------------+
#ifndef STOP_LIMIT_ORDER_PANEL_MQH
#define STOP_LIMIT_ORDER_PANEL_MQH

#include "OrderPanelBase.mqh"

class CStopLimitOrderPanel : public COrderPanelBase
{
private:
   CLabel m_lblStopPrice, m_lblLimitPrice;
   CEdit  m_editStopPrice, m_editLimitPrice;

protected:
   virtual void CreateExtraFields(int y) override
   {
      int labelW = 40, editW = 110, pairGap = 20;
      int secondX = ROW_X + labelW + FIELD_GAP + editW + pairGap;

      CreateSimpleRow("StopPrice",  m_lblStopPrice,  m_editStopPrice,  "Stop:",  "0.00000", ROW_X,   labelW, editW, y);
      CreateSimpleRow("LimitPrice", m_lblLimitPrice, m_editLimitPrice, "Limit:", "0.00000", secondX, labelW, editW, y);
   }

   //--- Seed stop/limit prices from market once; never overwrite prices the
   //--- user already set. Offset the limit a few pips past the stop to give
   //--- the fill some slippage tolerance. Re-derive SL/TP1-3 from the stop
   //--- price on every activation, not just the first, so a BUY<->SELL
   //--- switch keeps the lines pointing the correct direction.
   virtual void OnTabActivated() override
   {
      if(StringToDouble(m_editStopPrice.Text()) <= 0.0)
      {
         double bid = SymbolInfoDouble(CurrentSymbol(), SYMBOL_BID);
         double ask = SymbolInfoDouble(CurrentSymbol(), SYMBOL_ASK);
         double stopPrice = (m_activeTab == TAB_BUY) ? ask : bid;
         double slippage = 5.0 * 10.0 * SymbolPoint(); // 5 pips
         double limitPrice = (m_activeTab == TAB_BUY) ? (stopPrice + slippage) : (stopPrice - slippage);

         m_editStopPrice.Text(DoubleToString(stopPrice, SymbolDigits()));
         m_editLimitPrice.Text(DoubleToString(limitPrice, SymbolDigits()));
      }
      ApplyDefaultRiskPrices(GetReferencePrice());
      SyncAllRowsFromPrice();
      RefreshVisuals();
   }

public:
   virtual double GetReferencePrice() override
   {
      return StringToDouble(m_editStopPrice.Text());
   }

   virtual void ResetReferenceFields() override
   {
      m_editStopPrice.Text("0.00000");
      m_editLimitPrice.Text("0.00000");
   }
};

#endif // STOP_LIMIT_ORDER_PANEL_MQH
