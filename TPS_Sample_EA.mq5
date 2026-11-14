//+------------------------------------------------------------------+
//|                                               TPS_Sample_EA.mq5  |
//|  Sample Expert Advisor: Larry Connors' "Time, Price, Scale-in"   |
//|  (TPS) on an equity index, daily timeframe, long only.           |
//|                                                                  |
//|  Rules (public, from Connors & Alvarez):                         |
//|   - Trend filter: close > SMA(200).                              |
//|   - Entry: RSI(2) below 25 for two consecutive days -> buy the   |
//|     first tranche (10 % of the full position).                   |
//|   - Scale-in: each day the close is below the last entry price,  |
//|     add the next tranche (20 %, 30 %, 40 %; max. 4 tranches).    |
//|   - Exit: RSI(2) above 70 -> close the whole position.           |
//|                                                                  |
//|  Engineering features shown in this sample:                      |
//|   - Decision taken a few minutes before the session close, using |
//|     the live price as today's close (session-aware).             |
//|   - Wilder RSI computed in code (identical to the Python          |
//|     research version, so live trades match the backtest).        |
//|   - Notional-based position sizing with broker volume limits.    |
//|   - State persisted in terminal global variables and rebuilt     |
//|     from open positions after a restart.                         |
//|   - Equity drawdown guard that pauses new entries.               |
//|   - CSV log of every decision and fill for live-vs-backtest      |
//|     reconciliation.                                              |
//|                                                                  |
//|  Educational sample. Not investment advice.                      |
//+------------------------------------------------------------------+
#property copyright "Alberto Jabonero"
#property version   "1.00"
#include <Trade/Trade.mqh>

//--- strategy
input group "Strategy"
input int    InpSMA         = 200;           // Trend filter: SMA period (days)
input double InpRSIIn       = 25;            // Entry: RSI(2) below this, today and yesterday
input double InpRSIOut      = 70;            // Exit: RSI(2) above this
input string InpTranches    = "10,20,30,40"; // Scale-in tranches (% of full position)

//--- sizing and risk
input group "Sizing and risk"
input double InpNotionalPct = 25;            // Full position notional, % of equity
input double InpMaxDDPct    = 8;             // Pause new entries if equity drawdown from peak exceeds this %
input int    InpSlippage    = 20;            // Max deviation (points)

//--- timing
input group "Timing"
input string InpDecision    = "23:45";       // Decision time (server time)
input int    InpBeforeClose = 5;             // If the session ends earlier, decide N minutes before the close
input int    InpWindowMin   = 3;             // Minutes after the decision time in which the EA may act

//--- housekeeping
input group "Housekeeping"
input long   InpMagic       = 900100;        // Magic number
input bool   InpCsvLog      = true;          // Write decisions and fills to MQL5/Files/TPS_<symbol>.csv

CTrade   trade;
double   g_tranches[];
datetime g_lastDecisionDay = 0;
string   g_gvCount, g_gvLast, g_gvPeak;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpSMA < 10 || InpRSIIn <= 0 || InpRSIOut <= InpRSIIn || InpNotionalPct <= 0)
   {
      Print("TPS: invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
   }
   string parts[];
   int k = StringSplit(InpTranches, ',', parts);
   if(k < 1) { Print("TPS: no tranches defined"); return INIT_PARAMETERS_INCORRECT; }
   ArrayResize(g_tranches, k);
   for(int i = 0; i < k; i++) g_tranches[i] = StringToDouble(parts[i]) / 100.0;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);

   g_gvCount = StringFormat("TPS_%s_%I64d_count", _Symbol, InpMagic);
   g_gvLast  = StringFormat("TPS_%s_%I64d_last",  _Symbol, InpMagic);
   g_gvPeak  = StringFormat("TPS_%s_%I64d_peak",  _Symbol, InpMagic);
   if(MQLInfoInteger(MQL_TESTER))
   {
      GlobalVariableDel(g_gvCount); GlobalVariableDel(g_gvLast); GlobalVariableDel(g_gvPeak);
   }
   SyncState();
   PrintFormat("TPS %s ready: open tranches %d", _Symbol, (int)GlobalVariableGet(g_gvCount));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Minutes after midnight (server) at which the daily decision runs |
//+------------------------------------------------------------------+
int DecisionMinutes(const int dow)
{
   int dm = 23 * 60 + 45;
   string p[];
   if(StringSplit(InpDecision, ':', p) == 2)
      dm = (int)StringToInteger(p[0]) * 60 + (int)StringToInteger(p[1]);

   // move the decision earlier if today's trading session ends before it
   datetime from, to; int endMin = -1;
   for(uint i = 0; i < 10; i++)
   {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dow, i, from, to)) break;
      int e = (int)((long)to / 60);
      if(e > endMin) endMin = e;
   }
   if(endMin > 0 && endMin < 24 * 60) dm = MathMin(dm, endMin - InpBeforeClose);
   return dm;
}

//+------------------------------------------------------------------+
//| Open positions of this EA on this symbol                         |
//+------------------------------------------------------------------+
int MyPositions(double &volume, double &lastPrice)
{
   int n = 0; volume = 0; lastPrice = 0; datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
      volume += PositionGetDouble(POSITION_VOLUME);
      datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
      if(pt >= lastTime) { lastTime = pt; lastPrice = PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   return n;
}

//+------------------------------------------------------------------+
//| Keep the persisted state consistent with the real positions      |
//| (e.g. after a terminal restart or moving to another machine).    |
//+------------------------------------------------------------------+
void SyncState()
{
   double vol, lp;
   int n = MyPositions(vol, lp);
   if(n == 0) { GlobalVariableSet(g_gvCount, 0); GlobalVariableSet(g_gvLast, 0); return; }
   if(GlobalVariableGet(g_gvCount) <= 0)
   {
      GlobalVariableSet(g_gvCount, MathMin(n, ArraySize(g_tranches)));
      GlobalVariableSet(g_gvLast, lp);
      PrintFormat("TPS %s: state rebuilt from positions (%d tranches, last entry %.2f)", _Symbol, n, lp);
   }
}

//+------------------------------------------------------------------+
//| Equity drawdown guard: true if new entries are allowed           |
//+------------------------------------------------------------------+
bool DrawdownOK()
{
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double peak = MathMax(GlobalVariableGet(g_gvPeak), eq);
   GlobalVariableSet(g_gvPeak, peak);
   double dd = peak > 0 ? (peak - eq) / peak * 100.0 : 0;
   if(dd > InpMaxDDPct)
   {
      PrintFormat("TPS %s: equity drawdown %.2f %% > %.2f %% -> no new entries", _Symbol, dd, InpMaxDDPct);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Lots for one tranche, from notional exposure                     |
//+------------------------------------------------------------------+
double LotsForTranche(const double weight, const double price)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0 || price <= 0) return 0;

   double notionalPerLot = price / tickSize * tickValue;   // account currency
   double lots = AccountInfoDouble(ACCOUNT_EQUITY) * InpNotionalPct / 100.0 * weight / notionalPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < vmin) return 0;
   return MathMin(lots, vmax);
}

//+------------------------------------------------------------------+
//| Wilder RSI(2): exponential smoothing with alpha = 1/2            |
//+------------------------------------------------------------------+
void RSI2(const double &c[], const int n, double &rToday, double &rYesterday)
{
   double au = 0, ad = 0; bool init = false;
   rToday = rYesterday = 50;
   for(int i = 1; i < n; i++)
   {
      double d = c[i] - c[i - 1], up = MathMax(d, 0), dn = MathMax(-d, 0);
      if(!init) { au = up; ad = dn; init = true; }
      else      { au = 0.5 * up + 0.5 * au; ad = 0.5 * dn + 0.5 * ad; }
      double r = ad > 0 ? 100 - 100 / (1 + au / ad) : 100;
      if(i == n - 2) rYesterday = r;
      if(i == n - 1) rToday = r;
   }
}

//+------------------------------------------------------------------+
void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!trade.PositionClose(t))
         PrintFormat("TPS %s: close failed, ticket %I64u, retcode %u", _Symbol, t, trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| CSV log (decisions and fills)                                    |
//+------------------------------------------------------------------+
void CsvLog(const string event, const double price, const double lots, const string info)
{
   if(!InpCsvLog || MQLInfoInteger(MQL_TESTER)) return;
   string fn = StringFormat("TPS_%s.csv", _Symbol);
   int h = FileOpen(fn, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ';');
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0) FileWrite(h, "time", "symbol", "event", "price", "lots", "info");
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), _Symbol, event,
             DoubleToString(price, _Digits), DoubleToString(lots, 2), info);
   FileClose(h);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &tx, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   if(tx.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(tx.deal)) return;
   if(HistoryDealGetInteger(tx.deal, DEAL_MAGIC) != InpMagic) return;
   if(HistoryDealGetString(tx.deal, DEAL_SYMBOL) != _Symbol) return;
   string side = HistoryDealGetInteger(tx.deal, DEAL_ENTRY) == DEAL_ENTRY_IN ? "FILL_IN" : "FILL_OUT";
   CsvLog(side, HistoryDealGetDouble(tx.deal, DEAL_PRICE), HistoryDealGetDouble(tx.deal, DEAL_VOLUME),
          StringFormat("profit=%.2f", HistoryDealGetDouble(tx.deal, DEAL_PROFIT)));
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime st; TimeToStruct(TimeCurrent(), st);
   if(st.day_of_week == 0 || st.day_of_week == 6) return;

   int nowMin = st.hour * 60 + st.min, dm = DecisionMinutes(st.day_of_week);
   if(nowMin < dm || nowMin > dm + InpWindowMin) return;

   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today == g_lastDecisionDay) return;           // one decision per day

   MqlRates d[]; ArraySetAsSeries(d, false);
   int nd = CopyRates(_Symbol, PERIOD_D1, 0, 400, d); // last bar = today (in progress)
   if(nd < InpSMA + 5) { PrintFormat("TPS %s: not enough daily history (%d bars)", _Symbol, nd); return; }

   double close = SymbolInfoDouble(_Symbol, SYMBOL_BID); // live price used as today's close
   double c[]; ArrayResize(c, nd);
   for(int i = 0; i < nd; i++) c[i] = d[i].close;
   c[nd - 1] = close;

   double sma = 0;
   for(int i = nd - InpSMA; i < nd; i++) sma += c[i];
   sma /= InpSMA;
   double rT, rY; RSI2(c, nd, rT, rY);
   g_lastDecisionDay = today;

   SyncState();
   int    count = (int)GlobalVariableGet(g_gvCount);
   double last  = GlobalVariableGet(g_gvLast);
   bool   ddOK  = DrawdownOK();                     // also updates the equity peak every day
   string info  = StringFormat("SMA=%.2f RSI2=%.1f/%.1f tranches=%d", sma, rT, rY, count);
   CsvLog("DECISION", close, 0, info);

   //--- 1) in a position: exit or scale in
   if(count > 0)
   {
      if(rT > InpRSIOut)
      {
         CloseAll();
         double v, lp;
         if(MyPositions(v, lp) == 0) { GlobalVariableSet(g_gvCount, 0); GlobalVariableSet(g_gvLast, 0); }
         return;                                    // no re-entry on the exit day
      }
      if(count < ArraySize(g_tranches) && close < last)
      {
         double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double lots = LotsForTranche(g_tranches[count], ask);
         if(lots <= 0)
         {
            // tranche too small for the broker's minimum volume: count it so the schedule stays in sync
            GlobalVariableSet(g_gvCount, count + 1); GlobalVariableSet(g_gvLast, close);
            return;
         }
         if(trade.Buy(lots, _Symbol, 0, 0, 0, StringFormat("TPS %d/%d", count + 1, ArraySize(g_tranches))))
         {
            GlobalVariableSet(g_gvCount, count + 1); GlobalVariableSet(g_gvLast, close);
         }
         else PrintFormat("TPS %s: scale-in failed, retcode %u", _Symbol, trade.ResultRetcode());
      }
      return;
   }

   //--- 2) flat: entry
   if(close > sma && rT < InpRSIIn && rY < InpRSIIn && ddOK)
   {
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lots = LotsForTranche(g_tranches[0], ask);
      if(lots <= 0) { PrintFormat("TPS %s: first tranche below minimum volume, no entry", _Symbol); return; }
      if(trade.Buy(lots, _Symbol, 0, 0, 0, StringFormat("TPS 1/%d", ArraySize(g_tranches))))
      {
         GlobalVariableSet(g_gvCount, 1); GlobalVariableSet(g_gvLast, close);
      }
      else PrintFormat("TPS %s: entry failed, retcode %u", _Symbol, trade.ResultRetcode());
   }
}
//+------------------------------------------------------------------+
