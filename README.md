# XAU_Scalper — XAUUSD 高频剥头皮 EA（MT5）

> **状态：代码尚未经过 MetaEditor 编译，也没有跑过任何回测。**
> 它是在没有 MT5 的 Linux 环境里写的。第一步请在 MetaEditor 里按 F7 编译，把报错（如果有）贴回来修。
> 默认参数只是合理起点，不代表有正期望。

| 文件 | 用途 |
|---|---|
| `XAU_Scalper.mq5` | EA 主文件（单文件，CTrade） |
| `backtest/single_test.ini` | 单次真实 tick 回测配置 |
| `backtest/optimize_wfo_template.ini` | Walk-Forward 单窗口模板 |
| `backtest/XAU_Scalper_opt.set` | 8 个优化参数及范围 |
| `backtest/run_mt5.sh` / `run_wfo.sh` | Mac 上无人值守批量运行 |

## 0. 我采用的假设

1. **所有价格距离参数的单位是美元价格**（如 `InpMaxSpread=0.35`），不是“点”。EA 用 `SYMBOL_POINT` 换算，所以 2 位和 3 位报价商用同一套参数。
2. **时段用服务器时间**，默认值按 MetaQuotes-Demo（EET，GMT+2/+3）设置。Gate TradFi 的服务器时区如果不同，必须改时段。
3. **对冲账户**。净额账户上 EA 自动把最大持仓数限制为 1。
4. **信号在每根 M1 收线后评估一次**，不是逐 tick 触发。频率靠偏离阈值 `InpMR_DevK` 调节；每天 20–100 笔需要较低的 k 和三个时段全开，默认参数预计偏少。
5. **凯利 ≤ 0（统计上没有优势）时用固定最小手数继续交易**，而不是停止。这样能继续积累样本，但意味着亏损策略不会自己停下，靠日亏损和总开关兜底。
6. **日亏损和净值回撤按整个账户计算**（含其它 EA 和手动单）；平仓只平本 Magic 的单。
7. 新闻默认过滤 USD 的**全部高影响事件**。`InpNewsKeywords` 匹配的是日历事件名，事件名随终端语言变化，所以默认留空。

## 1. 策略逻辑

**均值回归（主逻辑）。** 最近两根 M1 中任一根的影线刺穿 `EMA ± k×ATR`，随后一根反向收线（阳线且收盘高于前收，做空相反），RSI 到过超买超卖区，并且收盘价离 EMA 仍有至少 `0.3×ATR` 的空间。止盈取“回到 EMA 的距离”，上限 `1.5×ATR`；止损 `1.8×ATR`。两者都有最小美元下限，并且不小于 `STOPS_LEVEL + 点差`。

**动量突破（默认关）。** 快慢 ATR 之比 ≥ 1.3 时，M1 收盘突破前 20 根的高低点且实体 ≥ `0.8×ATR` 才入场，不做逆势突破。

**趋势过滤。** M5 和 M15 的 EMA20/50 同向且 M15 的 ADX ≥ 25 判为单边。默认模式下单边时只允许顺势方向的回调单；也可设为单边时暂停全部均值回归。

**优势边界。** 这个策略赚的是震荡市里短时过度偏离后的回吐。单笔目标约 1–2 美元，点差加滑点常在 0.2–0.4 美元，成本占目标的 15–30%，所以净优势很薄，对执行质量极度敏感。

**失效场景。**
- 单边趋势和数据行情：偏离后继续偏离。靠趋势过滤、波动比上限和新闻过滤缓解，无法消除。
- 点差扩大或滑点变差：0.1 美元的额外成本就可能把正期望变成负的。
- 经纪商限制剥头皮（最小持仓时间、延迟成交、B-book 不对称滑点）。
- 波动率结构变化：金价水平变了，固定的美元下限（最小止损、最大点差）需要跟着调。
- 回测 tick 与实盘 tick 不同源：MetaQuotes-Demo 上有效不代表 Gate 上有效。

## 2. 代码

见 `XAU_Scalper.mq5`。四个模块：信号（`TrendState` / `SignalMeanReversion` / `SignalMomentum`）、过滤（`SessionOK` / `NewsBlocked` / `CanOpen`）、风控（`CheckRisk` / `KellyF` / `RegisterTrade`）、执行（`OpenTrade` / `ManagePositions`）。

几个需要知道的行为：

- **凯利实际上几乎总是被 0.5% 上限截断。** 例如胜率 55%、盈亏比 1 时凯利 f=0.10，乘 0.25 是 2.5%，远高于 0.5%。所以实际效果是：有优势时每笔风险 0.5%，没优势时最小手数。
- **总开关**触发后全平、写入终端全局变量、移除 EA。之后 EA 拒绝启动，直到把 `InpResetKillSwitch` 设为 true 加载一次（峰值重置为当前净值），再改回 false。出入金会扭曲净值峰值，出金后请手动重置。
- **无止损的持仓**（个别经纪商不接受开仓时带 SL）会在下一个 tick 补设，补不上立即平仓。
- **超时（TIMEOUT）不重试**，因为订单可能已成交，重发会重复下单。只有重新报价、价格变化、繁忙、断线才重试。
- **CSV 日志**在 `MQL5/Files/XAU_Scalper_<Magic>_<品种>.csv`（回测时在测试代理的 Files 目录），优化时不写。`CLOSE` 行的 `req_price` 是入场价，`fill_price` 是出场价。
- **回测里经济日历不可用**（MT5 的限制）。先在实盘图表上设 `InpNewsExportDays=400` 加载一次，EA 会把历史事件导出到公共文件夹，回测时自动读取。不导出的话回测不过滤新闻，结果偏乐观或偏悲观都有可能。

## 3. 参数说明

| 组 | 参数 | 默认 | 说明 |
|---|---|---|---|
| 基本 | `InpMagic` | 20261110 | 每个实例不同 |
| | `InpSignalTF` | M1 | 信号周期 |
| 均值回归 | `InpEmaPeriod` / `InpAtrPeriod` | 20 / 14 | 均值与波动 |
| | `InpMR_DevK` | 1.8 | 偏离阈值，越小越频繁 |
| | `InpMR_MinRoomATR` | 0.3 | 入场时距均值的最小空间 |
| | `InpMR_UseRSI` / `InpRsiPeriod` / `InpMR_RsiLevel` | true / 7 / 30 | 超卖线，超买线 = 100 − 该值 |
| | `InpMR_MaxVolRatio` | 2.5 | 波动比过高时暂停 |
| | `InpMR_SL_ATR` / `InpMR_TP_ATR` / `InpMR_TPToMean` | 1.8 / 1.5 / true | 止损、止盈上限、止盈取到均值 |
| 动量 | `InpMO_Enable` | false | 开关 |
| | `InpMO_Lookback` / `InpMO_BodyATR` / `InpMO_MinVolRatio` | 20 / 0.8 / 1.3 | 通道、实体、波动门槛 |
| | `InpMO_SL_ATR` / `InpMO_TP_ATR` | 1.5 / 2.0 | |
| 趋势 | `InpTrendMode` | 只做顺势 | 关闭 / 只做顺势 / 单边暂停 |
| | `InpTrendFast` / `InpTrendSlow` / `InpTrendADX` | 20 / 50 / 25 | M5 + M15 |
| 执行 | `InpMaxSpread` | 0.35 | 美元价格 |
| | `InpDeviation` / `InpSlipWarn` | 0.20 / 0.10 | 允许滑点 / 告警阈值 |
| | `InpMinSecBetween` / `InpSignalValidSec` | 20 / 10 | 开仓间隔 / 信号等待点差恢复的时间 |
| | `InpMaxRetries` / `InpRetryDelayMs` | 3 / 250 | |
| 时段 | 亚盘 / 欧盘 / 美盘 | 03:00–08:30 / 10:15–15:15 / 16:45–21:30 | 服务器时间，各有开关 |
| | `InpFridayStopHour` | 21 | |
| 新闻 | `InpNewsBeforeMin` / `InpNewsAfterMin` | 15 / 15 | |
| | `InpNewsClosePos` | false | 进入窗口时平仓 |
| 仓位 | `InpKellyFraction` | 0.25 | 0.25–0.5 |
| | `InpKellyLookback` / `InpKellyMinTrades` | 100 / 30 | |
| | `InpFixedLot` | 0.01 | 样本不足时 |
| | `InpMaxRiskPct` | 0.5 | 单笔硬上限 |
| | `InpCommissionPerLot` | 0 | 每手往返手续费，只用于风险计算 |
| 止损管理 | `InpMinSL` / `InpMinTP` | 1.00 / 0.80 | 美元价格下限 |
| | `InpUseBE` / `InpBE_TrigATR` / `InpBE_Offset` | true / 0.8 / 0.05 | 保本 |
| | `InpUseTrail` / `InpTrail_StartATR` / `InpTrail_DistATR` | false / 1.0 / 0.8 | 移动止损 |
| | `InpMaxHoldSec` | 600 | 时间止损 |
| 账户风控 | `InpDailyLossPct` | 3.0 | |
| | `InpMaxConsecLoss` / `InpPauseMinutes` | 4 / 30 | |
| | `InpMaxPositions` / `InpMaxTotalLots` | 2 / 1.0 | |
| | `InpMaxEquityDD` | 10.0 | 总开关 |
| | `InpMinMarginLevel` | 300 | |
| 优化 | `InpOptMinTrades` | 200 | 少于此数 OnTester 返回 0 |

## 4. 回测 / 优化 / Walk-Forward

### 为什么必须用真实 tick

“1 分钟 OHLC”模式每根 K 线只有 4 个价格。这个 EA 的止损和止盈距离（1–3 美元）与一根 M1 的振幅同量级，经常同一根 K 线内两者都被触及，测试器只能猜先后顺序。点差也是固定的，看不到数据前后的点差跳升，而点差过滤正是策略的核心。“每个 tick（生成）”同样是从 M1 插值出来的假路径。只有“基于真实 tick 的每个 tick”用经纪商记录的买卖价和真实点差。

### 计入成本

- **点差**：真实 tick 模式自带。
- **滑点**：测试器“延迟”选随机延迟（ini 里 `ExecutionMode=-1`）。零延迟的结果不可信。
- **手续费**：MetaQuotes-Demo 的黄金通常没有手续费。要模拟 Gate 的费率，在测试器设置里配置自定义手续费，或者建一个自定义品种设好手续费后导入 tick。同时把 `InpCommissionPerLot` 填上。
- **压力测试**：最终参数再用固定 100ms、300ms 延迟各跑一次。延迟一加就亏的参数不能上实盘。

### 值得优化的参数

| 参数 | 范围 | 步长 |
|---|---|---|
| `InpMR_DevK` | 1.2 – 2.6 | 0.2 |
| `InpMR_SL_ATR` | 1.0 – 3.0 | 0.25 |
| `InpMR_TP_ATR` | 0.6 – 2.4 | 0.2 |
| `InpEmaPeriod` | 10 – 50 | 5 |
| `InpMR_RsiLevel` | 20 – 40 | 5 |
| `InpTrendADX` | 18 – 36 | 3 |
| `InpMaxHoldSec` | 120 – 1200 | 120 |
| `InpMaxSpread` | 0.15 – 0.50 | 0.05 |

组合数约 600 万，用遗传算法。风控参数（日亏损、回撤、单笔风险）不要参与优化。优化标准选“自定义最大值”。

### Walk-Forward

训练 3 个月、测试 1 个月、每次滚动 1 个月。利用 MT5 自带的前推功能：`ForwardMode=4` 加 `ForwardDate`，优化器会把训练段最好的一批参数自动在测试段重跑，输出 `<名字>.xml` 和 `<名字>.forward.xml`。

判断标准：
1. 至少 8–12 个窗口。
2. 看训练段排名前 10% 的参数在测试段的**中位数**表现，不要只看第一名。
3. 测试段盈利因子 > 1.15 的窗口占比 ≥ 60–70%，且没有单个窗口回撤超过你的总开关阈值。
4. 相邻窗口的最优参数应当接近。每个窗口最优值乱跳说明是在拟合噪声。
5. 最优点周围的参数也要盈利（参数高原），孤立的尖峰不要用。

### Mac mini 无人值守

1. 编译：把 `XAU_Scalper.mq5` 放到 `<数据目录>/MQL5/Experts/`，在 MetaEditor 里编译。
2. 把 `XAU_Scalper_opt.set` 放到 `<数据目录>/MQL5/Profiles/Tester/`。
3. 在两个 `.ini` 里填账号、密码、服务器。先手动登录一次，并在测试器里手动跑一次，让终端把 XAUUSD 的真实 tick 下载完。
4. 运行：

```bash
cd backtest
./run_mt5.sh single_test.ini                      # 单次回测
caffeinate -i nohup ./run_wfo.sh 2025-01-01 2026-10-01 > wfo.log 2>&1 &   # 滚动优化
```

`caffeinate -i` 防止 Mac 休眠。脚本里 Wine 和数据目录的路径是官方 Mac 版的常见默认值，**我没法在这里验证**，运行前请 `ls` 确认，或用 `WINE=... WINEPREFIX=...` 覆盖。运行时不能有另一个 MT5 窗口开着。如果 Mac 版终端不响应 `/config`，退路是在 Mac 上装 Windows 虚拟机或租一台 Windows VPS，`.ini` 文件原样可用（`terminal64.exe /config:C:\path\run.ini`）。

真实 tick 的优化很慢：8 个参数的遗传优化，3 个月数据，在 Mac mini 上经 Wine 运行，一个窗口预计要几个小时。

## 5. 实盘前检查清单

**经纪商规则（问客服要书面答复）**
- [ ] 是否允许剥头皮和 EA 高频交易？有没有最小持仓时间（常见 1–3 分钟）？本 EA 很多单会在几十秒内出场。
- [ ] 每日或每秒的订单数、改单数上限。
- [ ] 执行模式是市价执行还是即时执行；是否允许开仓时带 SL/TP。
- [ ] 手续费、隔夜利息、周五是否提高保证金、数据前是否降杠杆。

**品种规格（EA 启动日志第一行会打印）**
- [ ] `SYMBOL_DIGITS`（2 或 3）、`SYMBOL_POINT`、合约大小（100 盎司？）。
- [ ] `STOPS_LEVEL` 和 `FREEZE_LEVEL`。如果 STOPS_LEVEL 换算后 > 0.5 美元，这个策略在该经纪商基本不可行。
- [ ] 最小手数、手数步长。确认 0.01 手在最小止损下的风险不超过净值的 0.5%，否则 EA 一单都不会开。
- [ ] 品种名是否带后缀（`XAUUSD.m`、`GOLD`）。
- [ ] 服务器时区，对应调整三个时段和周五截止时间。

**实测执行质量**
- [ ] 模拟盘挂 2 周，从 CSV 统计：各时段平均点差、平均滑点、不利滑点占比、从信号到成交的延迟。
- [ ] 把实测点差和滑点代回回测，结果仍然为正才继续。
- [ ] 模拟盘成交通常比实盘好。换实盘后先用最小手数跑 2–4 周，再对比一次。

**运行环境**
- [ ] 终端到交易服务器的延迟 < 50ms，否则用靠近服务器的 VPS。Mac mini 家用网络做剥头皮通常不够。
- [ ] 开启“允许算法交易”；经济日历在终端里能正常显示。
- [ ] 故意触发一次每个保护：把 `InpMaxEquityDD` 设成 0.1 看总开关是否全平并拒绝重启；把 `InpDailyLossPct` 设成 0.1 看是否当日停止；断网看重连后状态是否恢复。
- [ ] 多实例时每个 Magic 不同。注意日亏损和总开关是账户级的，一个实例触发，其它实例也会各自触发。
