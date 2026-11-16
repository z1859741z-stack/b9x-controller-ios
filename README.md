# 冰环FLY for iOS

飞智 B6X / B7X / B8X / B9X 散热器第三方控制器，iOS 原生版（Swift / SwiftUI）。

原版是安卓 App（包名 `com.b9x.controller`，v0.8.143，Kotlin + Compose + Miuix），
本仓库是基于 BLE 协议的原生重写，不是源码移植（原版不开源）。
协议参考开源项目 [feizhi-b9x-cooler-client](https://github.com/ShaoCI-Hz/feizhi-b9x-cooler-client)，
服务 `FFE0`、写特征 `FFE1`、通知特征 `FFE4`。

## 功能

- 扫描、连接 B9X 系列散热器（按广播名过滤），断线自动重连
- 散热模式：智能变频 / 固定功率 / 自由变频 / 电池温控 / 目标温控 / 超频模式
- 智能温控三档（安静 / 均衡 / 强劲）、目标温度、制冷 / 风量档位
- 超频（10W / 30W，首次开启有警告确认）
- 自定义温度曲线（9 段，仅 B9X）
- 灯效：19 种效果、颜色、流转速度、亮度
- 定时关机、冻结模式、低温 / 高温保护
- 场景联动：充电随动、游戏联动、电池智能稳温、手动接管窗口
- 设置导入导出（JSON）、运行日志、诊断
- 宣传演示模式：模拟真实设备状态，不扫描、不连接、不发蓝牙指令
- 快捷指令：App Intents（“设置散热器模式”），可在“快捷指令”里建自动化

## 移植说明

### 照搬

- BLE 协议：命令帧、状态帧解析与开源 Flutter 项目逐行对照
- 核心控制链路：扫描过滤、连接、FFE4 通知、FFE1 无响应写、45ms 命令间隔 + 同类合并
- 超频警告确认、自定义曲线、定时关机、灯效分包、保护开关、设置导入导出
- 界面结构：设备 / 联动 / 更多三 tab，深色圆角卡片 + 液态玻璃底栏

### iOS 替代实现

| 原版功能 | iOS 做法 |
| --- | --- |
| 游戏检测自动联动（读前台 App） | 快捷指令自动化 + App Intents；App 内无法直接检测 |
| 电池温度追踪 | 用系统热状态（nominal / fair / serious / critical）代替 |
| CPU / GPU 温度读取 | 用系统热状态代替 |
| 快捷磁贴 | 控制中心控件 / 小组件（后续版本）；当前先用快捷指令 |
| 通知栏 | 断连本地通知（需授权） |
| 原生实时动态 | Live Activity（后续版本，需小组件扩展） |
| 连接后恢复上次模式 | 打开 App 自动重连上次设备并恢复模式 |

### 做不到（iOS 系统限制）

- 游戏联动自动触发：iOS 不允许读取其他 App 状态，只能由快捷指令自动化触发
- Shizuku：iOS 没有
- 悬浮窗：iOS 不允许系统级悬浮窗
- 无障碍保活：iOS 没有；用蓝牙后台模式 + 断线自动重连代替
- HyperOS 超级岛：iOS 无对等功能

## 构建

GitHub Actions（macOS runner）自动编译未签名 IPA：

1. 推送到 `main` 即触发 `.github/workflows/ios.yml`
2. 在 Actions 页下载 `B9XController-unsigned-ipa`
3. 用自己的签名工具（全能签等）签名后安装

本地构建需要 Mac + Xcode 26（iOS 26 SDK，Liquid Glass）：

```sh
xcodebuild -project B9XController.xcodeproj -scheme B9XController \
  -sdk iphoneos -configuration Release \
  CODE_SIGNING_ALLOWED=NO
```

## 状态

- 编译：见 Actions（绿灯为通过）
- 蓝牙实机连接：未实测（开发者没有 iPhone 与 B9X 硬件），需实机验证
