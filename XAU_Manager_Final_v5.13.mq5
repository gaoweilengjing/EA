//+------------------------------------------------------------------+
//|                                    XAU_Manager_Final_v5.13.mq5   |
//|           通用仓位管理系统（多品种自适应 + 自动时区 + 状态持久化）   |
//|                                                              v5.13|
//+------------------------------------------------------------------+
//| v5.13 修复说明（相对 v5.12）：                                     |
//| 1. 状态持久化改为终端全局变量（GlobalVariable），彻底移除不可靠的    |
//|    持仓注释写入（MT5 无法修改持仓 comment，旧方案实际从未生效）。   |
//| 2. 初始 R、初始手数、追踪最高价、保本底线全部持久化，重启后恢复的    |
//|    是"真实初始状态"，不再用当前 SL 反推 R（旧方案会污染 R 基准）。  |
//| 3. 新增手动止损检测与三种处理模式（尊重/接管/暂停），并且删除止损    |
//|    时无条件强制恢复保护。                                          |
//| 4. ModifyPosition 增加 stops/freeze level 校验、retcode 严格判断。 |
//| 5. PartialClose 增加填充模式自适应、retcode 校验、点差过滤。        |
//| 6. 最小止损美元换算改用 SYMBOL_TRADE_TICK_SIZE。                   |
//| 7. 手数规范化改用品种真实 VOLUME_MIN / VOLUME_STEP。               |
//| 8. 面板改为对象复用，不再每秒删除重建数百个对象。                    |
//| 9. 修复追踪最高价在"未达最小移动距离"时丢失更新的问题。              |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "5.13"
#property strict

//===== 基础设置 =====
input string   InpSection1 = "========== 基础设置 ==========";
input int      InpMagicNumber = 20260610;
input bool     InpManageAnyMagic = true;
input bool     InpShowPanel = true;
input bool     InpTakeoverExisting = false;
// 时区偏移已自动检测，无需手动设置（保留参数但不使用）
input int      InpTimeZoneOffset_Deprecated = 6;     // 已废弃，系统自动检测

//===== 初始止损（加权ATR + 时段自适应）=====
input string   InpSection2 = "========== 初始止损（加权ATR） ==========";
input int      InpAtrPeriod = 14;
input double   InpATRMult_Asia = 2.0;               // 亚盘（08-15）倍数
input double   InpATRMult_Europe = 1.5;             // 欧盘（15-20）倍数
input double   InpATRMult_US = 1.4;                 // 美盘（20-04）倍数
input double   InpMinStop_ATR_Ratio = 0.5;          // 最小止损距离 = ATR * 该值
input double   InpMinStop_AbsUSD = 2.0;             // 最小止损绝对下限（美元）

//===== 分层平仓 =====
input string   InpSection3 = "========== 分层平仓 ==========";
input double   InpL1_TriggerR = 0.5;
input double   InpL1_Pct = 30.0;
input double   InpL1_NewSL_R = 0.2;                 // 第一层后新止损偏移（R倍数）

input double   InpL2_TriggerR = 0.7;
input double   InpL2_Pct = 20.0;

input double   InpL3_TriggerR = 1.1;
input double   InpL3_Pct = 30.0;
input double   InpL3_FinalOffset_ATR_Ratio = 0.12;  // 第三层后保本偏移 = ATR * 该值

//===== 追踪止损 =====
input string   InpSection4 = "========== 追踪止损（优化版） ==========";
input double   InpTrailing_StartR = 1.3;             // 追踪启动倍数
input bool     InpEnableTrailing = true;

// 动态K值分段参数
input double   InpTrailing_K_Profit1 = 2.0;          // 盈利≤此值使用K1
input double   InpTrailing_K1 = 1.2;                 // 宽松K值
input double   InpTrailing_K_Profit2 = 3.5;          // 盈利≤此值使用K2
input double   InpTrailing_K2 = 0.9;                 // 中等K值
input double   InpTrailing_K3 = 0.6;                 // 极紧K值（盈利>K_Profit2时使用）

// 最小移动距离（ATR比例动态自适应）
input double   InpMinMoveATR_Ratio = 0.05;           // 最小移动距离 = ATR * 该值

//===== 手数设置 =====
input string   InpSection5 = "========== 手数设置 ==========";
input double   InpMinLot = 0.01;                     // 备用最小手数（品种查询失败时）
input double   InpLotStep = 0.01;                    // 备用手数步长（品种查询失败时）

//===== 手动止损处理 =====
enum ENUM_MANUAL_SL_MODE
{
   MANUAL_SL_RESPECT = 0,   // 尊重手动止损（收紧则作为新底线，放松则警告但接受）
   MANUAL_SL_OVERRIDE = 1,  // EA完全接管（手动修改会被立即改回）
   MANUAL_SL_PAUSE = 2      // 检测到手动干预后，该仓位暂停EA管理
};
input string   InpSection6 = "========== 手动止损处理 ==========";
input ENUM_MANUAL_SL_MODE InpManualSLMode = MANUAL_SL_RESPECT;

//===== 执行保护 =====
input string   InpSection7 = "========== 执行保护 ==========";
input double   InpMaxSpread_ATR_Ratio = 0.15;        // 点差超过 ATR*该值 时暂缓平仓/移损（0=禁用）

//+------------------------------------------------------------------+
//| 枚举与结构                                                       |
//+------------------------------------------------------------------+
enum ENUM_MANAGE_STATE
{
   STATE_NEW,
   STATE_L1_DONE,
   STATE_L2_DONE,
   STATE_L3_DONE,
   STATE_TRAILING_ACTIVE,
   STATE_FINISHED
};

struct PositionInfo
{
   ulong          ticket;
   string         symbol;
   double         entry;
   double         initialSL;
   double         rDistance;       // 初始R距离，一经确定永不改变
   double         initialVolume;   // 原始开仓手数，一经确定永不改变
   ENUM_MANAGE_STATE state;
   bool           l1Closed;
   bool           l2Closed;
   bool           l3Closed;
   bool           trailingActive;
   bool           paused;          // 手动干预后暂停管理
   double         l1Price, l1Volume;
   double         l2Price, l2Volume;
   double         l3Price, l3Volume;
   double         slFloor;         // 止损底线（保本线/手动收紧线），EA永不放松到底线以下
   double         lastSetSL;       // EA最后一次设置的止损，用于检测手动修改
   double         trailingHighest;
   int            digits;
   double         point;
   datetime       initTime;
};

//+------------------------------------------------------------------+
//| 全局变量                                                         |
//+------------------------------------------------------------------+
PositionInfo ManagedPositions[];
string ATRSymbols[];            // 已创建ATR句柄的品种列表
int    ATRHandles[];            // 对应句柄
string prefix = "PM_";
ENUM_TIMEFRAMES expectedTF = PERIOD_M15;
string gvPrefix = "PM513_";      // 终端全局变量前缀（状态持久化）
int    g_GMT_Offset = 0;         // 服务器时间与GMT的偏移秒数
int    g_lastPanelRows = 0;      // 面板上次显示的行数（用于对象复用）

// 持久化标志位
#define PM_FLAG_L1      1
#define PM_FLAG_L2      2
#define PM_FLAG_L3      4
#define PM_FLAG_TRAIL   8
#define PM_FLAG_PAUSED  16

//+------------------------------------------------------------------+
//| 状态持久化：终端全局变量（写入磁盘，重启终端后仍在）                |
//+------------------------------------------------------------------+
string GVName(ulong ticket, string field)
{
   return gvPrefix + (string)ticket + "_" + field;
}

void SaveState(PositionInfo &pos)
{
   GlobalVariableSet(GVName(pos.ticket, "R"),     pos.rDistance);
   GlobalVariableSet(GVName(pos.ticket, "VOL"),   pos.initialVolume);
   GlobalVariableSet(GVName(pos.ticket, "ISL"),   pos.initialSL);
   GlobalVariableSet(GVName(pos.ticket, "HIGH"),  pos.trailingHighest);
   GlobalVariableSet(GVName(pos.ticket, "FLOOR"), pos.slFloor);
   GlobalVariableSet(GVName(pos.ticket, "LSL"),   pos.lastSetSL);
   double flags = 0;
   if(pos.l1Closed)       flags += PM_FLAG_L1;
   if(pos.l2Closed)       flags += PM_FLAG_L2;
   if(pos.l3Closed)       flags += PM_FLAG_L3;
   if(pos.trailingActive) flags += PM_FLAG_TRAIL;
   if(pos.paused)         flags += PM_FLAG_PAUSED;
   GlobalVariableSet(GVName(pos.ticket, "FLAGS"), flags);
}

bool HasState(ulong ticket)
{
   return GlobalVariableCheck(GVName(ticket, "R"));
}

void DeleteState(ulong ticket)
{
   GlobalVariableDel(GVName(ticket, "R"));
   GlobalVariableDel(GVName(ticket, "VOL"));
   GlobalVariableDel(GVName(ticket, "ISL"));
   GlobalVariableDel(GVName(ticket, "HIGH"));
   GlobalVariableDel(GVName(ticket, "FLOOR"));
   GlobalVariableDel(GVName(ticket, "LSL"));
   GlobalVariableDel(GVName(ticket, "FLAGS"));
}

// 清理已平仓订单遗留的全局变量
void CleanOrphanStates()
{
   int total = GlobalVariablesTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, gvPrefix) != 0) continue;
      string rest = StringSubstr(name, StringLen(gvPrefix));
      int us = StringFind(rest, "_");
      if(us <= 0) continue;
      ulong ticket = (ulong)StringToInteger(StringSubstr(rest, 0, us));
      if(!PositionSelectByTicket(ticket))
         GlobalVariableDel(name);
   }
}

//+------------------------------------------------------------------+
//| 辅助函数：获取品种ATR句柄（按需创建）                              |
//+------------------------------------------------------------------+
int GetAtrHandle(string symbol)
{
   for(int i=0; i<ArraySize(ATRSymbols); i++)
      if(ATRSymbols[i] == symbol)
         return ATRHandles[i];
   int handle = iATR(symbol, expectedTF, InpAtrPeriod);
   if(handle != INVALID_HANDLE)
   {
      int size = ArraySize(ATRSymbols);
      ArrayResize(ATRSymbols, size+1);
      ArrayResize(ATRHandles, size+1);
      ATRSymbols[size] = symbol;
      ATRHandles[size] = handle;
   }
   return handle;
}

//+------------------------------------------------------------------+
//| 加权平均ATR（5根已完成K线，指数权重）                              |
//+------------------------------------------------------------------+
double GetWeightedAverageATR(string symbol)
{
   int handle = GetAtrHandle(symbol);
   if(handle == INVALID_HANDLE) return 0;
   double atrValues[5];
   if(CopyBuffer(handle, 0, 1, 5, atrValues) != 5)
      return 0;
   // CopyBuffer: 索引0为最旧，索引4为最新已完成K线
   double weights[5] = {0.1, 0.15, 0.2, 0.25, 0.3};
   double sum = 0, wsum = 0;
   for(int i=0; i<5; i++)
   {
      sum += atrValues[i] * weights[i];
      wsum += weights[i];
   }
   return sum / wsum;
}

//+------------------------------------------------------------------+
//| 稳定ATR（仅前一根已完成K线，用于追踪止损）                         |
//+------------------------------------------------------------------+
double GetStableATR(string symbol)
{
   int handle = GetAtrHandle(symbol);
   if(handle == INVALID_HANDLE) return 0;
   double buffer[1];
   if(CopyBuffer(handle, 0, 1, 1, buffer) == 1)
      return buffer[0];
   return 0;
}

//+------------------------------------------------------------------+
//| 品种手数规格（优先用品种真实规格，查询失败时用输入参数兜底）         |
//+------------------------------------------------------------------+
double GetSymbolMinLot(string symbol)
{
   double v = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   return (v > 0) ? v : InpMinLot;
}

double GetSymbolLotStep(string symbol)
{
   double v = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   return (v > 0) ? v : InpLotStep;
}

//+------------------------------------------------------------------+
//| 计算部分平仓量（基于原始开仓手数）                                 |
//+------------------------------------------------------------------+
double CalculatePartialVolumeUp(string symbol, double baseVolume, double percent, double currentVolume)
{
   double lotStep = GetSymbolLotStep(symbol);
   double minLot  = GetSymbolMinLot(symbol);
   double raw = baseVolume * (percent / 100.0);
   int steps = (int)MathCeil(raw / lotStep - 0.0000001);
   double planned = steps * lotStep;
   if(planned > currentVolume)
      planned = currentVolume;
   if(planned < minLot)
      return 0;
   planned = MathRound(planned / lotStep) * lotStep;
   int volDigits = (int)MathRound(-MathLog10(lotStep));
   if(volDigits < 0) volDigits = 2;
   return NormalizeDouble(planned, volDigits);
}

//+------------------------------------------------------------------+
//| 点差过滤：点差过大时暂缓交易动作（黄金新闻时段保护）                |
//+------------------------------------------------------------------+
bool SpreadTooWide(string symbol)
{
   if(InpMaxSpread_ATR_Ratio <= 0) return false;
   double atr = GetStableATR(symbol);
   if(atr <= 0) return false;
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double spread = ask - bid;
   return (spread > atr * InpMaxSpread_ATR_Ratio);
}

//+------------------------------------------------------------------+
//| 修改止损（stops/freeze level 校验 + retcode 严格判断 + 重试）      |
//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double newSL, double newTP)
{
   if(!PositionSelectByTicket(ticket)) return false;
   string symbol = PositionGetString(POSITION_SYMBOL);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double currSL = PositionGetDouble(POSITION_SL);
   double currTP = PositionGetDouble(POSITION_TP);
   int posType = (int)PositionGetInteger(POSITION_TYPE);

   newSL = NormalizeDouble(newSL, digits);
   newTP = NormalizeDouble(newTP, digits);
   if(newSL == currSL && newTP == currTP) return true;

   // 经纪商最小止损距离与冻结区校验
   long stopsLevel  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLevel, (double)freezeLevel) * point;
   if(newSL != 0 && minDist > 0)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(posType == POSITION_TYPE_BUY && newSL > bid - minDist)
         newSL = NormalizeDouble(bid - minDist, digits);
      else if(posType == POSITION_TYPE_SELL && newSL < ask + minDist)
         newSL = NormalizeDouble(ask + minDist, digits);
      // 被距离限制钳制后，若对多头不再是收紧（对空头同理），本次放弃，等下一个Tick
      if(currSL != 0)
      {
         if(posType == POSITION_TYPE_BUY && newSL <= currSL) return false;
         if(posType == POSITION_TYPE_SELL && newSL >= currSL) return false;
      }
   }

   int retries = 3;
   int delayMs = 150;
   for(int attempt = 1; attempt <= retries; attempt++)
   {
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      request.action = TRADE_ACTION_SLTP;
      request.position = ticket;
      request.symbol = symbol;
      request.sl = newSL;
      request.tp = newTP;

      bool sent = OrderSend(request, result);
      if(sent && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED))
         return true;

      uint retcode = result.retcode;
      // 可重试错误码：报价过期、价格改变、超时、市场繁忙
      if(retcode == TRADE_RETCODE_REQUOTE || retcode == TRADE_RETCODE_PRICE_CHANGED ||
         retcode == TRADE_RETCODE_TIMEOUT || retcode == TRADE_RETCODE_PRICE_OFF ||
         retcode == TRADE_RETCODE_CONNECTION)
      {
         if(attempt < retries)
            Sleep(delayMs * attempt);
      }
      else
      {
         Print("修改止损失败(不可重试) | 订单:", ticket, " 新SL:", newSL, " retcode:", retcode);
         return false;
      }
   }
   Print("修改止损最终失败 | 订单:", ticket, " 新SL:", newSL, " 错误:", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| 部分平仓（填充模式自适应 + retcode 校验）                          |
//+------------------------------------------------------------------+
bool PartialClose(ulong ticket, double volume)
{
   if(!PositionSelectByTicket(ticket)) return false;
   string symbol = PositionGetString(POSITION_SYMBOL);
   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   if(volume > currentVolume) volume = currentVolume;
   if(volume < GetSymbolMinLot(symbol)) return false;

   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = symbol;
   request.volume = volume;
   request.deviation = 10;
   request.magic = InpMagicNumber;
   request.comment = "Partial Close";

   // 填充模式自适应（不同经纪商/品种支持不同模式）
   long fillingMode = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_IOC) != 0)
      request.type_filling = ORDER_FILLING_IOC;
   else if((fillingMode & SYMBOL_FILLING_FOK) != 0)
      request.type_filling = ORDER_FILLING_FOK;
   else
      request.type_filling = ORDER_FILLING_RETURN;

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   int posType = (int)PositionGetInteger(POSITION_TYPE);
   if(posType == POSITION_TYPE_BUY)
   {
      request.type = ORDER_TYPE_SELL;
      request.price = bid;
   }
   else
   {
      request.type = ORDER_TYPE_BUY;
      request.price = ask;
   }

   bool sent = OrderSend(request, result);
   if(!sent || (result.retcode != TRADE_RETCODE_DONE &&
                result.retcode != TRADE_RETCODE_DONE_PARTIAL &&
                result.retcode != TRADE_RETCODE_PLACED))
   {
      Print("部分平仓失败 | 订单:", ticket, " retcode:", result.retcode, " 错误:", GetLastError());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 动态K值获取                                                       |
//+------------------------------------------------------------------+
double GetDynamicK(double profitInR)
{
   if(profitInR <= InpTrailing_K_Profit1)
      return InpTrailing_K1;
   else if(profitInR <= InpTrailing_K_Profit2)
      return InpTrailing_K2;
   else
      return InpTrailing_K3;
}

//+------------------------------------------------------------------+
//| 将服务器时间转换为北京时间                                        |
//+------------------------------------------------------------------+
datetime ServerTimeToBeijing(datetime serverTime)
{
   // 北京时间 = 服务器时间 - 服务器与GMT的偏移 + 8小时
   return serverTime - g_GMT_Offset + 8 * 3600;
}

//+------------------------------------------------------------------+
//| 初始化新仓位（接管）                                               |
//+------------------------------------------------------------------+
void InitializeNewPosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;

   PositionInfo pos;
   ZeroMemory(pos);
   pos.ticket = ticket;
   pos.symbol = PositionGetString(POSITION_SYMBOL);
   pos.entry = PositionGetDouble(POSITION_PRICE_OPEN);
   pos.initialVolume = PositionGetDouble(POSITION_VOLUME);
   pos.state = STATE_NEW;
   pos.l1Closed = false;
   pos.l2Closed = false;
   pos.l3Closed = false;
   pos.trailingActive = false;
   pos.paused = false;
   pos.initTime = TimeCurrent();
   pos.digits = (int)SymbolInfoInteger(pos.symbol, SYMBOL_DIGITS);
   pos.point = SymbolInfoDouble(pos.symbol, SYMBOL_POINT);

   // 确保报价可用
   SymbolSelect(pos.symbol, true);

   double currentSL = PositionGetDouble(POSITION_SL);
   int posType = (int)PositionGetInteger(POSITION_TYPE);

   if(currentSL != 0)
   {
      pos.initialSL = currentSL;
      if(posType == POSITION_TYPE_BUY)
         pos.rDistance = pos.entry - currentSL;
      else
         pos.rDistance = currentSL - pos.entry;
      if(pos.rDistance <= pos.point * 10)
      {
         Print("人工止损距离过小，放弃管理 #", ticket);
         return;
      }
      Print("✅ 检测到人工止损，R=", pos.rDistance/pos.point, "点");
   }
   else
   {
      // 获取开仓服务器时间，并转换为北京时间
      datetime openTime = (datetime)(long)PositionGetInteger(POSITION_TIME);
      datetime beijingTime = ServerTimeToBeijing(openTime);
      MqlDateTime dt;
      TimeToStruct(beijingTime, dt);
      int hour = dt.hour;
      double mult;
      if(hour >= 8 && hour < 15)
         mult = InpATRMult_Asia;
      else if(hour >= 15 && hour < 20)
         mult = InpATRMult_Europe;
      else
         mult = InpATRMult_US;

      Print("开仓服务器时间:", TimeToString(openTime), " 北京时间:", TimeToString(beijingTime), " 时段:", hour, " 乘数:", mult);

      double wAtr = GetWeightedAverageATR(pos.symbol);
      if(wAtr <= 0)
      {
         Print("加权ATR获取失败，放弃管理 #", ticket);
         return;
      }
      double atrDist = wAtr * mult;
      double tickValue = SymbolInfoDouble(pos.symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(pos.symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0) tickValue = 1.0;
      if(tickSize <= 0)  tickSize = pos.point;
      // 每1手每tickSize价格变动 = tickValue美元 → 反推价格距离
      double minStopUSD_Price = InpMinStop_AbsUSD / tickValue * tickSize;
      double minStopATR_Price = InpMinStop_ATR_Ratio * wAtr;
      double minStopFinal = MathMax(minStopATR_Price, minStopUSD_Price);
      double slDistance = MathMax(atrDist, minStopFinal);
      pos.rDistance = slDistance;

      if(posType == POSITION_TYPE_BUY)
         pos.initialSL = pos.entry - slDistance;
      else
         pos.initialSL = pos.entry + slDistance;
      pos.initialSL = NormalizeDouble(pos.initialSL, pos.digits);

      if(!ModifyPosition(ticket, pos.initialSL, 0))
      {
         Print("设置初始止损失败，放弃管理 #", ticket);
         return;
      }
      Print("✅ 自动初始止损，R=", slDistance/pos.point, "点，时段倍数=", mult);
   }

   pos.slFloor = (posType == POSITION_TYPE_BUY) ? 0 : 999999;
   pos.lastSetSL = pos.initialSL;
   pos.trailingHighest = pos.entry;

   int size = ArraySize(ManagedPositions);
   ArrayResize(ManagedPositions, size+1);
   ManagedPositions[size] = pos;
   SaveState(ManagedPositions[size]);
   Print("✅ 订单 #", ticket, " 加入管理列表");
}

//+------------------------------------------------------------------+
//| 从终端全局变量恢复仓位状态（EA重启/重连时）                        |
//+------------------------------------------------------------------+
bool RestorePositionFromGlobal(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(!HasState(ticket)) return false;

   PositionInfo pos;
   ZeroMemory(pos);
   pos.ticket = ticket;
   pos.symbol = PositionGetString(POSITION_SYMBOL);
   pos.entry = PositionGetDouble(POSITION_PRICE_OPEN);
   pos.digits = (int)SymbolInfoInteger(pos.symbol, SYMBOL_DIGITS);
   pos.point = SymbolInfoDouble(pos.symbol, SYMBOL_POINT);
   pos.initTime = (datetime)(long)PositionGetInteger(POSITION_TIME);

   // 恢复的是"真实初始状态"，不用当前SL反推
   pos.rDistance       = GlobalVariableGet(GVName(ticket, "R"));
   pos.initialVolume   = GlobalVariableGet(GVName(ticket, "VOL"));
   pos.initialSL       = GlobalVariableGet(GVName(ticket, "ISL"));
   pos.trailingHighest = GlobalVariableGet(GVName(ticket, "HIGH"));
   pos.slFloor         = GlobalVariableGet(GVName(ticket, "FLOOR"));
   pos.lastSetSL       = GlobalVariableGet(GVName(ticket, "LSL"));
   int flags = (int)GlobalVariableGet(GVName(ticket, "FLAGS"));
   pos.l1Closed       = (flags & PM_FLAG_L1) != 0;
   pos.l2Closed       = (flags & PM_FLAG_L2) != 0;
   pos.l3Closed       = (flags & PM_FLAG_L3) != 0;
   pos.trailingActive = (flags & PM_FLAG_TRAIL) != 0;
   pos.paused         = (flags & PM_FLAG_PAUSED) != 0;

   if(pos.rDistance <= 0 || pos.initialVolume <= 0)
   {
      Print("恢复失败：持久化数据异常，转为重新接管 #", ticket);
      DeleteState(ticket);
      return false;
   }

   if(pos.l3Closed) pos.state = STATE_L3_DONE;
   else if(pos.l2Closed) pos.state = STATE_L2_DONE;
   else if(pos.l1Closed) pos.state = STATE_L1_DONE;
   else pos.state = STATE_NEW;
   if(pos.trailingActive) pos.state = STATE_TRAILING_ACTIVE;

   SymbolSelect(pos.symbol, true);

   int size = ArraySize(ManagedPositions);
   ArrayResize(ManagedPositions, size+1);
   ManagedPositions[size] = pos;
   Print("✅ 恢复仓位 #", ticket, " R=", pos.rDistance/pos.point, "点 初始手数=", pos.initialVolume,
         " 层[", pos.l1Closed, pos.l2Closed, pos.l3Closed, "] 追踪:", pos.trailingActive,
         pos.paused ? " [已暂停:手动干预]" : "");
   return true;
}

//+------------------------------------------------------------------+
//| 手动止损检测与处理                                                |
//| 返回 true 表示本Tick应跳过后续管理（暂停模式）                      |
//+------------------------------------------------------------------+
bool HandleManualSLChange(PositionInfo &pos, int posType, double currentSL)
{
   if(pos.paused) return true;

   double tol = pos.point * 0.5;

   // 情况1：止损被手动删除 —— 无论什么模式都强制恢复（裸仓不可接受）
   if(currentSL == 0 && pos.lastSetSL != 0)
   {
      Print("⚠️ 检测到止损被手动删除 #", pos.ticket, "，强制恢复保护止损 ", pos.lastSetSL);
      if(ModifyPosition(pos.ticket, pos.lastSetSL, 0))
         SaveState(pos);
      return false;
   }

   // 情况2：止损被手动移动
   if(pos.lastSetSL != 0 && currentSL != 0 && MathAbs(currentSL - pos.lastSetSL) > tol)
   {
      bool tightened = (posType == POSITION_TYPE_BUY) ? (currentSL > pos.lastSetSL)
                                                      : (currentSL < pos.lastSetSL);
      switch(InpManualSLMode)
      {
         case MANUAL_SL_RESPECT:
            if(tightened)
            {
               // 手动收紧 → 作为新的底线，EA之后只会继续收紧，绝不放松回去
               if(posType == POSITION_TYPE_BUY)
                  pos.slFloor = MathMax(pos.slFloor, currentSL);
               else
                  pos.slFloor = MathMin(pos.slFloor, currentSL);
               Print("✋ 检测到手动收紧止损 #", pos.ticket, " → ", currentSL,
                     "，已设为新底线，EA不会放松");
            }
            else
            {
               Print("⚠️ 检测到手动放松止损 #", pos.ticket, " ", pos.lastSetSL, " → ", currentSL,
                     "，风险敞口已扩大！EA接受该止损，但R基准与分层计划不变");
            }
            pos.lastSetSL = currentSL;
            SaveState(pos);
            break;

         case MANUAL_SL_OVERRIDE:
            Print("🔒 接管模式：手动止损修改被撤销 #", pos.ticket, " ", currentSL, " → ", pos.lastSetSL);
            ModifyPosition(pos.ticket, pos.lastSetSL, 0);
            break;

         case MANUAL_SL_PAUSE:
            pos.paused = true;
            pos.lastSetSL = currentSL;
            SaveState(pos);
            Print("⏸️ 检测到手动干预 #", pos.ticket, "，该仓位EA管理已暂停（重新加载EA可恢复接管）");
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 管理单个仓位（直接引用数组元素，避免状态丢失）                      |
//+------------------------------------------------------------------+
void ManagePosition(int idx)
{
   if(idx < 0 || idx >= ArraySize(ManagedPositions)) return;
   if(!PositionSelectByTicket(ManagedPositions[idx].ticket))
   {
      DeleteState(ManagedPositions[idx].ticket);
      RemovePosition(idx);
      return;
   }
   PositionInfo pos = ManagedPositions[idx];
   if(pos.rDistance <= 0) return;

   int posType = (int)PositionGetInteger(POSITION_TYPE);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentVolume = PositionGetDouble(POSITION_VOLUME);
   double currentPrice = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(pos.symbol, SYMBOL_BID) :
                         SymbolInfoDouble(pos.symbol, SYMBOL_ASK);
   double profitInR = (posType == POSITION_TYPE_BUY) ?
                      (currentPrice - pos.entry) / pos.rDistance :
                      (pos.entry - currentPrice) / pos.rDistance;

   //===== 手动止损检测（在所有管理动作之前） =====
   bool skipManage = HandleManualSLChange(pos, posType, currentSL);
   ManagedPositions[idx] = pos;
   if(skipManage) return;
   currentSL = PositionGetDouble(POSITION_SL);

   //===== 点差保护：异常点差时暂缓所有主动动作 =====
   if(SpreadTooWide(pos.symbol)) return;

   bool needUpdate = false;
   bool acted = false;   // 本Tick是否已执行平仓
   double newSL = 0;

   //===== 第一层平仓 =====
   if(!pos.l1Closed && profitInR >= InpL1_TriggerR && !acted)
   {
      double closeVol = CalculatePartialVolumeUp(pos.symbol, pos.initialVolume, InpL1_Pct, currentVolume);
      if(closeVol > 0 && closeVol <= currentVolume)
      {
         if(PartialClose(pos.ticket, closeVol))
         {
            pos.l1Closed = true;
            pos.state = STATE_L1_DONE;
            pos.l1Price = (posType == POSITION_TYPE_BUY) ? pos.entry + InpL1_TriggerR * pos.rDistance : pos.entry - InpL1_TriggerR * pos.rDistance;
            pos.l1Volume = closeVol;
            if(currentVolume - closeVol > 0)
            {
               newSL = pos.entry - InpL1_NewSL_R * pos.rDistance;
               if(posType == POSITION_TYPE_SELL) newSL = pos.entry + InpL1_NewSL_R * pos.rDistance;
               newSL = NormalizeDouble(newSL, pos.digits);
               if(ModifyPosition(pos.ticket, newSL, 0))
                  pos.lastSetSL = newSL;
            }
            acted = true;
            needUpdate = true;
            Print("📉 第一层平仓完成，平仓 ", closeVol, " 手，剩余 ", currentVolume-closeVol, " 手");
         }
      }
   }

   //===== 第二层平仓 =====
   if(!pos.l2Closed && pos.l1Closed && profitInR >= InpL2_TriggerR && !acted)
   {
      double closeVol = CalculatePartialVolumeUp(pos.symbol, pos.initialVolume, InpL2_Pct, currentVolume);
      if(closeVol > 0 && closeVol <= currentVolume)
      {
         if(PartialClose(pos.ticket, closeVol))
         {
            pos.l2Closed = true;
            pos.state = STATE_L2_DONE;
            pos.l2Price = (posType == POSITION_TYPE_BUY) ? pos.entry + InpL2_TriggerR * pos.rDistance : pos.entry - InpL2_TriggerR * pos.rDistance;
            pos.l2Volume = closeVol;
            acted = true;
            needUpdate = true;
            Print("📉 第二层平仓完成，平仓 ", closeVol, " 手，剩余 ", currentVolume-closeVol, " 手");
         }
      }
   }

   //===== 第三层平仓 =====
   if(!pos.l3Closed && pos.l2Closed && profitInR >= InpL3_TriggerR && !acted)
   {
      double closeVol = CalculatePartialVolumeUp(pos.symbol, pos.initialVolume, InpL3_Pct, currentVolume);
      if(closeVol > 0 && closeVol <= currentVolume)
      {
         if(PartialClose(pos.ticket, closeVol))
         {
            pos.l3Closed = true;
            pos.state = STATE_L3_DONE;
            pos.l3Price = (posType == POSITION_TYPE_BUY) ? pos.entry + InpL3_TriggerR * pos.rDistance : pos.entry - InpL3_TriggerR * pos.rDistance;
            pos.l3Volume = closeVol;
            double atr = GetStableATR(pos.symbol);
            if(atr <= 0) atr = pos.rDistance / 1.5;
            double offsetPrice = InpL3_FinalOffset_ATR_Ratio * atr;
            double baseSL = (posType == POSITION_TYPE_BUY) ? pos.entry + offsetPrice : pos.entry - offsetPrice;
            baseSL = NormalizeDouble(baseSL, pos.digits);
            // 保本底线只收紧，不覆盖已有更紧的底线（如手动收紧线）
            if(posType == POSITION_TYPE_BUY)
               pos.slFloor = MathMax(pos.slFloor, baseSL);
            else
               pos.slFloor = MathMin(pos.slFloor, baseSL);
            if(currentVolume - closeVol > 0)
            {
               if(ModifyPosition(pos.ticket, pos.slFloor, 0))
                  pos.lastSetSL = pos.slFloor;
            }
            acted = true;
            needUpdate = true;
            Print("📉 第三层平仓完成，平仓 ", closeVol, " 手，剩余 ", currentVolume-closeVol, " 手，底线止损: ", pos.slFloor);
         }
      }
   }

   //===== 追踪止损启动 =====
   if(!pos.trailingActive && profitInR >= InpTrailing_StartR && InpEnableTrailing && currentVolume > 0)
   {
      pos.trailingActive = true;
      pos.state = STATE_TRAILING_ACTIVE;
      pos.trailingHighest = currentPrice;
      double atr = GetStableATR(pos.symbol);
      if(atr <= 0) atr = pos.rDistance / 1.5;
      double k = GetDynamicK(profitInR);
      newSL = pos.trailingHighest - k * atr;
      if(posType == POSITION_TYPE_SELL) newSL = pos.trailingHighest + k * atr;
      newSL = NormalizeDouble(newSL, pos.digits);
      // 底线钳制（保本线/手动收紧线），任何时候都不放松到底线以下
      if(posType == POSITION_TYPE_BUY && newSL < pos.slFloor) newSL = pos.slFloor;
      if(posType == POSITION_TYPE_SELL && newSL > pos.slFloor) newSL = pos.slFloor;
      if(ModifyPosition(pos.ticket, newSL, 0))
      {
         pos.lastSetSL = newSL;
         Print("🏁 追踪止损启动，初始止损 ", newSL, " K=", k);
      }
      needUpdate = true;
   }

   //===== 追踪止损更新 =====
   if(pos.trailingActive && InpEnableTrailing && currentVolume > 0)
   {
      bool moved = false;
      if(posType == POSITION_TYPE_BUY && currentPrice > pos.trailingHighest + pos.point*0.1)
      {
         pos.trailingHighest = currentPrice;
         moved = true;
      }
      else if(posType == POSITION_TYPE_SELL && currentPrice < pos.trailingHighest - pos.point*0.1)
      {
         pos.trailingHighest = currentPrice;
         moved = true;
      }
      if(moved)
      {
         needUpdate = true;   // 最高价已更新，必须保存（v5.12会丢失此更新）
         double atr = GetStableATR(pos.symbol);
         if(atr <= 0) atr = pos.rDistance / 1.5;
         double k = GetDynamicK(profitInR);
         newSL = pos.trailingHighest - k * atr;
         if(posType == POSITION_TYPE_SELL) newSL = pos.trailingHighest + k * atr;
         newSL = NormalizeDouble(newSL, pos.digits);
         if(posType == POSITION_TYPE_BUY && newSL < pos.slFloor) newSL = pos.slFloor;
         if(posType == POSITION_TYPE_SELL && newSL > pos.slFloor) newSL = pos.slFloor;
         double minMovePrice = atr * InpMinMoveATR_Ratio;
         bool canMove = false;
         if(posType == POSITION_TYPE_BUY && newSL - currentSL > minMovePrice)
            canMove = true;
         else if(posType == POSITION_TYPE_SELL && currentSL - newSL > minMovePrice)
            canMove = true;
         if(canMove && ModifyPosition(pos.ticket, newSL, 0))
            pos.lastSetSL = newSL;
      }
   }

   if(needUpdate)
   {
      ManagedPositions[idx] = pos;
      SaveState(pos);
   }
   else
   {
      ManagedPositions[idx] = pos;
   }
}

//+------------------------------------------------------------------+
//| 从管理数组移除仓位                                                |
//+------------------------------------------------------------------+
void RemovePosition(int index)
{
   int size = ArraySize(ManagedPositions);
   if(index >= 0 && index < size)
   {
      for(int i=index; i<size-1; i++)
         ManagedPositions[i] = ManagedPositions[i+1];
      ArrayResize(ManagedPositions, size-1);
   }
}

//+------------------------------------------------------------------+
//| 判断是否已在管理列表中                                            |
//+------------------------------------------------------------------+
bool IsPositionManaged(ulong ticket)
{
   for(int i=0; i<ArraySize(ManagedPositions); i++)
      if(ManagedPositions[i].ticket == ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
//| 面板绘制与更新（对象复用版，不再每秒删建数百对象）                  |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   string bg = prefix + "bg";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 700);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 450);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'25,30,45');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   CreateLabel("title", "通用仓位管理器 v5.13", 15, 35, clrWhite, 12);
   CreateLabel("time", "", 15, 55, clrGray, 9);
   CreateLabel("stats", "", 15, 75, clrCyan, 10);
   CreateLabel("sep_main", "────────────────────────────────────────────────────────────────────────────", 15, 90, clrGray, 8);
}

void DeletePanelRow(int rowIdx)
{
   string base = prefix + "row" + IntegerToString(rowIdx);
   ObjectDelete(0, base+"_bg");
   ObjectDelete(0, base+"_line1");
   ObjectDelete(0, base+"_line2");
   ObjectDelete(0, base+"_line4");
   ObjectDelete(0, base+"_details");
   ObjectDelete(0, base+"_bar_bg");
   ObjectDelete(0, base+"_bar_fill");
   ObjectDelete(0, base+"_marker0");
   ObjectDelete(0, base+"_marker1");
   ObjectDelete(0, base+"_marker2");
   ObjectDelete(0, base+"_label0");
   ObjectDelete(0, base+"_label1");
   ObjectDelete(0, base+"_label2");
}

void EnsureRect(string name, int x, int y, int xsize, int ysize, color bgColor)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, xsize);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, ysize);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
}

void UpdateDashboard()
{
   if(!InpShowPanel) return;
   datetime now = TimeCurrent();
   ObjectSetString(0, prefix+"time", OBJPROP_TEXT, TimeToString(now, TIME_MINUTES|TIME_SECONDS));
   double totalProfit = 0;
   int activeCount = 0;
   for(int i=0; i<ArraySize(ManagedPositions); i++)
      if(PositionSelectByTicket(ManagedPositions[i].ticket))
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT);
         activeCount++;
      }
   string statsText = StringFormat("管理订单: %d   浮动盈亏: %.2f USD", activeCount, totalProfit);
   ObjectSetString(0, prefix+"stats", OBJPROP_TEXT, statsText);

   int row = 0;
   int yBase = 110;
   const int rowHeight = 85;
   for(int i=0; i<ArraySize(ManagedPositions); i++)
   {
      if(!PositionSelectByTicket(ManagedPositions[i].ticket)) continue;
      PositionInfo pos = ManagedPositions[i];
      int posType = (int)PositionGetInteger(POSITION_TYPE);
      double curPrice = (posType==POSITION_TYPE_BUY) ?
                        SymbolInfoDouble(pos.symbol, SYMBOL_BID) :
                        SymbolInfoDouble(pos.symbol, SYMBOL_ASK);
      double profitR = (pos.rDistance > 0) ? ((posType==POSITION_TYPE_BUY) ?
                       (curPrice-pos.entry)/pos.rDistance :
                       (pos.entry-curPrice)/pos.rDistance) : 0;
      double profitUSD = PositionGetDouble(POSITION_PROFIT);
      double currSL = PositionGetDouble(POSITION_SL);
      string dir = (posType==POSITION_TYPE_BUY) ? "▲" : "▼";
      color dirColor = (posType==POSITION_TYPE_BUY) ? clrGreen : clrRed;
      string stateStr = "";
      switch(pos.state)
      {
         case STATE_NEW: stateStr="新仓位"; break;
         case STATE_L1_DONE: stateStr="[L1已平]"; break;
         case STATE_L2_DONE: stateStr="[L2已平]"; break;
         case STATE_L3_DONE: stateStr="[L3已平]"; break;
         case STATE_TRAILING_ACTIVE: stateStr="[追踪中]"; break;
         case STATE_FINISHED: stateStr="[已完成]"; break;
      }
      if(pos.paused) stateStr += " [手动干预-已暂停]";
      string slType = "";
      if(pos.paused) slType = "手动";
      else if(pos.state == STATE_TRAILING_ACTIVE) slType = "追踪";
      else if(pos.state == STATE_L3_DONE) slType = "底线";
      else if(pos.state == STATE_L1_DONE) slType = "L1后";
      else slType = "初始";

      string rowBase = prefix + "row" + IntegerToString(row);
      int y = yBase + row*rowHeight;
      EnsureRect(rowBase+"_bg", 15, y, 670, rowHeight-2, C'30,35,50');

      string line1 = StringFormat("%s %s  %.2f手  开:%.2f  现:%.2f  盈:%+.1fR (%+.2f USD) %s",
                         dir, pos.symbol, pos.initialVolume, pos.entry, curPrice, profitR, profitUSD, stateStr);
      CreateLabel("row" + IntegerToString(row) + "_line1", line1, 25, y + 5, dirColor, 10);

      string line2 = "";
      if(pos.l1Closed) line2 = StringFormat("L1 %.2f/%.2f手", pos.l1Price, pos.l1Volume);
      if(pos.l2Closed) line2 += StringFormat("  L2 %.2f/%.2f手", pos.l2Price, pos.l2Volume);
      if(pos.l3Closed) line2 += StringFormat("  L3 %.2f/%.2f手", pos.l3Price, pos.l3Volume);
      if(line2 == "") line2 = "无已平仓";
      CreateLabel("row" + IntegerToString(row) + "_line2", line2, 25, y + 25, clrLightBlue, 9);

      double maxR = 1.5;
      double progress = MathMin(profitR / maxR, 1.0);
      if(progress < 0) progress = 0;
      int barWidth = 450;
      int fillWidth = (int)(barWidth * progress);
      EnsureRect(rowBase+"_bar_bg", 25, y + 45, barWidth, 6, C'50,55,70');
      if(fillWidth > 0)
         EnsureRect(rowBase+"_bar_fill", 25, y + 45, fillWidth, 6, clrGreen);
      else
         ObjectDelete(0, rowBase+"_bar_fill");

      int mark_x0 = 25 + (int)(barWidth * (InpL1_TriggerR / maxR));
      int mark_x1 = 25 + (int)(barWidth * (InpL2_TriggerR / maxR));
      int mark_x2 = 25 + (int)(barWidth * (InpL3_TriggerR / maxR));
      CreateLabel("row" + IntegerToString(row) + "_marker0", "●", mark_x0-4, y + 43, clrYellow, 10);
      CreateLabel("row" + IntegerToString(row) + "_marker1", "●", mark_x1-4, y + 43, clrYellow, 10);
      CreateLabel("row" + IntegerToString(row) + "_marker2", "●", mark_x2-4, y + 43, clrYellow, 10);
      CreateLabel("row" + IntegerToString(row) + "_label0", DoubleToString(InpL1_TriggerR,1)+"R", mark_x0-12, y + 55, clrGray, 8);
      CreateLabel("row" + IntegerToString(row) + "_label1", DoubleToString(InpL2_TriggerR,1)+"R", mark_x1-12, y + 55, clrGray, 8);
      CreateLabel("row" + IntegerToString(row) + "_label2", DoubleToString(InpL3_TriggerR,1)+"R", mark_x2-12, y + 55, clrGray, 8);
      string line4 = StringFormat("止损: %.2f (%s)", currSL, slType);
      CreateLabel("row" + IntegerToString(row) + "_line4", line4, 25 + barWidth + 10, y + 48, clrGray, 9);

      double currentVol = PositionGetDouble(POSITION_VOLUME);
      double l1PlanVol = CalculatePartialVolumeUp(pos.symbol, pos.initialVolume, InpL1_Pct, currentVol);
      double l2PlanVol = CalculatePartialVolumeUp(pos.symbol, pos.initialVolume, InpL2_Pct, currentVol);
      double l3PlanVol = CalculatePartialVolumeUp(pos.symbol, pos.initialVolume, InpL3_Pct, currentVol);
      double l1PricePlan = (posType == POSITION_TYPE_BUY) ? pos.entry + InpL1_TriggerR * pos.rDistance : pos.entry - InpL1_TriggerR * pos.rDistance;
      double l2PricePlan = (posType == POSITION_TYPE_BUY) ? pos.entry + InpL2_TriggerR * pos.rDistance : pos.entry - InpL2_TriggerR * pos.rDistance;
      double l3PricePlan = (posType == POSITION_TYPE_BUY) ? pos.entry + InpL3_TriggerR * pos.rDistance : pos.entry - InpL3_TriggerR * pos.rDistance;
      string details = StringFormat("计划: L1 %.2f/%.2f手  L2 %.2f/%.2f手  L3 %.2f/%.2f手",
                                    l1PricePlan, l1PlanVol, l2PricePlan, l2PlanVol, l3PricePlan, l3PlanVol);
      CreateLabel("row" + IntegerToString(row) + "_details", details, 25, y + 68, clrLightBlue, 8);
      row++;
      if(row >= 10) break;
   }

   // 只删除多余的旧行，不再每秒全量删建
   for(int r = row; r < g_lastPanelRows; r++)
      DeletePanelRow(r);
   g_lastPanelRows = row;
}

void CreateLabel(string name, string text, int x, int y, color clr, int size)
{
   string full = prefix + name;
   if(ObjectFind(0, full) < 0)
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, full, OBJPROP_TEXT, text);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, full, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
}

//+------------------------------------------------------------------+
//| EA生命周期                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("通用仓位管理器 v5.13 初始化 | 图表: ", _Symbol, " 周期: ", EnumToString((ENUM_TIMEFRAMES)Period()));
   if(Period() != expectedTF)
   {
      Print("❌ 请加载在M15图表上！当前周期: ", EnumToString((ENUM_TIMEFRAMES)Period()));
      return INIT_FAILED;
   }

   // 自动计算服务器与GMT的偏移（秒）
   g_GMT_Offset = (int)(TimeCurrent() - TimeGMT());
   Print("服务器时区自动检测：与GMT偏移 = ", g_GMT_Offset, " 秒 (约 ", g_GMT_Offset/3600, " 小时)");

   ArrayResize(ManagedPositions, 0);
   ArrayResize(ATRSymbols, 0);
   ArrayResize(ATRHandles, 0);
   g_lastPanelRows = 0;

   GetAtrHandle(_Symbol);
   CleanOrphanStates();

   EventSetTimer(1);
   if(InpShowPanel) CreateDashboard();

   // 有持久化状态的仓位：无条件恢复（保证重启前后行为一致）
   // 无状态的存量仓位：仅在 InpTakeoverExisting=true 时接管
   int total = PositionsTotal();
   for(int i=0; i<total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!InpManageAnyMagic && magic != InpMagicNumber) continue;
      if(RestorePositionFromGlobal(ticket)) continue;
      if(InpTakeoverExisting)
         InitializeNewPosition(ticket);
   }
   Print("✅ 初始化完成，当前管理订单数: ", ArraySize(ManagedPositions));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i=0; i<ArraySize(ATRHandles); i++)
      if(ATRHandles[i] != INVALID_HANDLE)
         IndicatorRelease(ATRHandles[i]);
   if(InpShowPanel) ObjectsDeleteAll(0, prefix);
   // 注意：不删除全局变量，状态需要跨重启保留
   Print("EA已卸载, 原因: ", reason);
}

void OnTimer()
{
   for(int i = ArraySize(ManagedPositions) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(ManagedPositions[i].ticket))
      {
         DeleteState(ManagedPositions[i].ticket);
         RemovePosition(i);
      }
   if(InpShowPanel) UpdateDashboard();
}

void OnTrade()
{
   for(int i = ArraySize(ManagedPositions) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(ManagedPositions[i].ticket))
      {
         DeleteState(ManagedPositions[i].ticket);
         RemovePosition(i);
      }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(IsPositionManaged(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!InpManageAnyMagic && magic != InpMagicNumber) continue;
      if(!RestorePositionFromGlobal(ticket))
         InitializeNewPosition(ticket);
   }
   if(InpShowPanel) UpdateDashboard();
}

void OnTick()
{
   for(int i=ArraySize(ManagedPositions)-1; i>=0; i--)
   {
      if(!PositionSelectByTicket(ManagedPositions[i].ticket))
      {
         DeleteState(ManagedPositions[i].ticket);
         RemovePosition(i);
         continue;
      }
      ManagePosition(i);
   }
}
//+------------------------------------------------------------------+
