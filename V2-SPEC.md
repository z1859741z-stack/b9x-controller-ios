# 引擎核心 Plus v2 — 实施 Spec（以此为准，勿凭记忆发挥）

> 背景：v1（Swift 重写）蓝牙能连、状态帧能收，但所有写功能不生效。已用 jadx 反编译原版安卓 App（冰环FLY 0.8.143，`~/workspace/.cache/jadx-out/`）+ 对照开源 Flutter 客户端（`~/workspace/b9x-ios-port/`，只读、勿动）逐字节核对。结论：写不通是多因叠加——帧内容错（0x20 第 9 字节、LED 无校验和、0x57/0x61/0x60/0x32 全错、轮询帧发错）、setRunMode 发 0、原版 App 遗留 Freeze 未清除、LED 校验和缺失。下面按此改。
> 版本保持 **0.8.143（build 227）** 不动；显示名 **引擎核心 Plus**；Bundle ID **com.enginecore.plus**；全工程删光“冰环 / BingHuan / 冰环FLY”字眼。

## 0. 总原则

- 写通路优先于界面。所有开关、模式切换、滑块、步进器、灯效选择：点按后**立即**下发蓝牙命令、界面**立即**反馈，不等 2 秒轮询；状态帧回来后界面实时刷新。
- 本地值优先：用户刚设的值，轮询回来的状态在 3 秒内不许覆盖（或等回显确认后再同步）。
- 两家冲突时以**原版**为准（原版是用户正在用的、针对真机调过的最新实现）；Flutter 只在原版没有时补位。冲突点已在下表注明。
- 性能优先，不压缩包大小；蓝牙频率、轮询、界面效果按性能最优做。
- **不要提交 git**（由主代理统一提交）；不要动 `~/workspace/b9x-ios-port/`；不要碰全能签证书；构建由主代理做。两个子代理分工见 §8，互不改对方文件。

## 1. 协议帧表（B9XProtocol.swift）——逐项改

| 命令 | v2 帧（改后） | 说明 |
|---|---|---|
| 0x20 模式 | `[0x20, mode, coldOC, windOC/100, windOC%100, target, cold, wind/100, modeCustom=0]` | **第 9 字节改发 0**（原版：modeCustom；v1 错发 wind%100）。wind 只发百位（wind/100），即 wind 按 100 取整。mode 只取 0..3；mode 4 走曲线帧。target 用 `clamp(t,0,255)`（-20 这类负值进帧前钳到 0，0 = 最冷；本地显示仍保留 -20）。coldOC/windOC/cold/wind 绝不发字面 0（见 §3 填充规则），target=0 与 OC=0/0 是合法值。 |
| 0x20 曲线 | `[0x20, 0x04, 9 个档位各 clamp 1..8]` | **删 0x34 路径**。曲线温度点固定 `[-12,-9,-6,-3,0,3,6,9,12]`，默认档位 `[5,5,5,6,7,8,8,8,8]`。 |
| 0x13 轮询 | `[0x13]` 单字节 | **v1 错发 `[0x52,0x00]`**（那是读实验模式，拉不到状态）。 |
| 0x21 快捷模式 | `[0x21, mode]`，mode 只取 0/1/4 | v1 错用 0x57。 |
| 0x61 读定时 | `[0x61]` 单字节 | v1 错发 `[0x61,0x00]`。 |
| 0x60 定时设置 | `[0x60, repeat, enabled, 分钟>>8, 分钟&0xFF]` | **分钟制**（v1 是秒制且字节顺序反了）。UI 输入仍用分钟；state 里 timeCountdown 存秒（分钟×60）。 |
| 0x32 低温保护 | `[0x32, 0x00, enabled]` | 只有低温保护；**删高温保护命令**（原版无此命令；高温只是状态位）。 |
| 0x50 LED | 20 字节包：`[0x50, mode, speedRaw, 颜色总数, 包序号(1起), R,G,B×4槽, 亮度, colorful标志, checksum8]`，随后 `[0x51, mode]` 触发帧 | 颜色最多 **8 个**（take 8，超 4 色分 2 包）；亮度 **clamp 0..100**（v1 错发 0..255）；byte[18] = mode==19 ? (colorful ? 2 : 1) : 0（v1 在非 colorful 时错发 0，应为 1）；byte[19] = **checksum8 = 前 19 字节之和 mod 256**（v1 留 0，设备会丢弃——灯效不生效的头号嫌疑）。speedRaw 由 UI 速度档换算（见 §6 LED）。 |
| 0x10 灯开关 | `[0x10, 0xFF/0x00]` | 不变。 |
| 0x11/0x12 档位 | `[0x11, level]` / `[0x12, level]` | 不变。0x12 制冷档位范围 0..175。0x11 本工程**不用**（原版从不发 0x11，风量只走 0x20）。 |
| 0x26 Freeze | `[0x26, enabled, 0, 0]` | 不变（帧对），但要加事务（见 §3）。 |
| 0x25 风开关 | `[0x25, enabled ? 0 : 1]`（取反） | 新增函数备用（原版有；UI 暂不接线）。 |
| 0xA5 握手 | `[0xA5, 0xA0, 0x00, 0x00]` | 保留（Flutter 有；无害）。 |
| 0x24 / 0x22 / 0x40 | `[0x24,0]` / `[0x22,mode]` / `[0x40,0]` | 不变。 |
| 0x33 / 0xFF | 保留原样 | 低频使用，不动。 |
| 0x52 实验模式 | `[0x52, 0x01, level, target/100]` / 读 `[0x52, 0x00]` | 保留（Flutter/官方协议有，原版不用）。**绝不再用作轮询**。专家模式页用它。 |

### 状态帧解析（0x13，20 字节）改动

- 冷面温度：`temperatureValue = temp < 0 ? temp - decimal/100.0 : temp + decimal/100.0`（v1 是 /10 且负温加错方向；原版 /100 且负温减小数）。显示 1 位小数。
- flags：**bit0 = coldProtectionEnabled，bit1 = runningInMaxLevel，bit2 = timedShutdownMode，bit3 = timedShutdownRunning，bit4 = hotProtectionActive，bit5 = coldProtectionActive，bit6 = timedCountdownInMinute，bit7 = freezeMode**（v1 把 bit0/bit5 弄反了：v1 的 coldProtection 与 coldProtectionEnabled 互换）。
- 其余字段布局不变：runMode=v[2]>>4，overclockUsableLevel=v[2]&15，coldLevel=v[3]，windLevel=v[4]*100+v[5]（v[4] 有符号），target=v[6]（无符号），hotTemp=有符号 v[9]（整数），coldRunLevel=v[10]，windRunLevel=v[11]，speed=有符号 v[12]*100+v[13]，lightOn=v[14]==0xFF，ledType=v[15]，quickMode=v[16]，timeCountdown=(v[18]<<8)|v[19]（秒）。
- 百分比（首页制冷/风扇强度，**用运行档位**，不是设定档位）：`cold% = (coldRunLevel*100 + 92)/184` clamp 0..100；`wind% = (windRunLevel*100 + 127)/255` clamp 0..100（原版公式：round(raw×100/max)，max 冷=184、风=255）。设定值百分比另算：冷设定% = coldLevel×100/175，风设定% = windLevel×100/5700。
- **删 volts 显示**：全 App 不再显示“· x.xV”（voltsOf 只对 0..134 档位有效，风量 4500 算出 119.4V 是错的；原版根本不显示电压）。

## 2. 常量（原版 B9X 档案，直接照抄）

- 智能二档：静音 id 0（target 6，wind 4000，cold 145，OC 0/0）；极寒 id 2（target 0，wind 5500，cold 175，OC 0/0）。
- 手动三档：节能（cold 92，wind 4000，windOC 4000，coldOC 92）；强劲（cold 155，wind 4500，windOC 4500，coldOC 155）；极强（cold 175，wind 4500，windOC 5700，coldOC 175）。
- 上限：冷 175，风 5700（WIND_STRONGEST），目标温度帧内范围 0..16（SMART/MANUAL 帧的 target 钳到 0..16；目标温控环路的设定值 -20 只存本地，帧内钳到 0）。
- **超频转速真相（2026-11-17 02:20 重新核实，旧结论“5700 封顶”作废）**：分两个数——**设定值上限**风 5700（WIND_STRONGEST），没有任何命令能发 wind > 5700（全仓库搜 5800..6900 无设定值；字符串里无“6000”字样）；**实测转速**是状态帧 speed 字段 `(v[12]*100)+v[13]`，固件直接上报、无换算、无 Freeze 特殊处理（`B9xPacketParser.parseRealtime`）。6000 的出处：原版作者把 RPM 进度环满刻度定在 **6000.0f**（`B9xHyperOsIslandSupport.progressPercent`：`rpm/6000.0f*100`），把 CPU 温度估算模型的 RPM 归一化分母定在 6500.0f（`B9xPhoneThermalReader`，只是模型余量、不是实测 claim）；手动档位判定用 `abs(windLevel-5700)<=300`（即回显风量 5400..6000 都算极强）。机制：Freeze 只发 `[0x26,1,0,0]` 一个开关、不带任何转速数值，固件接到后以 100% 占空比驱动风扇，风扇物理转速冲到硬件上限、固件如实上报——5700 是名义最强档设定值，**6000 是 Freeze 下实测峰值**（随个体/温度/电压浮动；用户 01:09 截图里 5700 RPM 是某一时刻的读数，不是上限）。结论：**6500 RPM 作为实测值没有证据、到不了**（6500 只出现在温度估算模型的归一化分母）；**6000 RPM 是 Freeze 实测峰值，v2 超频验收标准就是它**：Freeze 真生效后，实测转速应明显高于 v1 的 3090、冲到约 6000（允许个体浮动；若他这台顶到 5700–5900，那是硬件自己的上限、不是我们的 bug，但必须明显高于 5700 名义档、且冷面温度要下来）。不许伪造转速显示。档位判定容差沿用原版（wind ±300、cold ±5、target 精确），Freeze 开启时回显 windLevel 可能读到 6000、不要因此误判档位；如有转速环/进度条，满刻度按 6000（原版值），不要按 5700。
- LED 模式 id（与 v1 字典一致，不动）：3 流光 FLOW、5 呼吸 BREATH、6 渐变 GRADIENT、4 切换 CUTOVER、11 常亮 ALWAYS_ON、12 变频旋转 SMART_ROTATION、16 多色旋转 MULTI_ROTATION、17 跳动 THROB、18 主题 THEME、19 律动 RHYTHM、20 赛博朋克 CYBERPUNK、21 碰撞 COLLISION。B9X 可用：FLOW/BREATH/GRADIENT/CUTOVER/ALWAYS_ON/MULTI_ROTATION/THROB/RHYTHM/CYBERPUNK/COLLISION（无 SMART_ROTATION/THEME）。
- LED 颜色数（min/max/默认）：FLOW 2..8，BREATH 2..8，GRADIENT 2..8，CUTOVER 2..8，ALWAYS_ON 1，MULTI_ROTATION 2..3，THROB 8，RHYTHM 8，CYBERPUNK 1..8，COLLISION 2..8。
- LED 速度（UI 0 慢 / 1 中 / 2 快 → raw）：CUTOVER/BREATH/MULTI_ROTATION 表 [3,5,8]（快→慢），GRADIENT [6,8,10]，COLLISION [8,5,3]，取 `表[2-uiSpeed]`；无表模式取 [115,58,1][uiSpeed]（慢 115 / 中 58 / 快 1）。默认速度档 = 中（raw 取表中值）。
- 九点曲线温度点 `[-12,-9,-6,-3,0,3,6,9,12]`，默认档位 `[5,5,5,6,7,8,8,8,8]`。
- B9X 能力：硬件定时关机 ✓、Freeze ✓、九点曲线 ✓、LED ✓、低温保护 ✓、快捷模式 ✓、实时遥测 ✓；专家模式 ✗（原版 B9X 不提供，0x52 仅保留入口）、参数微调 ✗（原版 B9X 的 setModeParameters 直接返回，但设备接受 0x20 帧，滑块仍走 0x20/0x12）。

## 3. 控制器行为（CoolerController.swift）

### 3.1 模式帧填充规则（核心修补）
`setRunMode` 绝不把字面 0 发进帧里：cold/wind 为 0 时用当前 state 值填；state 也没有时用当前模式的预设值填（SMART→极寒档，MANUAL→强劲档）；target 为 0 合法（=最冷），OC 0/0 合法。`rememberMode` 存解析后的完整值（不再存 0）。`setSmartLevel` 的三档预设（Flutter 的 [18,77,115…]）**作废**，改用 §2 的原版二档（静音/极寒）。`setManual`/`setOverclock(mode 2)`：**mode 2 的超频路径从 UI 删除**（见 3.3）；`setManual` 改走预设（见 3.2）。

### 3.2 模式切换事务（照搬原版 sendRunModeConfig）
- 点选模式 → 本地 state 立即更新（pendingRunMode=目标，界面立即反馈）→ 发 0x20 全参数帧 → 180/420/850ms 各补发一次 `[0x13]` 拉回显 → 1150ms 校验：state.runMode == 目标则成功，清 pending、记一条日志；失败则重试一次（再发一遍帧 + 1150ms 校验），仍失败则清 pending、state.lastError="模式切换未确认，请重试"、日志记失败。
- 已在目标模式且参数相同 → 快捷路径：只发一遍帧，不校验、不记重复日志。
- 模式真正变化时才记一条“切换模式：XXX”日志；轮询/重复下发不记日志（修每秒刷屏）。
- 若 Freeze（state.freezeMode）为真 → 不发 0x20，把该模式请求暂存，提示“正在等待退出超频…”，等 Freeze 退出确认后再补发。
- 若 max(cold, coldOC) >= 175 且 coldProtectionEnabled 为假 → 先发 `[0x32,0,1]` 开低温保护，400ms 后再发模式帧（原版的前置保护事务；日志记一句）。
- 模式入口（供 UI 用，签名冻结）：
  - `setSmartPreset(_ preset: Int)`：0=静音，2=极寒（发 SMART 全参数帧）。
  - `setManualPreset(_ preset: Int)`：0=节能，1=强劲，2=极强（发 MANUAL 全参数帧；target 取当前 state target，钳 0..16，缺省 16）。
  - `setCustomCurve(_ values: [Int])`：9 档 clamp 1..8，发 `[0x20,0x04,…]`，走同一事务（校验 runMode==4）。
  - `setTargetTemperature(_ t: Int)`：t 范围 -20..16；本地立即更新 + 保存；发 SMART 全参数帧（target 帧内钳 0..255，其余参数按 §3.1 填充）；本地优先 3 秒（见 §4）。
  - `setQuickSwitchRunMode(_ mode: Int)`：0x21，mode 只取 0/1/4。
  - `setExperimentalMode(enabled:level:targetTemperature:)`：0x52 保留，专家页用。
- 恢复上次模式：**等 READY（收到第一帧 0x13）后再发**，且只发 UserDefaults 里存过的完整值；没存过不发。`restoreLastModeOnConnect` 保留。

### 3.3 超频 = Freeze（原版机制，核心修补）
- 原版的“超频模式”按钮**不是**发 mode 2，而是发 Freeze `[0x26,1,0,0]`；mode 2 的 0x20 帧原版从不发。Flutter 的 10W/30W 两档是官方 App 的概念，原版没有。v2 照原版：**首页超频按钮 + 散热模式页“超频体验”行 → 都是 Freeze 开关**。
- `setFreezeEnabled(_ enabled: Bool)`（UI 调这个）：未 READY 时拒绝并提示“设备未就绪”；发 `[0x26,e,0,0]`；1450ms 校验（写成功 + state.freezeMode==目标）→ 成功记日志；失败重试最多 2 次（间隔 1100ms）；仍失败提示“设备未确认进入/退出超频体验，请检查供电”（进入失败）/“设备未确认退出超频体验；已阻止后续模式切换”（退出失败）。
- 退出 Freeze 后，自动补发暂存的模式请求（若有）。
- 切换到其他模式时自动退出 Freeze（先发 Freeze OFF 并等确认，再发模式帧；若用户点的就是超频则不退出）。
- **重连后遗留 Freeze 清除（紧急 bug 根因之一）**：连接 READY 后若 state.freezeMode==true 且本地 freezeDesired==false → 自动发一次 Freeze OFF，日志记“检测到原版 App 遗留的超频状态，已退出”，并在首页横幅提示一次。若用户之前在本 App 里开过 Freeze（freezeDesired==true），重连后 420ms 重申一次 Freeze ON（900ms 内只重申一次）。
- Freeze=ON 时设备拒绝 0x20——这是“先连原版再切回我们 App 后全部失效”的主因之一，务必在汇报里写清。
- 删 `setOverclock(mode 2)` 的 UI 调用（方法本身可删；`modeOverclock=2` 常量保留，仅用于回显识别：state 回显 runMode==2 时按超频显示）。

### 3.4 软件温控环路（目标温控 / 电池温控，原版 B9xAutomationEngine 逻辑）
- 模式 id：0=无，100=电池温控，101=目标温控（`softwareThermalMode`，Int，存 state）。
- 目标温控（默认目标 -20°C，可调，范围 -20..16）：每收到 0x13 或每 2 秒算一次档位 `decideCoolerTargetLevel(冷面温度, 目标)`：温差 ≤1→1，≤2→2，≤4→3，≤6→5，≤8→7，≤10→8，>10→9。档位 1..8 → 发平坦九点曲线 `[档位×9]`（走 0x20/4 事务）；档位 9 → Freeze ON。档位不变且设备已保持时不重复发。
- 电池温控（默认目标 20°C，可调）：**iOS 读不到电池温度**，用 `ProcessInfo.thermalState` 估算：nominal→1 档，fair→3 档，serious→7 档，critical→9 档（Freeze）；其余同目标温控（平坦曲线 / Freeze）。UI 上注明“电池温度 iOS 不提供，以系统热状态估算”。
- 退出环路（切其他模式 / 点其他模式按钮 / 手动调滑块）时：Freeze OFF（若开着）+ 恢复到用户点的模式；日志记“已退出XX温控”。
- 手动操作（模式/滑块/步进器/灯效）后自动化暂停 60 秒（原版行为；`manualOverrideUntil` 已有，复用；首页超频体验行显示“用户手动操作，自动化暂停 60 秒”文案时按此状态显示）。

### 3.5 连接与轮询（照搬原版）
- `afterConnected`：依次发握手 `[0xA5,A0,00,00]`、`[0x24,0]`、`[0x61]`、`[0x22,4]`；**不**立即恢复模式（等 READY）。
- READY 定义：收到第一帧 0x13。READY 前若 120/420/900/1600/2600ms 还没收到 → 各补发一次 `[0x13]`；4 秒仍未收到 → `reenableNotifications()` + 再发 `[0x13]`；同时首页横幅提示“已连接但收不到设备状态：可能原版 App 还在另一台手机上占着连接，请先在那边彻底断开”（假连识别）。
- READY 后：每 2 秒发 `[0x13]` 轮询（key "poll"）；**轮询帧绝不携带模式参数**（v1 的 bug 是轮询发 `[0x52,0]` 且 setRunMode 的 0 值曾被轮询带出去——修后轮询只发 `[0x13]`）。
- 断开：`disconnect()` 必须真正断开（取消 BLE 连接 + 清队列 + 清 lastDevice，v1 已有，保持）；重连时重新发现服务/特征、重新订阅 FFE4（BLEManager 已有流程，保持；断开时特征句柄置空，见 §5）。

### 3.6 其他命令
- 制冷滑块 → `setColdLevel(_:)`：`[0x12, clamp(0..175)]`，拖动中实时发（队列同 key 合并），松手后再确认一次；本地优先 1.5 秒。
- 风量滑块 → `setWindLevelViaMode(_ wind: Int)`：wind 范围 4000..5700、步进 100；发当前模式的 0x20 全参数帧（只改 wind，其余按 §3.1 填充）；拖动中实时发（同 key 合并），松手后再确认一次；本地优先 1.5 秒。
- 灯光开关 → `[0x10,FF/00]`，发后 220/520/900ms 补 `[0x13]`，1250ms 校验 lightOn，失败重试 1 次（照搬原版 setLightEnabled）。
- 灯效 → `applyLed` 立即发 0x50 包 + 0x51 触发帧（不再等“应用”按钮；颜色/速度/亮度任一改动都立即发全套）。
- 定时关机 → `setTimedShutdown(repeat:enabled:minutes:)`（分钟！）：发 `[0x60, repeat, enabled, 分钟>>8, 分钟&0xFF]`；关闭发 `[0x60, repeat, 0, 0, 0]`；发后 250ms 读 `[0x61]`、600ms 补 `[0x13]`。
- 低温保护开关 → `[0x32,0,enabled]`（只此一个；删高温保护开关）。
- `refreshState()`：握手 + `[0x24,0]` + `[0x61]` + `[0x22,4]` + `[0x13]`。

## 4. 状态模型（CoolerState.swift，struct）

新增字段（其余不动）：
- `coldRunLevel: Int = 0`、`windRunLevel: Int = 0`（从 0x13 的 v[10]/v[11] 填，applyStateEvent 必须填——v1 漏了）。
- `freezeMode: Bool = false`（flags bit7；v1 的 freezeModeEnabled 字段改名或复用——以 freezeMode 为准，UI 只读它）。
- `freezeRequested: Bool? = nil`（本地意图）。
- `pendingRunMode: Int? = nil`、`ready: Bool = false`、`lastStateAt: Date? = nil`。
- `softwareThermalMode: Int = 0`（0/100/101）、`batteryTargetC: Int = 20`、`coolerTargetC: Int = -20`、`smartPreset: Int = 2`（默认极寒）、`manualPreset: Int = 2`（默认极强）。
- `connectionNote: String? = nil`（首页横幅：假连提示 / Freeze 遗留提示）、`lastError: String? = nil`。
- 计算属性：`coldPercent`（运行档位，/184）、`windPercent`（运行档位，/255）、`coldSetPercent`（设定，/175）、`windSetPercent`（设定，/5700）、`temperatureValue`（按 §1 公式）。
- `applyStateEvent`：本地优先——`targetTemperature`/`coldLevel`/`windLevel`/`runMode` 在本地刚改过 3 秒内不被回显覆盖（控制器维护 `pendingLocalUntil: [String: Date]`，或由控制器在调用前处理；两种做法任选其一，但行为必须一致）；其余字段（温度、转速、运行档位、LED、Freeze、保护位、倒计时）一律以回显为准实时更新。`ready` 在第一帧 0x13 后置 true；`lastStateAt` 每帧更新。
- `demo` 静态数据：target 16 保持；coldRunLevel/windRunLevel 给合理演示值（如 150/200）。

## 5. BLE 层（BLEManager.swift）

- **回调驱动队列**（照搬原版 BleWriteQueue）：一次只一个在途；前一条写完（`didWriteValueFor` 回调）才发下一条；写失败或 **2.5 秒超时** → 重试 1 次（队首重入队），仍失败则丢弃 + `onWriteError` 回调记日志；同 key 合并时移除旧待发项并调其回调 false；可暂停/恢复（固件读取期间暂停——本工程暂不实现暂停接口，但结构上保留 `suspendWrites()/resumeWrites()` 空实现或直接实现）。
- **写类型自适应**：运行时查 `writeChar.properties`，含 `.write` 用 `.withResponse`，否则用 `.withoutResponse`（v1 无条件 withoutResponse——若特征不支持会被 iOS 静默丢弃，这是写不通的嫌疑之一；修后以运行时实际属性为准，并把当前写类型暴露为 `writeModeDescription` 供诊断页显示）。
- 实现 `peripheral(_:didWriteValueFor:error:)`：成功 → 记 write-ack（供 Freeze/模式事务用）→ 发下一条；失败 → 按上条重试。
- 断开时：清队列、取消超时计时、特征置空（已有）、`connection=.idle`；重连时重新发现服务/特征、重新订阅 FFE4（已有流程，保持）。
- 新增：`lastNotifyAt: Date?`（每次 FFE4 更新）、`reenableNotifications()`（重新 setNotifyValue(true) 并记日志）、`onWriteError: ((String) -> Void)?`、`writeModeDescription: String`。
- 未连接时 enqueue 的命令直接丢弃并记日志（与 Flutter 一致；不要静默吞掉不记）。
- 其余（扫描过滤、自动重连指数退避、lastDevice）保持 v1 行为。

## 6. UI（见 §8 分工 B；此处是行为契约）

- 首页（DeviceView）：顶部“B9X › ● 已连接 + 连接开关”；冷面温度大字**一行显示**（-12.4° 不许换行，字体自适应缩小）；右侧圆形网纹 + Y 形 logo 设备图（SwiftUI 画：圆形 + 网纹 + Y 形标志，不要只放雪花）；6 格数据 2 行 ×3：CPU（热状态文字，如“43°C”，iOS 无 CPU 温度故显示 `ProcessInfo.thermalState` 对应文字）、**电量**（明确标注“电量”+ %，不要让人误会是温度）、热面、转速、制冷强度（运行档位 %）、风扇强度（运行档位 %）。“散热模式 + 更多 ›”；模式卡（当前模式名 + 副标题 + 6 按钮 3×2 + 专属行，见下）；“超频体验”行（左蓝字，右状态文案）；“快捷控制”三卡片（灯光 开/关 / 保护机制 双保护正常/单保护/已关闭 / 定时关机 未开启/倒计时）；底栏设备/联动/更多。
- 模式卡专属行（按当前模式，只显示对应的一行）：
  - 智能变频 → “✓ 静音 / 极寒”两按钮（选中高亮；点选立即发 SMART 预设帧）。
  - 固定功率 → “节能 / 强劲 / 极强”三按钮（同上，发 MANUAL 预设帧）。
  - 自由变频 → “自由变频曲线 + 编辑”按钮（点开曲线编辑器，9 点温度 -12..12、档位 1..8，改完立即发曲线帧）。
  - 电池温控 → “电池目标 20°C + 调整”按钮（点开调目标温度页，改完生效不弹回）。
  - 目标温控 → “冷面目标 -20°C + 调整”按钮（同上）。
  - 超频模式 → “高性能输出 · 切换其他模式会自动退出超频”+ 已开启状态。
  - 模式副标题：智能“静音 · 智能调节”/“极寒 · 智能调节”（按选中档）；固定“节能/强劲/极强 · 固定功率”；自由“九点自由变频曲线”；电池“目标 20°C · 自动调节制冷”；目标“目标 -20°C · 自动维持冷面温度”；超频“高性能输出 · 切换其他模式会自动退出超频”。
  - 当前模式判定：freezeMode==true → 超频模式；否则 softwareThermalMode 100→电池温控，101→目标温控；否则 runMode 0/1/4（3 专家模式不在首页六按钮里，首页显示时按 0 处理并在散热模式页里提供入口）。
- 散热模式页（DeviceView 内 ModeGridView 所在页）：目标温度步进器（-20..16，点 +/- 立即发帧，本地优先不弹回）；制冷强度滑块（0..175，连续，显示“制冷强度 160 · 91%”格式，不显示 V）；风量滑块（4000..5700，步进 100，显示“风量 4500 · 79%”）；两个滑块拖动中实时生效、松手确认、数值与 thumb 实时同步；底部“超频体验”行不被底栏遮住（加 bottom padding）。
- 灯效页（LEDView）：删自定义大标题（用系统 navigationTitle，修返回按钮与标题重叠）；点选灯效立即下发 + 界面立即反馈；颜色 2~8 个（按模式 min/max 限制；长按色块删除；“恢复默认”按钮）；色轮选色 + “应用当前颜色”；速度三档（慢速/中速/快速）+ 亮度滑块（0..100%，显示 %）；灯光总开关在顶（“灯光已关闭”状态 + 提示“快速连按 2 次散热器开关，可按照顺序切换灯光模式”）。
- 运行日志（MoreView DataAdvancedView）：进页面自动刷新 + 新日志自动滚动到底部；“切换模式”类日志去重（只在模式真正变化时记一条）；顶部“重新读取设备状态”按钮不被导航栏遮住（改用 toolbar 或加 top padding）。
- 联动页（AutomationView）：“充电随动”卡片说明文字不截断（多行显示）。
- 更多页（MoreView）：AppearanceView 的手动主题切换**删除**（全 App 跟随系统）；AboutView 重写（见 §7）。
- 全 App 跟随系统外观：删 `ContentView.preferredColorScheme(.dark)`、删 `Info.plist` 的 `UIUserInterfaceStyle`、GlassViews 的硬编码深色改为系统自适应（`Color(.systemBackground)` / `.secondarySystemBackground` 等语义色，亮暗都好看）。
- 其余遮挡/截断通查修掉（逐屏过一遍）。

## 7. 改名 / 关于页 / 图标

- 显示名“引擎核心 Plus”，Bundle ID `com.enginecore.plus`（pbxproj 两处配置都改），版本 0.8.143（227）不动。`Info.plist` 的 `CFBundleDisplayName` 改名；删 `UIUserInterfaceStyle`。
- 全工程、关于页、README、仓库描述删“冰环/BingHuan/冰环FLY”。ConnectView 里的“冰环FLY”文字删掉。
- 关于页：应用名“引擎核心 Plus”、版本 0.8.143（227）、开发者“伊森 & 耄耋”；“社区与联系”改成 **z1859741z@gmail.com**（原作者酷安/抖音/QQ 群链接全删）；“支持作者”（赞赏/捐赠）整项去掉；开源组件列表换成我们的信息（SwiftUI / CoreBluetooth / AppIntents 等真实使用的，外加协议参考 feizhi-b9x-cooler-client 与原版实现对照说明——写“协议对照”不写“冰环”）；其他关于项保留。
- 图标：源文件 `~/workspace/binghuan-fly-ios/media-generation-engine-core-plus-icon-0-4e0b34d4-018e-48c2-ae08-e38ad9d48710.webp`（白熊+黄王冠+红披风，深蓝底；带圆角留白）→ 转 **1024×1024 全幅 PNG**（深色铺满到边，iOS 自己切圆角），做成 `AppIcon.appiconset`（含全部所需尺寸）；关于页如有 logo 也换成这只熊。

## 8. 分工

- **Agent CORE**（核心）：`B9XController/Protocol/B9XProtocol.swift`、`B9XController/BLE/BLEManager.swift`、`B9XController/Controller/CoolerController.swift`、`B9XController/Models/CoolerState.swift`。按 §1–§5 实现；UI 调用的公开方法签名按 §3.2/§3.3/§3.6 冻结，缺失的补齐，废弃的删掉（`setSmartLevel` 三档、`setOverclock` mode 2、`setCustomCurve` 0x34 路径、`setTempProtect` 高温分支、`setTimedShutdown` 秒制参数——对外签名可改，但要在最终汇报里列出改了哪些签名）。
- **Agent UI**（界面）：`B9XController/UI/` 全部（DeviceView、LEDView、MoreView、AutomationView、ContentView、GlassViews、ConnectView）、`B9XController/Info.plist`、`B9XController.xcodeproj/project.pbxproj`（只改 Bundle ID 与相关显示名）、`README.md`、AppIcon（含图标转换）。按 §6–§7 实现；调用 CORE 的冻结 API（§3.2/§3.3/§3.6 的方法名与 §4 的 state 字段）；若 CORE 的 API 与本 spec 不符，以 spec 为准、不要自己改 CORE 的文件，有出入在汇报里写明。
- 两代理都不要提交 git、不要改对方文件、不要动 `~/workspace/b9x-ios-port/`、不要做构建（主代理统一做）。完成后各自汇报：改了哪些文件、关键行为、未解决的疑问。

## 9. 官方包佐证（飞智游戏厅 7.2.11.2，jadx 反编译，仅佐证；下一轮优化再用）

- 官方原生 SDK `com.flydigi.sdk.waspwing`（classes2.dex）+ Dart 层（libapp.so，AOT，未深拆——字符串/符号级已探，blutter 未装，连接逻辑本就在 dex 层）。
- **连接流程**：`connectGatt(autoConnect=false, transport=2 LE, phy=3 1M+2M)`；仅当状态为断开才连；连接超时 5 秒（超时只复位状态、不主动 close）；连上 → `discoverServices()`；发现服务 → 取 FFE0 服务、找 FFE1/FFE4 → `setCharacteristicNotification(true)` + 写 CCCD `ENABLE_NOTIFICATION_VALUE`；**无 MTU/连接优先级请求、无主动 readCharacteristic**；CCCD 写完后 SDK 层无后续动作（初始化帧由 Dart 层经 method channel 驱动，顺序未从 AOT 恢复）。
- **断开**：`disconnect()` + `gatt.close()` + 置空；**每次断开都调隐藏 API `BluetoothGatt.refresh()` 清 GATT 缓存**（Android 特有；iOS 无等价物，v2 以“取消连接＋特征置空＋重新发现”对应）。
- **无自动重连、无跨手机占线检测、无抢连接机制**：SDK 层 `connectWith` 只拦“已连着另一台设备”；dex 全文无“被占用/已被连接”文案。BLE 本身无跨手机占线查询接口——v2 的“4 秒收不到 0x13 帧就提示可能被占着”做法是唯一可行的，与官方能力边界一致。
- **写队列**：串行、写间隔 ≥30ms（不足则 sleep 补到 35ms）；`writeCharacteristic` 返回 false 就地重试最多 11 次；写超时 runnable 100ms，超时重试 1 次、再超时丢弃并推进队列。写类型官方用 **NO_RESPONSE（setWriteType(1)）**，冰环用 **WITH_RESPONSE（2）**——两家都在线上跑通，FFE1 两种都接受；v1 无条件 withoutResponse 不是写不通的主因，主因是帧错误（§1）；§5“写类型自适应”保留。
- **帧对照（全部一致）**：0x20 九字节帧第 9 字节官方留 0（与 §1“发 0”一致）；轮询单字节 `[0x13]`（与 §1 一致；`[0x52,0x00]` 只是读实验模式）；Freeze `[0x26,1/0,0,0]`（与 §3.5 一致）；灯光开关 `[0x10,FF/00]`；快捷模式 `[0x21,mode]`；实验模式 `[0x52,0x01,…]`；取 UUID `[0xA5,0xA0,0,0]`；状态帧布局与 §1 逐字节一致，温度为整数 + 小数/100（官方分开存两字段拼 `"%d.%d"`，与 §1 符号感知 /100 等价），转速 `(v[12]*100)+v[13]` 原始上报无换算。
- **风量上限**：官方 `WIND_LEVEL_MAX_B9X=4500`（常规），`WIND_LEVEL_MAX_OVERCLOCK_B9X=5700`（超频）；**无任何通路发 wind > 5700**。超频在官方包里只有 Freeze 方法 + `OverclockLevel` 1/2 两档 + OC 档位阈值，无现成“6000”设定——超频依据仍按冰环 Freeze（§2 勘误版），官方不作超频依据。
- **两处待真机验证（非代码改动）**：① flags bit0/bit5：官方 + Flutter 一致（bit0=coldProtection 触发态、bit5=coldProtectionEnabled 开关），与冰环命名相反；v2 仍按冰环（冲突规则），若真机上保护指示反了，对调一行即可。② LED 帧 byte[19]：官方发 0，冰环发 checksum8，两家灯效都正常 → 设备忽略该字节；v2 仍按冰环发 checksum8。
- **Dart 层止步点**：libapp.so 含 `package:waspwing/...`（bridge、models、capabilities B3–B9、enums），连接/初始化顺序在 Dart 侧经 method channel（方法名见 `WaspwingMethodHandler`：connectGattWith/disconnect/ctrlFreezeMode/refreshDeviceInfo/requestRunModeParams/requestMacAddress/refreshGatt 等）驱动，AOT 未反编译；下一轮如需可装 blutter 再拆。

## 10. 官方包连接层深拆（下一轮优化用；dex 层已完成，Dart 层 blutter 构建中）

来源：飞智游戏厅 7.2.11.2。dex 全覆盖：classes.dex（3274 .java）、classes2.dex（1202）、classes3.dex（723）已 jadx 全量反编译；classes4/5 经字符串计数确认零 flydigi 引用，跳过。连接逻辑全部在 classes2（SDK）+ classes3（UI 触发层）；classes3 的 42 个 waspwing 文件全是界面（DetailFragment/对话框/LED/曲线编辑），无 BLE 逻辑。

### 10.1 扫描（`com.flydigi.sdk.bluetooth.q` + `WaspWingManager`）
- 官方用**旧版 `BluetoothAdapter.startLeScan`**（scanMode=2 走 `U()` → 权限通过后 `T()` → startLeScan；scanMode=1 才走现代 `BluetoothLeScanner` 的 `R()`）。**无 service-UUID 过滤、无 ScanFilter**，回调里按名字过滤。
- 过滤规则（`H()` + `WaspWingManager$init$filter$1`）：`RSSI > -90 dBm && 名字 != null && 名字在 BLUETOOTH_NAME_LIST 里（精确匹配）`。名字取不到时用广播解析 `w.a(scanRecord)` 从广播包里抠名字。
- 名单（`BluetoothName`，10 个精确值）：Flydigi Waspwing2 Pro、Flydigi B5、Flydigi B5Pro、Flydigi B5X、Flydigi B6、Flydigi B6X、Flydigi B7、Flydigi B7X、Flydigi B8X、**Flydigi B9X**。
- 扫描入口 `ScanFragment.v3()`：Android <31 先要位置权限；点设备项 → `bleDevice.U()`（记选）→ `WaspWingManager.connectGattWith(device)`。
- iOS 对应：`CBCentralManager.scanForPeripherals` 不带 service UUID 过滤（或带 FFE0 亦可，官方没用），`didDiscover` 里按名字精确匹配 + RSSI > -90 过滤。v2 现状是按服务发现，下一轮可加名字精确匹配防串设备。

### 10.2 连接（`m0` + `AbstractDataInteractionController`）
- `connectWith(device)`：先 `W()` 守卫——`mDataConnectState == 1（连接中）|| == 2（已连接）` 就直接返回，只防本机重复连。
- `connectGatt(context, autoConnect=false, callback, transport=2 LE, phy=3 即 1M+2M)`；设备类型须 LE/DUAL。
- **连接超时 5 秒**：`onGattConnectStart` 后 5000ms 若仍在连接态，状态归 0 并发 `onGattConnectTimeout` 事件；**只复位状态，不主动 disconnect/close**。
- **无自动重连**：SDK 层无 reconnect/autoConnect；UI 层 `onGattDisconnected` → `v3()` **自动重新开始扫描**（不是自动重连，是回到扫描列表）。
- 连接失败 UI：`onGattConnectFailed` 只调 super（无提示、无重试）；`onGattConnectTimeout` 只把提示文字改成"连接失败"（`j3()`）+ 埋点，无重试按钮。
- 断开：`disconnect()` + `gatt.close()` + 置空 + `clearQueue()`；每次断开调隐藏 API `BluetoothGatt.refresh()` 清 GATT 缓存（Android 特有；iOS 无等价物，v2 以取消连接＋特征置空＋重新发现对应）。
- `createBond` 只经 method channel 暴露，**连接流程里从不自动调用**——B9X 正常连接不配对、不加密。

### 10.3 GATT 协商与初始化
- 连上 → `discoverServices()` → 取 FFE0 服务 → 找 FFE1/FFE4 → `setCharacteristicNotification(true)` + 写 CCCD `ENABLE_NOTIFICATION_VALUE`。**不发 MTU 请求、不发连接优先级请求、不主动 readCharacteristic**；`onDescriptorWritten` 为空实现。全 dex 只有一处 `requestConnectionPriority(1)`，在高通耳机 GAIA 服务里，与 waspwing 无关。
- 原生初始化链（`WaspWingDataInteractionController.onReceiveDataFromDevice` 内）：固件版本响应到达 → 1000ms 后 `getExperimentalRunMode()`（`[0x52,0x00]`）→ UUID 为空则 `getUUIDCommand()`（`[0xA5,0xA0,0,0]`）→ `WaspWingManager.requestLedColor(0)`（`[0x51,0]`）。
- `refreshDeviceInfo`（Dart → native）：`requestMacAddress()`（`[0x24,0x00]`，注意不是 0xA5 帧）+ `readTimedShutdown()`（单字节 `[0x61]`）。
- `openReadNotification()` = 单字节 `[0x13]`，**只由 Dart 侧经 method channel 显式调用**（`WaspwingMethodHandler` case `openReadNotification`），原生层没有定时轮询器。
- `requestRunModeParams(i)` = `[0x22,i]`；`requestTempHistory()` = `[0x40,0x00]`；`requestLedColor(i)` = `[0x51,i]`。
- 写入口 `X()`：只有 state==2（已连接）才写，否则记 "Gatt hasn't connected" 并丢弃（与 v2 spec §5 一致）。

### 10.4 写队列（`m0.writeToBluetoothDevice` + 控制器 `ConcurrentLinkedQueue`）
- 串行；写前保证 ≥30ms 间隔（不足则 `Thread.sleep(35 - elapsed)`）；`writeCharacteristic` 返回 false 就地重试最多 11 次；每次写完挂 100ms 超时 runnable，超时重试 1 次、再超时丢弃并推进队列。
- 写类型官方 NO_RESPONSE（`setWriteType(1)`）；冰环 WITH_RESPONSE（2）。两家线上都通，FFE1 两种都接受（已写入 §9，不重复）。

### 10.5 未恢复的部分
- **`runFetchLoop`（Kotlin 协程，`AbstractDataInteractionController.kt:55`）**：jadx 报 `JadxOverflowException`，循环体无法从反编译输出恢复；调用点也未在 dex 源码里找到。已知 `[0x13]` 由 `openReadNotification` 显式触发、原生无定时器；该协程可能是 Dart 侧轮询的补充或固件拉取循环，**间隔与触发条件未恢复**。下一轮如需精确值，可用 androguard 读该方法字节码或等 blutter 的 Dart 侧结果（Dart 侧若用 Timer.periodic 调 openReadNotification，间隔即在 Dart 代码里）。
- **Dart 层（libapp.so，AOT）**：blutter 已启动（`~/workspace/.cache/blutter-repo`，venv `~/workspace/.cache/blutter-venv`，日志 `/tmp/blutter-run.log`，输出 `~/workspace/.cache/blutter-out`）。blutter 从 Flutter 引擎检测到 Dart **3.9.2**（早先字符串猜的 3.3.4 是错的，已纠正），正在克隆 Dart SDK 3.9.2 源码并编译专用解析器。工具链已齐：g++ 13.3.0、cmake 3.28.3、ninja 1.13.2（pip 装，apt 无候选）、pyelftools/requests。构建耗时较长（Dart VM 编译，4 核），跑完后从 `objs.txt`/`pp.txt`/`asm/` 恢复 Dart 侧连接时序（init 调用顺序、重连定时器、超时处理），再补进本节。
- 止步点记录：pip 无 blutter 包（须 git clone 源码）；apt 装不上 ninja（须 pip 装 `ninja` 包）；libflutter.so 须从 APK 另行解出（首次解包只取了 libapp.so）。

### 10.6 对下一轮 v2.x 的直接启示（待用户验收反馈后排期）
1. 扫描加名字精确匹配（"Flydigi B9X"）+ RSSI > -90 过滤，防串到别的 BLE 设备。
2. 连接超时 5 秒与 v2 的 4 秒假连判定基本一致，保留 4 秒（更敏感），不改。
3. 断开后自动回到扫描（官方 UI 层做法）——v2 断开后如自动重扫，需用户确认是否想要（可能打扰），默认不做。
4. 连接失败/超时只给文字提示、不自动重试——与 v2 现状一致，不改。
5. 不配对、不发 MTU/优先级——v2 已是这样，不改。
6. 若 blutter 恢复出 Dart 侧 init 顺序与 v2 §3.5 有出入，以 Dart 侧为准补齐。
