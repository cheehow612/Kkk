//+------------------------------------------------------------------+
//|                                                  XAU_Scalper.mq5 |
//|  XAUUSD 高频剥头皮 EA：M1 均值回归为主 + 可开关动量突破          |
//|  无马丁 / 无加倍补仓 / 无网格。每笔必带硬止损与止盈。            |
//+------------------------------------------------------------------+
#property copyright   "XAU Scalper"
#property version     "1.00"
#property description "XAUUSD M1 均值回归剥头皮 + 可选动量突破；分数凯利仓位；多层硬性风控"

#include <Trade\Trade.mqh>

//--- 趋势过滤模式
enum ENUM_TREND_MODE
  {
   TREND_OFF         = 0,  // 关闭趋势过滤
   TREND_FOLLOW_ONLY = 1,  // 单边时只做顺势回调
   TREND_PAUSE_MR    = 2   // 单边时暂停全部均值回归单
  };

//+------------------------------------------------------------------+
//| 输入参数                                                         |
//| 约定：所有“价格距离”参数的单位都是【报价货币价格】（美元）。     |
//| 例如 0.30 = 黄金价格变动 0.30 美元，2 位报价商 = 30 点，          |
//| 3 位报价商 = 300 点。EA 内部用 SYMBOL_POINT 自动换算。            |
//+------------------------------------------------------------------+
input group "===== 1. 基本设置 ====="
input long            InpMagic            = 20261110;     // MagicNumber（多实例时每个实例不同）
input string          InpComment          = "XS";         // 订单注释前缀
input ENUM_TIMEFRAMES InpSignalTF         = PERIOD_M1;    // 信号周期
input bool            InpVerbose          = false;        // 输出被过滤原因等详细日志

input group "===== 2. 均值回归（主逻辑） ====="
input bool            InpMR_Enable        = true;         // 启用均值回归
input int             InpEmaPeriod        = 20;           // 均值 EMA 周期
input int             InpAtrPeriod        = 14;           // ATR 周期
input double          InpMR_DevK          = 1.8;          // 偏离阈值 k（EMA ± k×ATR）
input double          InpMR_MinRoomATR    = 0.3;          // 回拉后距均值的最小剩余空间（×ATR）
input bool            InpMR_UseRSI        = true;         // 用 RSI 确认超买超卖
input int             InpRsiPeriod        = 7;            // RSI 周期
input double          InpMR_RsiLevel      = 30.0;         // RSI 超卖线（超买线 = 100 − 此值）
input double          InpMR_MaxVolRatio   = 2.5;          // 波动比(快ATR/慢ATR)高于此值暂停均值回归，0=不限
input double          InpMR_SL_ATR        = 1.8;          // 止损 = k×ATR
input double          InpMR_TP_ATR        = 1.5;          // 止盈上限 = k×ATR
input bool            InpMR_TPToMean      = true;         // 止盈优先取“回到 EMA”的距离

input group "===== 3. 动量突破（高波动时段，可开关） ====="
input bool            InpMO_Enable        = false;        // 启用动量突破
input int             InpMO_Lookback      = 20;           // 突破通道回看 K 线数
input double          InpMO_BodyATR       = 0.8;          // 突破 K 线实体 ≥ k×ATR
input double          InpMO_MinVolRatio   = 1.3;          // 波动比 ≥ 此值才允许突破单
input int             InpAtrSlowPeriod    = 100;          // 慢 ATR 周期（波动比分母）
input double          InpMO_SL_ATR        = 1.5;          // 突破单止损 = k×ATR
input double          InpMO_TP_ATR        = 2.0;          // 突破单止盈 = k×ATR

input group "===== 4. 趋势过滤（M5 / M15） ====="
input ENUM_TREND_MODE InpTrendMode        = TREND_FOLLOW_ONLY; // 趋势过滤模式
input ENUM_TIMEFRAMES InpTrendTF1         = PERIOD_M5;    // 趋势周期 1
input ENUM_TIMEFRAMES InpTrendTF2         = PERIOD_M15;   // 趋势周期 2
input int             InpTrendFast        = 20;           // 趋势快 EMA
input int             InpTrendSlow        = 50;           // 趋势慢 EMA
input int             InpTrendAdxPeriod   = 14;           // ADX 周期（周期 2 上）
input double          InpTrendADX         = 25.0;         // ADX ≥ 此值判定为单边

input group "===== 5. 执行过滤 ====="
input double          InpMaxSpread        = 0.35;         // 最大点差（美元价格）
input double          InpDeviation        = 0.20;         // 允许滑点 Deviation（美元价格）
input double          InpSlipWarn         = 0.10;         // 成交价不利偏离超过此值记警告（美元价格）
input int             InpMinSecBetween    = 20;           // 两次开仓最小间隔秒数
input int             InpSignalValidSec   = 10;           // 信号有效秒数（等待点差恢复）
input int             InpMaxRetries       = 3;            // 重新报价/繁忙时最大重试次数
input int             InpRetryDelayMs     = 250;          // 重试间隔毫秒

input group "===== 6. 交易时段（服务器时间 HH:MM） ====="
input bool            InpAsiaOn           = true;         // 亚盘开关
input string          InpAsiaStart        = "03:00";      // 亚盘开始
input string          InpAsiaEnd          = "08:30";      // 亚盘结束
input bool            InpEuroOn           = true;         // 欧盘开关
input string          InpEuroStart        = "10:15";      // 欧盘开始（避开伦敦开盘前 15 分钟）
input string          InpEuroEnd          = "15:15";      // 欧盘结束（避开美盘数据时段）
input bool            InpUSOn             = true;         // 美盘开关
input string          InpUSStart          = "16:45";      // 美盘开始（避开纽约开盘前 15 分钟）
input string          InpUSEnd            = "21:30";      // 美盘结束（避开收盘/结算）
input int             InpFridayStopHour   = 21;           // 周五此小时后不再开仓（服务器时间）

input group "===== 7. 新闻过滤（MT5 经济日历） ====="
input bool            InpNewsEnable       = true;         // 启用新闻过滤
input string          InpNewsCurrency     = "USD";        // 关注货币
input int             InpNewsBeforeMin    = 15;           // 数据前 N 分钟停止开仓
input int             InpNewsAfterMin     = 15;           // 数据后 N 分钟停止开仓
input string          InpNewsKeywords     = "";           // 关键词(逗号分隔)，空=全部高影响事件
input bool            InpNewsClosePos     = false;        // 进入新闻窗口时平掉本 EA 持仓
input string          InpNewsFile         = "XAU_Scalper_news.csv"; // 回测用新闻文件（公共文件夹）
input int             InpNewsExportDays   = 0;            // >0：实盘启动时导出过去 N 天新闻到上述文件

input group "===== 8. 仓位（分数凯利） ====="
input double          InpKellyFraction    = 0.25;         // 凯利系数（0.25–0.5）
input int             InpKellyLookback    = 100;          // 滚动统计最近 N 笔
input int             InpKellyMinTrades   = 30;           // 样本少于此数用固定手数
input double          InpFixedLot         = 0.01;         // 固定手数（样本不足 / 凯利≤0 时）
input double          InpMaxRiskPct       = 0.5;          // 单笔最大风险（净值 %，硬上限）
input double          InpCommissionPerLot = 0.0;          // 每手往返手续费（账户货币，计入风险）
input int             InpHistDays         = 30;           // 启动时回读历史成交的天数

input group "===== 9. 止损 / 止盈 / 持仓管理 ====="
input double          InpMinSL            = 1.00;         // 止损最小距离（美元价格）
input double          InpMinTP            = 0.80;         // 止盈最小距离（美元价格）
input bool            InpUseBE            = true;         // 启用保本
input double          InpBE_TrigATR       = 0.8;          // 浮盈 ≥ k×ATR 时保本
input double          InpBE_Offset        = 0.05;         // 保本偏移（美元价格）
input bool            InpUseTrail         = false;        // 启用移动止损
input double          InpTrail_StartATR   = 1.0;          // 浮盈 ≥ k×ATR 开始移动
input double          InpTrail_DistATR    = 0.8;          // 移动止损距离 = k×ATR
input double          InpTrailStep        = 0.05;         // 止损最小改动步长（美元价格）
input int             InpMaxHoldSec       = 600;          // 最长持仓秒数（0=不限）

input group "===== 10. 账户级硬性风控 ====="
input double          InpDailyLossPct     = 3.0;          // 当日亏损达 % 后当天停止
input int             InpMaxConsecLoss    = 4;            // 连续亏损 N 笔后暂停（0=关闭）
input int             InpPauseMinutes     = 30;           // 暂停 M 分钟
input int             InpMaxPositions     = 2;            // 最大同时持仓数
input double          InpMaxTotalLots     = 1.0;          // 最大总手数
input double          InpMaxEquityDD      = 10.0;         // 净值回撤 % 触发总开关（全平并停止）
input double          InpMinMarginLevel   = 300.0;        // 保证金水平低于 % 禁止开新仓
input bool            InpResetKillSwitch  = false;        // 总开关触发后：设为 true 重启一次以解除

input group "===== 11. 日志 / 优化 ====="
input bool            InpCsvLog           = true;         // 输出 CSV 交易日志
input int             InpOptMinTrades     = 200;          // OnTester：交易数少于此值返回 0

//+------------------------------------------------------------------+
//| 全局变量                                                         |
//+------------------------------------------------------------------+
CTrade   g_trade;

//--- 指标句柄
int      g_hEma = INVALID_HANDLE, g_hAtr = INVALID_HANDLE, g_hAtrSlow = INVALID_HANDLE, g_hRsi = INVALID_HANDLE;
int      g_hT1Fast = INVALID_HANDLE, g_hT1Slow = INVALID_HANDLE;
int      g_hT2Fast = INVALID_HANDLE, g_hT2Slow = INVALID_HANDLE, g_hAdx = INVALID_HANDLE;

//--- 品种属性
double   g_volMin, g_volMax, g_volStep;
int      g_volDigits;
bool     g_hedging;
bool     g_isTester, g_isOptim;

//--- 时段（分钟）
int      g_asiaS, g_asiaE, g_euroS, g_euroE, g_usS, g_usE;

//--- 信号状态
datetime g_lastBarTime   = 0;
int      g_sigDir        = 0;      // 待执行信号方向 +1/-1
string   g_sigReason     = "";
bool     g_sigIsMO       = false;
datetime g_sigExpire     = 0;
datetime g_lastEntryTime = 0;
string   g_lastBlockMsg  = "";

//--- 风控状态
bool     g_halted        = false;  // 总开关已触发
bool     g_dayStopped    = false;  // 当日亏损停止
int      g_dayKey        = -1;
double   g_dayStartBal   = 0.0;
double   g_peakEquity    = 0.0;
datetime g_pauseUntil    = 0;
int      g_consecLoss    = 0;
double   g_hist[];                 // 最近 N 笔净盈亏
string   g_gvPeak, g_gvHalt;

//--- 新闻
datetime g_news[];
datetime g_newsLastRefresh = 0;
bool     g_newsLoaded      = false;

//--- 其它
int      g_csv           = INVALID_HANDLE;
bool     g_wasConnected  = true;

//+------------------------------------------------------------------+
//| 工具函数                                                         |
//+------------------------------------------------------------------+
double NormPrice(const double p) { return NormalizeDouble(p, _Digits); }

//--- 读取指标缓冲区单个值
bool Buf(const int handle, const int buffer, const int shift, double &v)
  {
   double a[1];
   if(CopyBuffer(handle, buffer, shift, 1, a) != 1)
      return false;
   v = a[0];
   return (v != EMPTY_VALUE && MathIsValidNumber(v));
  }

//--- 手数向下取整到步长
double FloorLots(const double lots)
  {
   if(g_volStep <= 0.0)
      return 0.0;
   double l = MathFloor(lots / g_volStep + 1e-9) * g_volStep;
   if(l > g_volMax)
      l = g_volMax;
   return NormalizeDouble(l, g_volDigits);
  }

//--- 解析 "HH:MM"
bool ParseHM(const string s, int &mins)
  {
   string p[];
   if(StringSplit(s, ':', p) != 2)
      return false;
   int h = (int)StringToInteger(p[0]);
   int m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 24 || m < 0 || m > 59)
      return false;
   mins = h * 60 + m;
   return true;
  }

bool InWindow(const int now, const int s, const int e)
  {
   if(s == e)
      return false;
   if(s < e)
      return (now >= s && now < e);
   return (now >= s || now < e);   // 跨午夜
  }

//--- 最小止损距离（STOPS_LEVEL 与 FREEZE_LEVEL 取大者），价格单位
double StopsMinDist()
  {
   long sl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long fl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(sl, fl) * _Point;
  }

//--- 统计本 EA 持仓
int CountOwn(double &lots)
  {
   int n = 0;
   lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      n++;
      lots += PositionGetDouble(POSITION_VOLUME);
     }
   return n;
  }

//--- 是否属于可重试的返回码（重新报价 / 价格变化 / 繁忙 / 断线）
bool IsRetryable(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
           rc == TRADE_RETCODE_LOCKED || rc == TRADE_RETCODE_CONNECTION);
  }

bool IsDone(const uint rc)
  {
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
  }

//+------------------------------------------------------------------+
//| CSV 日志                                                         |
//+------------------------------------------------------------------+
void CsvOpen()
  {
   if(!InpCsvLog || g_isOptim)
      return;
   string name = StringFormat("XAU_Scalper_%I64d_%s.csv", InpMagic, _Symbol);
   g_csv = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(g_csv == INVALID_HANDLE)
     {
      Print("CSV 日志打开失败，错误 ", GetLastError());
      return;
     }
   if(FileSize(g_csv) == 0)
      FileWrite(g_csv, "time", "event", "position", "dir", "lots", "req_price", "fill_price",
                "slippage", "spread", "sl", "tp", "risk_money", "risk_pct", "kelly_f", "atr",
                "reason", "net_profit", "hold_sec", "exit_reason");
   FileSeek(g_csv, 0, SEEK_END);
  }

void CsvRow(const string event, const ulong pos, const string dir, const double lots,
            const double req, const double fill, const double slip, const double spread,
            const double sl, const double tp, const double riskMoney, const double riskPct,
            const double kellyF, const double atr, const string reason,
            const double net, const long holdSec, const string exitReason)
  {
   if(g_csv == INVALID_HANDLE)
      return;
   FileWrite(g_csv,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), event, IntegerToString((long)pos), dir,
             DoubleToString(lots, g_volDigits), DoubleToString(req, _Digits), DoubleToString(fill, _Digits),
             DoubleToString(slip, _Digits), DoubleToString(spread, _Digits),
             DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
             DoubleToString(riskMoney, 2), DoubleToString(riskPct, 3), DoubleToString(kellyF, 4),
             DoubleToString(atr, _Digits), reason,
             DoubleToString(net, 2), IntegerToString(holdSec), exitReason);
   FileFlush(g_csv);
  }

//+------------------------------------------------------------------+
//| 模块一：信号                                                     |
//+------------------------------------------------------------------+
//--- 趋势状态：+1 多头单边 / -1 空头单边 / 0 震荡
int TrendState()
  {
   double f1, s1, f2, s2, adx;
   if(!Buf(g_hT1Fast, 0, 1, f1) || !Buf(g_hT1Slow, 0, 1, s1) ||
      !Buf(g_hT2Fast, 0, 1, f2) || !Buf(g_hT2Slow, 0, 1, s2) || !Buf(g_hAdx, 0, 1, adx))
      return 0;
   if(adx < InpTrendADX)
      return 0;
   if(f1 > s1 && f2 > s2)
      return 1;
   if(f1 < s1 && f2 < s2)
      return -1;
   return 0;
  }

//--- 均值回归：价格刺穿 EMA ± k×ATR 后，出现反向收线（回拉确认）
int SignalMeanReversion(const double atr, const double volRatio, string &reason)
  {
   if(!InpMR_Enable)
      return 0;
   if(InpMR_MaxVolRatio > 0.0 && volRatio > InpMR_MaxVolRatio)
      return 0;

   double ema1, ema2;
   if(!Buf(g_hEma, 0, 1, ema1) || !Buf(g_hEma, 0, 2, ema2))
      return 0;
   double rsi1 = 50.0, rsi2 = 50.0;
   if(InpMR_UseRSI && (!Buf(g_hRsi, 0, 1, rsi1) || !Buf(g_hRsi, 0, 2, rsi2)))
      return 0;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpSignalTF, 0, 4, r) < 4)
      return 0;

   double band = InpMR_DevK * atr;
   double room = InpMR_MinRoomATR * atr;

   //--- 做多：下方偏离 + 阳线回拉 + 仍在均值下方
   bool stretchedDn = (r[1].low < ema1 - band) || (r[2].low < ema2 - band);
   bool turnUp      = (r[1].close > r[1].open) && (r[1].close > r[2].close);
   bool rsiLong     = (!InpMR_UseRSI) || (MathMin(rsi1, rsi2) <= InpMR_RsiLevel);
   if(stretchedDn && turnUp && rsiLong && (ema1 - r[1].close) >= room)
     {
      reason = StringFormat("MR_LONG dev=%.2fATR rsi=%.1f vr=%.2f",
                            (ema1 - MathMin(r[1].low, r[2].low)) / atr, MathMin(rsi1, rsi2), volRatio);
      return 1;
     }

   //--- 做空：上方偏离 + 阴线回拉 + 仍在均值上方
   bool stretchedUp = (r[1].high > ema1 + band) || (r[2].high > ema2 + band);
   bool turnDn      = (r[1].close < r[1].open) && (r[1].close < r[2].close);
   bool rsiShort    = (!InpMR_UseRSI) || (MathMax(rsi1, rsi2) >= 100.0 - InpMR_RsiLevel);
   if(stretchedUp && turnDn && rsiShort && (r[1].close - ema1) >= room)
     {
      reason = StringFormat("MR_SHORT dev=%.2fATR rsi=%.1f vr=%.2f",
                            (MathMax(r[1].high, r[2].high) - ema1) / atr, MathMax(rsi1, rsi2), volRatio);
      return -1;
     }
   return 0;
  }

//--- 动量突破：高波动 + 收盘突破通道 + 大实体
int SignalMomentum(const double atr, const double volRatio, string &reason)
  {
   if(!InpMO_Enable || volRatio < InpMO_MinVolRatio)
      return 0;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = InpMO_Lookback + 2;
   if(CopyRates(_Symbol, InpSignalTF, 0, need, r) < need)
      return 0;

   double hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = 2; i < need; i++)
     {
      hh = MathMax(hh, r[i].high);
      ll = MathMin(ll, r[i].low);
     }
   double body = MathAbs(r[1].close - r[1].open);
   if(body < InpMO_BodyATR * atr)
      return 0;

   if(r[1].close > hh && r[1].close > r[1].open)
     {
      reason = StringFormat("MO_LONG body=%.2fATR vr=%.2f", body / atr, volRatio);
      return 1;
     }
   if(r[1].close < ll && r[1].close < r[1].open)
     {
      reason = StringFormat("MO_SHORT body=%.2fATR vr=%.2f", body / atr, volRatio);
      return -1;
     }
   return 0;
  }

//--- 每根新 K 线评估一次信号
void EvaluateSignals()
  {
   g_sigDir = 0;
   double atr, atrSlow;
   if(!Buf(g_hAtr, 0, 1, atr) || !Buf(g_hAtrSlow, 0, 1, atrSlow) || atr <= 0.0 || atrSlow <= 0.0)
      return;
   double volRatio = atr / atrSlow;
   int    trend    = (InpTrendMode == TREND_OFF) ? 0 : TrendState();

   string reason = "";
   bool   isMO   = false;
   int    dir    = SignalMeanReversion(atr, volRatio, reason);

   //--- 趋势过滤作用于均值回归
   if(dir != 0 && trend != 0)
     {
      if(InpTrendMode == TREND_PAUSE_MR)
         dir = 0;
      else
         if(InpTrendMode == TREND_FOLLOW_ONLY && dir != trend)
            dir = 0;
     }

   //--- 没有均值回归信号时再看动量突破（禁止逆势突破）
   if(dir == 0)
     {
      dir = SignalMomentum(atr, volRatio, reason);
      isMO = (dir != 0);
      if(dir != 0 && trend != 0 && dir != trend)
         dir = 0;
     }

   if(dir == 0)
      return;
   g_sigDir    = dir;
   g_sigReason = reason + StringFormat(" trend=%d", trend);
   g_sigIsMO   = isMO;
   g_sigExpire = TimeCurrent() + InpSignalValidSec;
  }

//+------------------------------------------------------------------+
//| 模块二：过滤                                                     |
//+------------------------------------------------------------------+
bool SessionOK()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;
   if(dt.day_of_week == 5 && dt.hour >= InpFridayStopHour)
      return false;
   int now = dt.hour * 60 + dt.min;
   if(InpAsiaOn && InWindow(now, g_asiaS, g_asiaE))
      return true;
   if(InpEuroOn && InWindow(now, g_euroS, g_euroE))
      return true;
   if(InpUSOn && InWindow(now, g_usS, g_usE))
      return true;
   return false;
  }

//--- 关键词匹配（空 = 全部通过）
bool NewsKeywordMatch(string name)
  {
   if(InpNewsKeywords == "")
      return true;
   string kws[];
   int n = StringSplit(InpNewsKeywords, ',', kws);
   StringToLower(name);
   for(int i = 0; i < n; i++)
     {
      string k = kws[i];
      StringTrimLeft(k);
      StringTrimRight(k);
      StringToLower(k);
      if(k != "" && StringFind(name, k) >= 0)
         return true;
     }
   return false;
  }

//--- 从经济日历取高影响事件；out 为事件时间（服务器时间）
bool FetchCalendar(const datetime from, const datetime to, datetime &times[], string &names[])
  {
   ArrayResize(times, 0);
   ArrayResize(names, 0);
   MqlCalendarValue v[];
   ResetLastError();
   int n = CalendarValueHistory(v, from, to, NULL, InpNewsCurrency);
   if(n < 0)
      return false;
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(v[i].event_id, ev))
         continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;
      if(!NewsKeywordMatch(ev.name))
         continue;
      int k = ArraySize(times);
      ArrayResize(times, k + 1);
      ArrayResize(names, k + 1);
      times[k] = v[i].time;
      names[k] = ev.name;
     }
   return true;
  }

//--- 回测：经济日历函数在策略测试器中不可用，改读公共文件夹里的 CSV
void LoadNewsCSV()
  {
   ArrayResize(g_news, 0);
   int h = FileOpen(InpNewsFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      Print("回测未找到新闻文件 ", InpNewsFile, "（公共文件夹），新闻过滤在本次回测中不生效");
      return;
     }
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      string p[];
      if(StringSplit(line, ',', p) < 1)
         continue;
      datetime t = StringToTime(p[0]);
      if(t <= 0)
         continue;
      int k = ArraySize(g_news);
      ArrayResize(g_news, k + 1);
      g_news[k] = t;
     }
   FileClose(h);
   Print("已从 CSV 载入新闻事件 ", ArraySize(g_news), " 条");
  }

//--- 实盘：导出历史新闻供回测使用
void ExportNewsCSV()
  {
   datetime now = TimeTradeServer();
   datetime t[];
   string   nm[];
   if(!FetchCalendar(now - (datetime)InpNewsExportDays * 86400, now + 7 * 86400, t, nm))
     {
      Print("导出新闻失败，错误 ", GetLastError());
      return;
     }
   int h = FileOpen(InpNewsFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   for(int i = 0; i < ArraySize(t); i++)
      FileWriteString(h, TimeToString(t[i], TIME_DATE | TIME_MINUTES) + "," + nm[i] + "\r\n");
   FileClose(h);
   Print("已导出新闻 ", ArraySize(t), " 条到公共文件夹 ", InpNewsFile);
  }

void RefreshNews()
  {
   if(!InpNewsEnable)
      return;
   if(g_isTester)
     {
      if(!g_newsLoaded)
        {
         LoadNewsCSV();
         g_newsLoaded = true;
        }
      return;
     }
   datetime now = TimeTradeServer();
   if(g_newsLoaded && now - g_newsLastRefresh < 900)
      return;
   datetime t[];
   string   nm[];
   if(FetchCalendar(now - 86400, now + 3 * 86400, t, nm))
     {
      ArrayCopy(g_news, t);
      ArrayResize(g_news, ArraySize(t));
      g_newsLoaded      = true;
      g_newsLastRefresh = now;
     }
   else
      Print("经济日历读取失败，错误 ", GetLastError(), "；沿用上次事件表");
  }

bool NewsBlocked()
  {
   if(!InpNewsEnable)
      return false;
   datetime now = TimeCurrent();
   for(int i = ArraySize(g_news) - 1; i >= 0; i--)
      if(now >= g_news[i] - InpNewsBeforeMin * 60 && now <= g_news[i] + InpNewsAfterMin * 60)
         return true;
   return false;
  }

//--- 综合开仓许可
bool CanOpen(string &why)
  {
   if(g_halted)                                           { why = "kill-switch";      return false; }
   if(g_dayStopped)                                       { why = "daily-loss-stop";  return false; }
   if(TimeCurrent() < g_pauseUntil)                       { why = "consec-loss-pause"; return false; }
   if(!g_isTester)
     {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))        { why = "disconnected";     return false; }
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
         !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
                                                          { why = "trade-not-allowed"; return false; }
     }
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
                                                          { why = "symbol-trade-mode"; return false; }
   if(!SessionOK())                                       { why = "session";          return false; }
   if(NewsBlocked())                                      { why = "news";             return false; }

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.ask <= 0.0 || tk.bid <= 0.0)
                                                          { why = "no-tick";          return false; }
   if(tk.ask - tk.bid > InpMaxSpread)                     { why = "spread";           return false; }
   if(TimeCurrent() - g_lastEntryTime < InpMinSecBetween) { why = "min-interval";     return false; }

   double lots;
   int    n      = CountOwn(lots);
   int    maxPos = g_hedging ? InpMaxPositions : 1;       // 净额账户只允许 1 个仓位
   if(n >= maxPos)                                        { why = "max-positions";    return false; }
   if(lots + g_volMin > InpMaxTotalLots + 1e-9)           { why = "max-total-lots";   return false; }

   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   if(margin > 0.0 && AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) < InpMinMarginLevel)
                                                          { why = "margin-level";     return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| 模块三：风控                                                     |
//+------------------------------------------------------------------+
//--- 登记一笔已平仓交易
void RegisterTrade(const double net, const datetime closeTime)
  {
   int n = ArraySize(g_hist);
   ArrayResize(g_hist, n + 1);
   g_hist[n] = net;
   if(n + 1 > InpKellyLookback)
      ArrayRemove(g_hist, 0, n + 1 - InpKellyLookback);

   if(net < 0.0)
      g_consecLoss++;
   else
      g_consecLoss = 0;

   if(InpMaxConsecLoss > 0 && g_consecLoss >= InpMaxConsecLoss)
     {
      g_pauseUntil = closeTime + InpPauseMinutes * 60;
      g_consecLoss = 0;
      if(g_pauseUntil > TimeCurrent())
         Print("连续亏损 ", InpMaxConsecLoss, " 笔，暂停开仓至 ", TimeToString(g_pauseUntil, TIME_DATE | TIME_MINUTES));
     }
  }

//--- 启动 / 重连时从历史成交重建滚动统计（按持仓 ID 归属到本 EA）
void LoadHistoryStats()
  {
   ArrayResize(g_hist, 0);
   g_consecLoss = 0;
   g_pauseUntil = 0;
   datetime now = TimeTradeServer();
   if(!HistorySelect(now - (datetime)InpHistDays * 86400, now + 86400))
      return;

   long     ids[];
   double   pnl[];
   datetime ct[];
   int      order[];
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      long pid   = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      int  idx   = -1;
      for(int k = ArraySize(ids) - 1; k >= 0; k--)
         if(ids[k] == pid)
           {
            idx = k;
            break;
           }
      double money = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                     HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      if(entry == DEAL_ENTRY_IN)
        {
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic || idx >= 0)
            continue;
         int k = ArraySize(ids);
         ArrayResize(ids, k + 1);
         ArrayResize(pnl, k + 1);
         ArrayResize(ct, k + 1);
         ids[k] = pid;
         pnl[k] = money;
         ct[k]  = 0;
        }
      else
         if((entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) && idx >= 0)
           {
            pnl[idx] += money;
            if(ct[idx] == 0)
              {
               int o = ArraySize(order);
               ArrayResize(order, o + 1);
               order[o] = idx;
              }
            ct[idx] = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
           }
     }
   for(int i = 0; i < ArraySize(order); i++)
      RegisterTrade(pnl[order[i]], ct[order[i]]);
  }

//--- 计算当日起始余额（余额 − 今日已实现盈亏；账户级，含其它 EA）
void ComputeDayStart()
  {
   datetime now = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   g_dayKey = dt.year * 1000 + dt.day_of_year;
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime d0 = StructToTime(dt);
   double realized = 0.0;
   if(HistorySelect(d0, now + 86400))
     {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         long type = HistoryDealGetInteger(d, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;
         realized += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                     HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
        }
     }
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE) - realized;
   g_dayStopped  = false;
  }

//--- 分数凯利：返回 false 表示样本不足
bool KellyF(double &f)
  {
   f = 0.0;
   int n = ArraySize(g_hist);
   if(n < InpKellyMinTrades)
      return false;
   int    wins = 0, losses = 0;
   double sumW = 0.0, sumL = 0.0;
   for(int i = 0; i < n; i++)
     {
      if(g_hist[i] > 0.0)      { wins++;   sumW += g_hist[i]; }
      else if(g_hist[i] < 0.0) { losses++; sumL -= g_hist[i]; }
     }
   if(wins == 0)
      return true;              // f = 0
   if(losses == 0 || sumL <= 0.0)
     {
      f = 1.0;
      return true;
     }
   double W = (double)wins / n;
   double R = (sumW / wins) / (sumL / losses);
   f = W - (1.0 - W) / R;      // Kelly = W − (1−W)/R
   return true;
  }

//--- 每手在止损处的亏损金额（含点差，外加手续费）
double LossPerLot(const ENUM_ORDER_TYPE type, const double entry, const double sl)
  {
   double p = 0.0;
   if(OrderCalcProfit(type, _Symbol, 1.0, entry, sl, p) && p < 0.0)
      return -p + InpCommissionPerLot;
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv > 0.0 && ts > 0.0)
      return MathAbs(entry - sl) / ts * tv + InpCommissionPerLot;
   return 0.0;
  }

//--- 平掉本 EA 的单个持仓（带重试）
bool ClosePosition(const ulong ticket, const string why)
  {
   for(int a = 0; a < MathMax(1, InpMaxRetries); a++)
     {
      if(g_trade.PositionClose(ticket) && IsDone(g_trade.ResultRetcode()))
        {
         Print("平仓 #", ticket, " 原因=", why);
         return true;
        }
      uint rc = g_trade.ResultRetcode();
      if(!IsRetryable(rc))
        {
         Print("平仓失败 #", ticket, " retcode=", rc, " ", g_trade.ResultRetcodeDescription());
         return false;
        }
      Sleep(InpRetryDelayMs * (a + 1));
     }
   return false;
  }

void CloseAllOwn(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      ClosePosition(t, why);
     }
  }

//--- 总开关触发后的处理：持续尝试平仓，全部平掉后移除 EA
void HaltProcedure()
  {
   double lots;
   if(CountOwn(lots) > 0)
     {
      CloseAllOwn("KILL_SWITCH");
      if(CountOwn(lots) > 0)
         return;                // 下个 tick / 定时器继续尝试
     }
   Print("总开关：持仓已清空，EA 停止。解除方法：把 InpResetKillSwitch 设为 true 重新加载一次。");
   ExpertRemove();
  }

//--- 账户级风控检查；返回 false 表示已触发总开关
bool CheckRisk()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
      return true;

   //--- 净值峰值与回撤总开关
   if(equity > g_peakEquity)
     {
      g_peakEquity = equity;
      GlobalVariableSet(g_gvPeak, g_peakEquity);
     }
   if(g_peakEquity > 0.0 && InpMaxEquityDD > 0.0)
     {
      double dd = (g_peakEquity - equity) / g_peakEquity * 100.0;
      if(dd >= InpMaxEquityDD)
        {
         g_halted = true;
         GlobalVariableSet(g_gvHalt, 1.0);
         string msg = StringFormat("总开关触发：净值回撤 %.2f%% ≥ %.2f%%（峰值 %.2f，当前 %.2f），全部平仓并停止",
                                   dd, InpMaxEquityDD, g_peakEquity, equity);
         Print(msg);
         if(!g_isTester)
            Alert(msg);
         HaltProcedure();
         return false;
        }
     }

   //--- 日切
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   int key = dt.year * 1000 + dt.day_of_year;
   if(key != g_dayKey)
     {
      g_dayKey      = key;
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayStopped  = false;
     }

   //--- 当日亏损（含浮亏）
   if(!g_dayStopped && g_dayStartBal > 0.0 && InpDailyLossPct > 0.0)
     {
      double lossPct = (g_dayStartBal - equity) / g_dayStartBal * 100.0;
      if(lossPct >= InpDailyLossPct)
        {
         g_dayStopped = true;
         g_sigDir     = 0;
         Print(StringFormat("当日亏损 %.2f%% ≥ %.2f%%，今日停止交易并平掉本 EA 持仓", lossPct, InpDailyLossPct));
         CloseAllOwn("DAILY_LOSS");
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| 模块四：执行                                                     |
//+------------------------------------------------------------------+
void OpenTrade(const int dir, const string reason, const bool isMO)
  {
   double atr, ema;
   if(!Buf(g_hAtr, 0, 1, atr) || atr <= 0.0 || !Buf(g_hEma, 0, 1, ema))
      return;

   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double kellyF = 0.0;
   bool   haveKelly = KellyF(kellyF);
   string cmt = InpComment + (isMO ? "|MO" : "|MR");

   for(int attempt = 0; attempt < MathMax(1, InpMaxRetries); attempt++)
     {
      MqlTick tk;
      if(!SymbolInfoTick(_Symbol, tk))
         return;
      double spread = tk.ask - tk.bid;
      if(spread > InpMaxSpread)
        {
         Print("开仓放弃：重试时点差 ", DoubleToString(spread, _Digits), " 超限");
         return;
        }

      //--- 止损 / 止盈距离（ATR 基础 + 最小下限 + 经纪商 STOPS_LEVEL）
      double stopsMin = StopsMinDist() + spread + _Point;
      double slDist   = MathMax(atr * (isMO ? InpMO_SL_ATR : InpMR_SL_ATR), MathMax(InpMinSL, stopsMin));
      double tpFloor  = MathMax(InpMinTP, stopsMin);
      double tpDist   = MathMax(atr * (isMO ? InpMO_TP_ATR : InpMR_TP_ATR), tpFloor);
      double entry    = (dir > 0) ? tk.ask : tk.bid;
      if(!isMO && InpMR_TPToMean)
        {
         double toMean = dir * (ema - entry);
         if(toMean > 0.0)
            tpDist = MathMax(tpFloor, MathMin(tpDist, toMean));
        }
      double sl = NormPrice(entry - dir * slDist);
      double tp = NormPrice(entry + dir * tpDist);

      //--- 仓位：分数凯利，受单笔最大风险硬上限约束
      double lossPerLot = LossPerLot(ot, entry, sl);
      if(lossPerLot <= 0.0)
        {
         Print("开仓放弃：无法计算每手风险");
         return;
        }
      double maxRiskMoney = equity * InpMaxRiskPct / 100.0;
      double lots;
      if(haveKelly && kellyF > 0.0)
        {
         double riskPct = MathMin(kellyF * InpKellyFraction * 100.0, InpMaxRiskPct);
         lots = FloorLots(equity * riskPct / 100.0 / lossPerLot);
         if(lots < g_volMin)
            lots = g_volMin;
        }
      else
         lots = MathMax(g_volMin, FloorLots(InpFixedLot));   // 样本不足或凯利≤0：固定最小手数

      if(lots * lossPerLot > maxRiskMoney)
         lots = FloorLots(maxRiskMoney / lossPerLot);
      double curLots;
      CountOwn(curLots);
      if(curLots + lots > InpMaxTotalLots)
         lots = FloorLots(InpMaxTotalLots - curLots);
      if(lots < g_volMin)
        {
         Print(StringFormat("开仓放弃：最小手数的风险 %.2f 超过单笔上限 %.2f 或总手数已满",
                            g_volMin * lossPerLot, maxRiskMoney));
         return;
        }

      //--- 保证金检查（开仓后保证金水平仍须高于阈值）
      double needMargin = 0.0;
      if(!OrderCalcMargin(ot, _Symbol, lots, entry, needMargin))
         return;
      double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
      if(needMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) ||
         (usedMargin + needMargin > 0.0 && equity / (usedMargin + needMargin) * 100.0 < InpMinMarginLevel))
        {
         Print("开仓放弃：保证金不足或开仓后保证金水平低于阈值");
         return;
        }

      //--- 发送
      bool sent = (dir > 0) ? g_trade.Buy(lots, _Symbol, entry, sl, tp, cmt)
                            : g_trade.Sell(lots, _Symbol, entry, sl, tp, cmt);
      uint rc = g_trade.ResultRetcode();
      if(sent && IsDone(rc))
        {
         g_lastEntryTime = TimeCurrent();
         ulong  deal = g_trade.ResultDeal();
         double fill = g_trade.ResultPrice();
         double vol  = g_trade.ResultVolume();
         ulong  pos  = g_trade.ResultOrder();
         if(deal > 0 && HistoryDealSelect(deal))
           {
            if(fill <= 0.0)
               fill = HistoryDealGetDouble(deal, DEAL_PRICE);
            pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
           }
         if(fill <= 0.0)
            fill = entry;
         if(vol <= 0.0)
            vol = lots;
         double slip      = dir * (fill - entry);            // >0 为不利滑点
         double riskMoney = vol * LossPerLot(ot, fill, sl);
         double riskPct   = (equity > 0.0) ? riskMoney / equity * 100.0 : 0.0;

         Print(StringFormat("开仓 %s %.2f 手 @%s SL=%s TP=%s | 原因=%s | 点差=%s 滑点=%s | 风险=%.2f (%.3f%%) 凯利f=%.3f(%s)",
                            (dir > 0 ? "BUY" : "SELL"), vol, DoubleToString(fill, _Digits),
                            DoubleToString(sl, _Digits), DoubleToString(tp, _Digits), reason,
                            DoubleToString(spread, _Digits), DoubleToString(slip, _Digits),
                            riskMoney, riskPct, kellyF, (haveKelly ? "有效" : "样本不足")));
         if(slip > InpSlipWarn)
            Print(StringFormat("【滑点警告】不利滑点 %s 超过阈值 %s（请求 %s，成交 %s）",
                               DoubleToString(slip, _Digits), DoubleToString(InpSlipWarn, _Digits),
                               DoubleToString(entry, _Digits), DoubleToString(fill, _Digits)));
         CsvRow("OPEN", pos, (dir > 0 ? "BUY" : "SELL"), vol, entry, fill, slip, spread, sl, tp,
                riskMoney, riskPct, kellyF, atr, reason, 0.0, 0, "");
         return;
        }

      Print(StringFormat("开仓失败（第 %d 次）retcode=%u %s", attempt + 1, rc, g_trade.ResultRetcodeDescription()));
      if(!IsRetryable(rc))
         return;                 // 超时(TIMEOUT)等不确定状态不重试，避免重复下单
      Sleep(InpRetryDelayMs * (attempt + 1));
      if(!g_isTester && !TerminalInfoInteger(TERMINAL_CONNECTED))
         return;
     }
  }

//--- 持仓管理：缺失止损补救 / 时间止损 / 保本 / 移动止损
void ManagePositions()
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double atr;
   if(!Buf(g_hAtr, 0, 1, atr) || atr <= 0.0)
      return;
   double minDist = StopsMinDist();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      int      dir   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double   open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl    = PositionGetDouble(POSITION_SL);
      double   tp    = PositionGetDouble(POSITION_TP);
      datetime ot    = (datetime)PositionGetInteger(POSITION_TIME);
      double   cur   = (dir > 0) ? tk.bid : tk.ask;          // 平仓侧价格
      double   gain  = dir * (cur - open);

      //--- 1) 硬性要求：持仓必须有止损。补不上就立即平仓
      if(sl == 0.0)
        {
         double d     = MathMax(atr * InpMR_SL_ATR, MathMax(InpMinSL, minDist + _Point));
         double newSL = NormPrice(MathMin(open * dir, cur * dir) * dir - dir * d);
         double newTP = (tp == 0.0) ? NormPrice(cur + dir * MathMax(InpMinTP, minDist + _Point)) : tp;
         if(!g_trade.PositionModify(t, newSL, newTP) || !IsDone(g_trade.ResultRetcode()))
           {
            Print("持仓 #", t, " 无止损且补设失败，立即平仓");
            ClosePosition(t, "NO_SL");
           }
         continue;
        }

      //--- 2) 时间止损
      if(InpMaxHoldSec > 0 && TimeCurrent() - ot >= InpMaxHoldSec)
        {
         ClosePosition(t, "TIME_STOP");
         continue;
        }

      //--- 3) 保本 / 移动止损（只收紧不放宽）
      double newSL = sl;
      if(InpUseBE && gain >= InpBE_TrigATR * atr)
        {
         double c = open + dir * InpBE_Offset;
         if(dir * (c - newSL) > 0.0)
            newSL = c;
        }
      if(InpUseTrail && gain >= InpTrail_StartATR * atr)
        {
         double c = cur - dir * InpTrail_DistATR * atr;
         if(dir * (c - newSL) > 0.0)
            newSL = c;
        }
      newSL = NormPrice(newSL);
      if(dir * (newSL - sl) >= MathMax(InpTrailStep, _Point) && dir * (cur - newSL) > minDist)
        {
         if(!g_trade.PositionModify(t, newSL, tp) && InpVerbose)
            Print("修改止损失败 #", t, " retcode=", g_trade.ResultRetcode());
        }
     }
  }

//+------------------------------------------------------------------+
//| 事件处理                                                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);
   g_isOptim  = (bool)MQLInfoInteger(MQL_OPTIMIZATION);

   //--- 参数校验
   if(InpKellyFraction <= 0.0 || InpKellyFraction > 1.0 || InpMaxRiskPct <= 0.0 ||
      InpEmaPeriod < 2 || InpAtrPeriod < 2 || InpAtrSlowPeriod < 2 || InpMO_Lookback < 2 ||
      InpKellyLookback < 10 || InpMaxPositions < 1 || InpMaxTotalLots <= 0.0 ||
      InpMinSL <= 0.0 || InpMinTP <= 0.0 || InpMaxSpread <= 0.0)
     {
      Print("参数非法，请检查输入");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!ParseHM(InpAsiaStart, g_asiaS) || !ParseHM(InpAsiaEnd, g_asiaE) ||
      !ParseHM(InpEuroStart, g_euroS) || !ParseHM(InpEuroEnd, g_euroE) ||
      !ParseHM(InpUSStart, g_usS) || !ParseHM(InpUSEnd, g_usE))
     {
      Print("时段格式错误，应为 HH:MM");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- 品种属性（兼容 2 位 / 3 位报价）
   g_volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(g_volStep <= 0.0 || g_volMin <= 0.0 || _Point <= 0.0)
     {
      Print("品种属性读取失败");
      return INIT_FAILED;
     }
   g_volDigits = (int)MathMax(0.0, MathCeil(-MathLog10(g_volStep) - 1e-9));
   g_hedging   = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   //--- 总开关持久化标志（终端全局变量，按账户 + 品种 + Magic 区分）
   string key = StringFormat("XS_%I64d_%s_%I64d", AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, InpMagic);
   g_gvPeak = key + "_peak";
   g_gvHalt = key + "_halt";
   if(g_isTester)                // 回测 / 优化每次从干净状态开始，不继承上一轮的总开关标志
     {
      GlobalVariableDel(g_gvHalt);
      GlobalVariableDel(g_gvPeak);
     }
   if(GlobalVariableCheck(g_gvHalt) && GlobalVariableGet(g_gvHalt) > 0.5)
     {
      if(!InpResetKillSwitch)
        {
         string msg = "净值回撤总开关此前已触发，EA 拒绝启动。确认风险后把 InpResetKillSwitch 设为 true 重新加载一次。";
         Print(msg);
         if(!g_isTester)
            Alert(msg);
         return INIT_FAILED;
        }
      GlobalVariableDel(g_gvHalt);
      GlobalVariableDel(g_gvPeak);
      Print("总开关已手动解除，净值峰值重置为当前净值。请把 InpResetKillSwitch 改回 false。");
     }
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GlobalVariableCheck(g_gvPeak))
      g_peakEquity = MathMax(g_peakEquity, GlobalVariableGet(g_gvPeak));
   GlobalVariableSet(g_gvPeak, g_peakEquity);

   //--- 指标
   g_hEma     = iMA(_Symbol, InpSignalTF, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr     = iATR(_Symbol, InpSignalTF, InpAtrPeriod);
   g_hAtrSlow = iATR(_Symbol, InpSignalTF, InpAtrSlowPeriod);
   g_hRsi     = iRSI(_Symbol, InpSignalTF, InpRsiPeriod, PRICE_CLOSE);
   g_hT1Fast  = iMA(_Symbol, InpTrendTF1, InpTrendFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hT1Slow  = iMA(_Symbol, InpTrendTF1, InpTrendSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hT2Fast  = iMA(_Symbol, InpTrendTF2, InpTrendFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hT2Slow  = iMA(_Symbol, InpTrendTF2, InpTrendSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAdx     = iADX(_Symbol, InpTrendTF2, InpTrendAdxPeriod);
   if(g_hEma == INVALID_HANDLE || g_hAtr == INVALID_HANDLE || g_hAtrSlow == INVALID_HANDLE ||
      g_hRsi == INVALID_HANDLE || g_hT1Fast == INVALID_HANDLE || g_hT1Slow == INVALID_HANDLE ||
      g_hT2Fast == INVALID_HANDLE || g_hT2Slow == INVALID_HANDLE || g_hAdx == INVALID_HANDLE)
     {
      Print("指标句柄创建失败");
      return INIT_FAILED;
     }

   //--- 交易对象
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)MathMax(1.0, MathRound(InpDeviation / _Point)));
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   //--- 状态恢复
   LoadHistoryStats();
   ComputeDayStart();
   CsvOpen();
   if(InpNewsEnable && !g_isTester && InpNewsExportDays > 0)
      ExportNewsCSV();
   RefreshNews();
   g_wasConnected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   EventSetTimer(1);

   Print(StringFormat("XAU_Scalper 启动：%s digits=%d point=%s 手数[%.2f, %.2f] 步长=%.2f STOPS_LEVEL=%d 账户模式=%s 历史样本=%d",
                      _Symbol, _Digits, DoubleToString(_Point, _Digits), g_volMin, g_volMax, g_volStep,
                      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                      (g_hedging ? "对冲" : "净额"), ArraySize(g_hist)));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_csv != INVALID_HANDLE)
      FileClose(g_csv);
   IndicatorRelease(g_hEma);
   IndicatorRelease(g_hAtr);
   IndicatorRelease(g_hAtrSlow);
   IndicatorRelease(g_hRsi);
   IndicatorRelease(g_hT1Fast);
   IndicatorRelease(g_hT1Slow);
   IndicatorRelease(g_hT2Fast);
   IndicatorRelease(g_hT2Slow);
   IndicatorRelease(g_hAdx);
  }

void OnTick()
  {
   if(g_halted)
     {
      HaltProcedure();
      return;
     }
   if(!CheckRisk())
      return;

   ManagePositions();

   //--- 新闻窗口内可选平仓
   if(InpNewsClosePos && NewsBlocked())
     {
      double l;
      if(CountOwn(l) > 0)
         CloseAllOwn("NEWS");
     }

   //--- 每根新 K 线只评估一次信号（防止重复触发）
   datetime bt = iTime(_Symbol, InpSignalTF, 0);
   if(bt != 0 && bt != g_lastBarTime)
     {
      g_lastBarTime  = bt;
      g_lastBlockMsg = "";
      EvaluateSignals();
     }

   if(g_sigDir == 0)
      return;
   if(TimeCurrent() > g_sigExpire)
     {
      g_sigDir = 0;
      return;
     }
   string why = "";
   if(!CanOpen(why))
     {
      if(InpVerbose && why != g_lastBlockMsg)
        {
         Print("信号被过滤：", g_sigReason, " -> ", why);
         g_lastBlockMsg = why;
        }
      return;                    // 有效期内继续等待（例如点差恢复）
     }
   int    dir    = g_sigDir;
   g_sigDir      = 0;            // 无论成败，本根 K 线只尝试一次
   OpenTrade(dir, g_sigReason, g_sigIsMO);
  }

//--- 定时器：无 tick 时也执行风控；监控连接；刷新新闻
void OnTimer()
  {
   bool conn = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   if(conn != g_wasConnected)
     {
      g_wasConnected = conn;
      if(conn)
        {
         Print("连接已恢复，重新同步历史统计与当日基准");
         LoadHistoryStats();
         ComputeDayStart();      // 若仍超过当日亏损上限，CheckRisk 会立即再次停止
        }
      else
         Print("【警告】与交易服务器断开，暂停开仓（已有持仓由服务器端 SL/TP 保护）");
     }
   if(!conn)
      return;
   RefreshNews();
   if(g_halted)
      HaltProcedure();
   else
      CheckRisk();
  }

//--- 成交事件：记录平仓结果，更新滚动统计
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal))
      return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   long     pid      = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   double   outPrice = HistoryDealGetDouble(deal, DEAL_PRICE);
   double   outVol   = HistoryDealGetDouble(deal, DEAL_VOLUME);
   datetime outTime  = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   long     dreason  = HistoryDealGetInteger(deal, DEAL_REASON);

   //--- 通过持仓 ID 找开仓成交，按开仓 Magic 归属（SL/TP/手动平仓的成交 Magic 可能不同）
   if(!HistorySelectByPosition(pid))
      return;
   double   net     = 0.0;
   long     inMagic = -1, inType = -1;
   datetime inTime  = 0;
   double   inPrice = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
             HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN && inMagic < 0)
        {
         inMagic = HistoryDealGetInteger(d, DEAL_MAGIC);
         inType  = HistoryDealGetInteger(d, DEAL_TYPE);
         inTime  = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         inPrice = HistoryDealGetDouble(d, DEAL_PRICE);
        }
     }
   if(inMagic != InpMagic)
      return;

   string ex = "OTHER";
   if(dreason == DEAL_REASON_SL)
      ex = "SL";
   else if(dreason == DEAL_REASON_TP)
      ex = "TP";
   else if(dreason == DEAL_REASON_EXPERT)
      ex = "EA";
   else if(dreason == DEAL_REASON_CLIENT || dreason == DEAL_REASON_MOBILE || dreason == DEAL_REASON_WEB)
      ex = "MANUAL";
   else if(dreason == DEAL_REASON_SO)
      ex = "STOP_OUT";

   long hold = (long)(outTime - inTime);
   RegisterTrade(net, outTime);
   Print(StringFormat("平仓记录 #%I64d %s 净盈亏=%.2f 持仓=%I64d 秒 出场=%s 连亏=%d",
                      pid, (inType == DEAL_TYPE_BUY ? "BUY" : "SELL"), net, hold, ex, g_consecLoss));
   CsvRow("CLOSE", (ulong)pid, (inType == DEAL_TYPE_BUY ? "BUY" : "SELL"), outVol, inPrice, outPrice,
          0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, "", net, hold, ex);
  }

//+------------------------------------------------------------------+
//| 自定义优化指标：盈利因子 × 夏普 × (1 − 最大回撤)                 |
//+------------------------------------------------------------------+
double OnTester()
  {
   if(TesterStatistics(STAT_TRADES) < InpOptMinTrades)
      return 0.0;
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double sh = TesterStatistics(STAT_SHARPE_RATIO);
   double dd = TesterStatistics(STAT_EQUITY_DDREL_PERCENT) / 100.0;
   if(!MathIsValidNumber(pf) || !MathIsValidNumber(sh) || !MathIsValidNumber(dd))
      return 0.0;
   pf = MathMin(pf, 10.0);                    // 无亏损单时盈利因子会异常大，封顶
   dd = MathMax(0.0, MathMin(1.0, dd));
   return pf * sh * (1.0 - dd);
  }
//+------------------------------------------------------------------+
