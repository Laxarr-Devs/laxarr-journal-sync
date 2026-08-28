//+------------------------------------------------------------------+
//|                                        MarketExecutionPanel.mqh |
//|  Market order tab. Uses live bid/ask as the reference price and  |
//|  is the only tab wired to place real trades via CTrade.          |
//+------------------------------------------------------------------+
#ifndef MARKET_EXECUTION_PANEL_MQH
#define MARKET_EXECUTION_PANEL_MQH

#include "OrderPanelBase.mqh"
#include <Trade\Trade.mqh>

class CMarketExecutionPanel : public COrderPanelBase
{
private:
   CTrade *m_trade;
   CEdit  *m_commentEdit; // Comment field, shared and owned by the main dialog

   void CalculateRiskPrices()
   {
      double bid = SymbolInfoDouble(CurrentSymbol(), SYMBOL_BID);
      double ask = SymbolInfoDouble(CurrentSymbol(), SYMBOL_ASK);
      double slDist = RiskBasedSLDistance();

      if(m_activeTab == TAB_BUY)
      {
         m_rowPrice[ROW_SL].Text(DoubleToString(bid - slDist, SymbolDigits()));
         m_rowPrice[ROW_TP1].Text(DoubleToString(ask + slDist * 1.5, SymbolDigits()));
         m_rowPrice[ROW_TP2].Text(DoubleToString(ask + slDist * 2.0, SymbolDigits()));
         m_rowPrice[ROW_TP3].Text(DoubleToString(ask + slDist * 2.5, SymbolDigits()));
      }
      else
      {
         m_rowPrice[ROW_SL].Text(DoubleToString(ask + slDist, SymbolDigits()));
         m_rowPrice[ROW_TP1].Text(DoubleToString(bid - slDist * 1.5, SymbolDigits()));
         m_rowPrice[ROW_TP2].Text(DoubleToString(bid - slDist * 2.0, SymbolDigits()));
         m_rowPrice[ROW_TP3].Text(DoubleToString(bid - slDist * 2.5, SymbolDigits()));
      }
   }

protected:
   virtual void OnTabActivated() override
   {
      CalculateRiskPrices();
      SyncAllRowsFromPrice();
      RefreshVisuals();
   }

public:
   CMarketExecutionPanel() : m_trade(NULL), m_commentEdit(NULL) {}

   void BindTrade(CTrade *tradeObj, CEdit *commentEdit) { m_trade = tradeObj; m_commentEdit = commentEdit; }

   virtual double GetReferencePrice() override
   {
      double bid = SymbolInfoDouble(CurrentSymbol(), SYMBOL_BID);
      double ask = SymbolInfoDouble(CurrentSymbol(), SYMBOL_ASK);
      return (m_activeTab == TAB_BUY) ? ask : bid;
   }

   virtual bool UsesLiveReferencePrice() override { return true; }

   virtual void OnExecute() override
   {
      if(m_state == STATE_IDLE || m_trade == NULL) return;

      ENUM_ORDER_TYPE orderType = (m_state == STATE_STAGED_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double totalLot = Lots();
      double sl = SL();
      string comment = (m_commentEdit != NULL) ? m_commentEdit.Text() : "EA Trade";

      double tpValue[3]   = {TP1(), TP2(), TP3()};
      double tpLot[3]     = {LotOf(ROW_TP1), LotOf(ROW_TP2), LotOf(ROW_TP3)};
      bool   tpEnabled[3] = {true, IsRowEnabled(ROW_TP2), IsRowEnabled(ROW_TP3)};

      double volumeMin = SymbolInfoDouble(CurrentSymbol(), SYMBOL_VOLUME_MIN);
      if(totalLot <= 0) return;

      for(int i = 0; i < 3; i++)
      {
         if(!tpEnabled[i]) continue;
         double lot = NormalizeDouble(tpLot[i], 8);
         if(lot < volumeMin) continue; // skip this level only; its share rounded below the broker's minimum lot
         if(orderType == ORDER_TYPE_BUY)
            m_trade.Buy(lot, CurrentSymbol(), 0.0, sl, tpValue[i], comment);
         else
            m_trade.Sell(lot, CurrentSymbol(), 0.0, sl, tpValue[i], comment);
      }
   }
};

#endif // MARKET_EXECUTION_PANEL_MQH
