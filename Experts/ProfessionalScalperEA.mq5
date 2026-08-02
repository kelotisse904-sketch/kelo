//+------------------------------------------------------------------+
//| ProfessionalScalperEA.mq5                                        |
//| Aggressive, professional scalper EA for MT5                      |
//| Designed for EURUSD and XAUUSD on M1/M5                          |
//| Features:                                                         
//| - Multi-symbol support (per-instance symbol check)               
//| - Indicator handles (EMA, RSI, ATR)                              
//| - Per-symbol presets & profiles                                  
//| - Robust order and error handling with retries                   
//| - Spread, slippage and trading session filters                   
//| - News filter stub (user to integrate news source)               
//| - Detailed logging and position management (trailing/break-even)
//| - Risk-based or fixed lot sizing                                 
//| - Extensive input parameters for optimization & forward testing  
//| NOTE: Backtest extensively on demo accounts. Trading carries risk.
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include <File\File.mqh>
#include <Arrays\ArrayObj.mqh>

//===================================================================
// Inputs: strategy configuration
//===================================================================
input string  AllowedSymbols    = "EURUSD,XAUUSD"; // comma-separated
input ENUM_TIMEFRAMES WorkTF    = PERIOD_M1;        // Operating timeframe

// Risk & money management
input bool    UseFixedLots      = true;             // Fixed lots or risk-based
input double  FixedLots         = 0.01;             // Fixed lots size
input double  RiskPercent       = 1.0;              // Risk % per trade if risk-based
input double  AccountRiskMax    = 10.0;             // Max total % risk open

// Entry detection
input int     FastEMA           = 5;
input int     SlowEMA           = 20;
input int     RSIperiod         = 14;
input int     RSI_overbought    = 70;
input int     RSI_oversold      = 30;

// Exit & stops
input int     ATRperiod         = 14;
input double  ATR_SL_Mult       = 0.7;
input double  TP_SL_Ratio       = 1.0;

// Execution constraints
input double  MaxSpreadPoints   = 25.0;            // max spread allowed in points (adjust per symbol)
input int     MaxSlippage       = 10;              // deviation
input uint    MagicNumber       = 20260802;
input int     MaxPositions      = 3;               // max positions per symbol

// Management
input bool    UseTrailingStop   = true;
input int     TrailingStartPts  = 10;
input int     TrailingStepPts   = 5;
input bool    UseBreakEven      = true;
input int     BreakEvenPts      = 6;

// Operational
input bool    TradeOnFriday     = false;           // avoid trading on Fridays
input bool    TradeAtNews       = false;           // skip trading at news (stub)
input string  LogFileName       = "ProfessionalScalper.log";

// Per-symbol presets (format: SYMBOL:spreadMultiplier:atrMult:tpRatio:fixedLots)
input string  SymbolPresets     = "EURUSD:1.0:0.7:1.0:0.01;XAUUSD:1.5:1.0:1.2:0.02";

//===================================================================
// Global objects and handles
//===================================================================
CTrade trade;
int handleEMAFast = INVALID_HANDLE;
int handleEMASlow = INVALID_HANDLE;
int handleRSI     = INVALID_HANDLE;
int handleATR     = INVALID_HANDLE;

// Preset structure
struct SymbolPreset
{
   string symbol;
   double spreadMultiplier; // multiply base MaxSpreadPoints
   double atrMultiplier;    // override multiplier
   double tpRatio;
   double fixedLots;
};

CArrayObj presets;

// Logging file handle
int handleLog = INVALID_HANDLE;

//===================================================================
// Utility functions
//===================================================================
string Trim(string s)
{
   while(StringLen(s) && (StringGetCharacter(s,0)==32 || StringGetCharacter(s,0)==9)) s = StringSubstr(s,1);
   while(StringLen(s) && (StringGetCharacter(s,StringLen(s)-1)==32 || StringGetCharacter(s,StringLen(s)-1)==9)) s = StringSubstr(s,0,StringLen(s)-1);
   return(s);
}

void Log(string s)
{
   string time = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string line = time + " - " + s + "\r\n";
   Print(line);
   // append to log file
   int file_handle = FileOpen(LogFileName, FILE_WRITE|FILE_READ|FILE_ANSI|FILE_SHARE_WRITE);
   if(file_handle != INVALID_HANDLE)
   {
      FileSeek(file_handle, 0, SEEK_END);
      FileWriteString(file_handle, line);
      FileClose(file_handle);
   }
}

// parse comma-separated allowed symbols into array
int SplitString(string s, string sep, string &arr[])
{
   return(StringSplit(s, sep[0], arr));
}

// parse presets string
void LoadPresets()
{
   presets.Clear();
   string entries[];
   int cnt = StringSplit(SymbolPresets, ';', entries);
   for(int i = 0; i < cnt; i++)
   {
      string e = Trim(entries[i]);
      if(StringLen(e) == 0) continue;
      string parts[];
      int p = StringSplit(e, ':', parts);
      SymbolPreset *sp = new SymbolPreset;
      sp.symbol = (p > 0) ? Trim(parts[0]) : "";
      sp.spreadMultiplier = (p > 1) ? StrToDouble(parts[1]) : 1.0;
      sp.atrMultiplier    = (p > 2) ? StrToDouble(parts[2]) : ATR_SL_Mult;
      sp.tpRatio          = (p > 3) ? StrToDouble(parts[3]) : TP_SL_Ratio;
      sp.fixedLots        = (p > 4) ? StrToDouble(parts[4]) : FixedLots;
      presets.Add(sp);
   }
}

SymbolPreset* GetPreset(string symbol)
{
   for(int i = 0; i < presets.Total(); i++)
   {
      SymbolPreset *sp = (SymbolPreset*)presets.At(i);
      if(sp != NULL && StringCompare(sp.symbol, symbol) == 0) return sp;
   }
   return NULL;
}

bool IsSymbolAllowed(string symbol)
{
   string arr[];
   int cnt = StringSplit(AllowedSymbols, ',', arr);
   for(int i=0;i<cnt;i++)
   {
      if(Trim(arr[i])==symbol) return true;
   }
   return false;
}

//===================================================================
// Indicator / data helpers
//===================================================================
int CreateIndicatorHandles(string sym, ENUM_TIMEFRAMES tf)
{
   // release if existing
   if(handleEMAFast != INVALID_HANDLE) IndicatorRelease(handleEMAFast);
   if(handleEMASlow != INVALID_HANDLE) IndicatorRelease(handleEMASlow);
   if(handleRSI     != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR     != INVALID_HANDLE) IndicatorRelease(handleATR);

   handleEMAFast = iMA(sym, tf, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow = iMA(sym, tf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(sym, tf, RSIperiod, PRICE_CLOSE);
   handleATR     = iATR(sym, tf, ATRperiod);

   if(handleEMAFast==INVALID_HANDLE || handleEMASlow==INVALID_HANDLE || handleRSI==INVALID_HANDLE || handleATR==INVALID_HANDLE)
   {
      Log("Indicator handle creation failed - check parameters and symbols");
      return(-1);
   }
   return(0);
}

// copy buffer with safety
bool CopyIndicator(int handle, int index, int count, double &buf[])
{
   ArrayResize(buf, count);
   int copied = CopyBuffer(handle, 0, index, count, buf);
   if(copied <= 0) return false;
   return true;
}

//===================================================================
// Order management helpers
//===================================================================
ulong RetryTrade(bool isBuy, double lots, double price, double sl, double tp, int maxRetry=3, int sleepMs=500)
{
   ulong ticket = 0;
   for(int attempt = 0; attempt < maxRetry; attempt++)
   {
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviation(MaxSlippage);
      bool ok;
      if(isBuy)
         ok = trade.Buy(lots, Symbol(), price, sl, tp);
      else
         ok = trade.Sell(lots, Symbol(), price, sl, tp);

      if(ok)
      {
         ticket = trade.ResultOrder();
         Log(StringFormat("Trade placed: %s %f lots ticket=%I64u", (isBuy?"BUY":"SELL"), lots, ticket));
         return ticket;
      }
      else
      {
         string err = trade.ResultRetcodeDescription();
         Log(StringFormat("Trade attempt %d failed: %s", attempt+1, err));
         Sleep(sleepMs);
      }
   }
   return 0;
}

// calculate lots
double CalculateLots(string symbol, double stopPoints, SymbolPreset *preset)
{
   if(stopPoints <= 0) return(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN));
   if(UseFixedLots) return(preset != NULL ? preset.fixedLots : FixedLots);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tick_value <= 0 || tick_size <= 0) tick_value = 0.1;

   double value_per_point = tick_value / (tick_size / point);
   if(value_per_point <= 0) value_per_point = tick_value;
   double lots = riskMoney / (stopPoints * value_per_point);
   double minlot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxlot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   if(lots < minlot) lots = minlot;
   if(lots > maxlot) lots = maxlot;
   double normalized = MathFloor(lots/step)*step;
   if(normalized < minlot) normalized = minlot;
   return NormalizeDouble(normalized, 2);
}

int CountEAPositions(string symbol)
{
   int cnt = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if((ulong)magic == MagicNumber) cnt++;
   }
   return cnt;
}

//===================================================================
// Trading logic
//===================================================================
void EvaluateAndTrade()
{
   string symbol = Symbol();
   if(!IsSymbolAllowed(symbol)) return;
   if(Period() != WorkTF) return;

   // session filter: skip Fridays end of day if configured
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(!TradeOnFriday && dt.day_of_week == 5) return; // Friday

   // spread filter
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0 || ask <= 0 || bid <= 0) return;
   double spreadPoints = (ask - bid) / point;

   SymbolPreset *preset = GetPreset(symbol);
   double spreadMax = MaxSpreadPoints * (preset != NULL ? preset.spreadMultiplier : 1.0);
   if(spreadPoints > spreadMax) return;

   // indicator copy
   double emabuf[3], emaslowbuf[3], rsibuf[2], atrbuf[2];
   if(!CopyIndicator(handleEMAFast, 0, 3, emabuf)) return;
   if(!CopyIndicator(handleEMASlow, 0, 3, emaslowbuf)) return;
   if(!CopyIndicator(handleRSI, 0, 2, rsibuf)) return;
   if(!CopyIndicator(handleATR, 0, 2, atrbuf)) return;

   double emaFast = emabuf[0], emaFastPrev = emabuf[1];
   double emaSlow = emaslowbuf[0], emaSlowPrev = emaslowbuf[1];
   double rsi = rsibuf[0];
   double atr = atrbuf[0]; if(atr <= 0) atr = point * 10;

   bool bullish = (emaFastPrev <= emaSlowPrev) && (emaFast > emaSlow);
   bool bearish = (emaFastPrev >= emaSlowPrev) && (emaFast < emaSlow);

   double atrMult = (preset != NULL ? preset.atrMultiplier : ATR_SL_Mult);
   double sl_points = (atr / point) * atrMult; if(sl_points < 10) sl_points = 10;
   double tp_points = sl_points * (preset != NULL ? preset.tpRatio : TP_SL_Ratio);

   // position limit
   int current = CountEAPositions(symbol);
   if(current >= MaxPositions) return;

   // risk lot
   double lots;

   // Long
   if(bullish && rsi < RSI_overbought && !IsTradingBlockedByNews())
   {
      lots = CalculateLots(symbol, sl_points, preset);
      double sl = NormalizeDouble(bid - sl_points * point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      double tp = NormalizeDouble(bid + tp_points * point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      RetryTrade(true, lots, 0, sl, tp, 3);
   }

   // Short
   if(bearish && rsi > RSI_oversold && !IsTradingBlockedByNews())
   {
      lots = CalculateLots(symbol, sl_points, preset);
      double sl = NormalizeDouble(ask + sl_points * point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      double tp = NormalizeDouble(ask - tp_points * point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      RetryTrade(false, lots, 0, sl, tp, 3);
   }

   // Manage positions
   ManagePositions(symbol, point);
}

// stub for news filter - user to implement actual news source check
bool IsTradingBlockedByNews()
{
   if(!TradeAtNews) return false;
   // implement news feed check (HTTP or file based) and return true if high impact news upcoming
   return false;
}

void ManagePositions(string symbol, double point)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      long pmagic = PositionGetInteger(POSITION_MAGIC);
      if((ulong)pmagic != MagicNumber) continue;

      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur_price = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
      double cur_sl = PositionGetDouble(POSITION_SL);
      double cur_tp = PositionGetDouble(POSITION_TP);
      double profit_points = (ptype == POSITION_TYPE_BUY) ? (cur_price - open_price) / point : (open_price - cur_price) / point;

      // Break-even
      if(UseBreakEven && profit_points >= BreakEvenPts)
      {
         double new_sl = (ptype == POSITION_TYPE_BUY) ? NormalizeDouble(open_price + 1*point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) : NormalizeDouble(open_price - 1*point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
         if((ptype == POSITION_TYPE_BUY && new_sl > cur_sl) || (ptype == POSITION_TYPE_SELL && (new_sl < cur_sl || cur_sl==0.0)))
         {
            trade.PositionModify(ticket, new_sl, cur_tp);
         }
      }

      // Trailing
      if(UseTrailingStop && profit_points >= TrailingStartPts)
      {
         double desired_sl = (ptype == POSITION_TYPE_BUY) ? NormalizeDouble(cur_price - TrailingStepPts*point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) : NormalizeDouble(cur_price + TrailingStepPts*point, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
         if((ptype == POSITION_TYPE_BUY && desired_sl > cur_sl) || (ptype == POSITION_TYPE_SELL && (desired_sl < cur_sl || cur_sl==0.0)))
         {
            trade.PositionModify(ticket, desired_sl, cur_tp);
         }
      }
   }
}

//===================================================================
// MT5 Events
//===================================================================
int OnInit()
{
   Log("Initializing ProfessionalScalperEA...");
   LoadPresets();
   string sym = Symbol();
   if(!IsSymbolAllowed(sym))
   {
      Log(StringFormat("Symbol %s is not allowed. EA will not trade on this chart.", sym));
   }
   if(CreateIndicatorHandles(sym, Period()) < 0) return(INIT_FAILED);
   Log("Initialization complete.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(handleEMAFast != INVALID_HANDLE) IndicatorRelease(handleEMAFast);
   if(handleEMASlow != INVALID_HANDLE) IndicatorRelease(handleEMASlow);
   if(handleRSI     != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR     != INVALID_HANDLE) IndicatorRelease(handleATR);
   // free presets
   for(int i=presets.Total()-1;i>=0;i--) delete (SymbolPreset*)presets.At(i);
   presets.Clear();
   Log("EA deinitialized.");
}

void OnTick()
{
   EvaluateAndTrade();
}

//===================================================================
// End of file
//===================================================================
