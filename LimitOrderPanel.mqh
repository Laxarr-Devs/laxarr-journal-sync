//+------------------------------------------------------------------+
//|                                             LimitOrderPanel.mqh |
//|  Limit order tab. Adds a "Limit Price" field used as the         |
//|  reference price for the profit/loss visualization. UI only;     |
//|  not yet wired to place a real pending order.                    |
//+------------------------------------------------------------------+
#ifndef LIMIT_ORDER_PANEL_MQH
#define LIMIT_ORDER_PANEL_MQH

#include "OrderPanelBase.mqh"

class CLimitOrderPanel : public COrderPanelBase
{
private:
   CLabel m_lblPrice;
   CEdit  m_editPrice;

protected:
   virtual void CreateExtraFields(int y) override
   {
      CreateSimpleRow("LimitPrice", m_lblPrice, m_editPrice, "Limit:", "0.00000", ROW_X, 45, 150, y);
   }

   //--- Seed the limit price from market once; never overwrite a price the
   //--- user already set. Re-derive SL/TP1-3 from the reference price on
   //--- every activation, not just the first, so a BUY<->SELL switch keeps
   //--- the lines pointing the correct direction.
   virtual void OnTabActivated() override
   {
      if(StringToDouble(m_editPrice.Text()) <= 0.0)
      {
         double bid = SymbolInfoDouble(CurrentSymbol(), SYMBOL_BID);
         double ask = SymbolInfoDouble(CurrentSymbol(), SYMBOL_ASK);
         m_editPrice.Text(DoubleToString((m_activeTab == TAB_BUY) ? ask : bid, SymbolDigits()));
      }
      ApplyDefaultRiskPrices(GetReferencePrice());
      SyncAllRowsFromPrice();
      RefreshVisuals();
   }

public:
   virtual double GetReferencePrice() override
   {
      return StringToDouble(m_editPrice.Text());
   }

   virtual void ResetReferenceFields() override { m_editPrice.Text("0.00000"); }
};

#endif // LIMIT_ORDER_PANEL_MQH
