import Foundation

/// 连接阶段（DEEP-DIVE §3.3 `ConnectionPhase`）。
/// case 名未从符号表恢复，此处按传输层实际流程定义。
enum ConnectionPhase: String {
    case idle
    case scanning
    case discovering
    case subscribing
    case ready
    case connecting
    case recovering
    case flashing
    case failed
    case disconnected

    var displayName: String {
        switch self {
        case .idle: return "未连接"
        case .scanning: return "扫描中"
        case .discovering: return "发现服务"
        case .subscribing: return "订阅通知"
        case .ready: return "已就绪"
        case .connecting: return "连接中"
        case .recovering: return "重连中"
        case .flashing: return "刷固件中"
        case .failed: return "连接失败"
        case .disconnected: return "已断开"
        }
    }
}

/// 目标（DEEP-DIVE §3.4 `ModeTarget`）。
struct ModeTarget: Equatable {
    var mode: Int = B9XProtocol.modeSmart
    var targetCelsius: Int = 16
    var fanPercent: Int = 0
    var tecPercent: Int = 0
    var level: Int = 0
    var smartPreset: Int = 2
    var curveLevels: [Int] = B9XProtocol.defaultCurveLevels
    var isSoftwareControlled: Bool = false
    var isValid: Bool = true
}

/// 命令归属（DEEP-DIVE §1.1 `CommandOwner`）。
enum CommandOwner: String {
    case user
    case software
    case charging
    case system
}

/// 当前会话快照（DEEP-DIVE §3.2 `SessionSnapshot`）。
struct SessionSnapshot {
    var target: ModeTarget?
    var telemetry: StateEventData?
    var freezeOn: Bool = false
    var isCharging: Bool = false
    /// 设备是否在回应（收到过遥测帧）。
    var powerOn: Bool = false
    var phase: ConnectionPhase = .idle
}

/// 会话事件：状态机唯一的输入（DEEP-DIVE §3.1，简化版）。
enum SessionEvent {
    case telemetry(StateEventData)
    case userRequest(ModeTarget)
    case commandAcknowledged(generation: UInt64)
    case timerFired(UUID)
    case connectionLost
    case chargingStarted
    case chargingEnded
    case freezeChanged(Bool)
}

/// 状态机输出的效果：由 CoolerController 执行，状态机本身不碰 BLE。
enum SessionEffect {
    /// 发一条命令（Data 为完整帧，key 供写队列合并用）。
    case sendCommand(Data, key: String)
    /// 启动一个定时器；到时由调用方回喂 `.timerFired(token)`。
    case startTimer(TimeInterval, token: UUID)
    /// 读回一次设备状态（单字节 [0x13]）。
    case readBack
    /// 向用户报错（同时记日志）。
    case reportError(String)
    /// 取消进行中的操作（断连时）。
    case cancelPending
    /// 恢复被 Freeze 暂停的目标（调用方按已有事务补发，幂等）。
    case resumePausedTarget
}

/// 会话状态机（DEEP-DIVE §3 的简化版）：事件 → 效果。
/// 字段名照 §3.2；状态机逻辑只在这里，不散在 UI 或控制器各处。
/// 控制器负责把事件喂进来、把效果执行掉（发命令/启定时器/读回/报错）。
struct SessionMachine {
    var snapshot = SessionSnapshot()

    var timerToken: UUID?
    var fullChargeToken: UUID?
    var chargingBase: ModeTarget?
    var chargingOwned: Bool = false
    var followUpOwner: CommandOwner?
    var softwareOwner: CommandOwner?
    var pausedSoftwareOwner: CommandOwner?
    var followUpTarget: ModeTarget?
    var pausedHardwareTarget: ModeTarget?
    var pausedHardwareCurve: [Int]?
    var resumeRequestedAt: Date?
    var lastChargingReadAt: Date?
    var chargingAcquireRequestedAt: Date?
    var sawAuthoritativeOff: Bool = false
    var timerExpiredWaiting: Bool = false
    var userTookOverCharging: Bool = false
    var chargingStartedFromOff: Bool = false
    var hasChargingObservation: Bool = false

    private var lastAcknowledgedGeneration: UInt64 = 0

    mutating func handle(_ event: SessionEvent, now: Date) -> [SessionEffect] {
        switch event {
        case .telemetry(let telemetry):
            snapshot.telemetry = telemetry
            snapshot.freezeOn = telemetry.freezeMode
            snapshot.powerOn = true
            if telemetry.freezeMode {
                // Freeze 期间冻结软件目标，记下来等退出后恢复。
                if let target = snapshot.target, target.isSoftwareControlled {
                    pausedHardwareTarget = target
                    pausedHardwareCurve = target.curveLevels
                    pausedSoftwareOwner = softwareOwner
                }
                return []
            }
            if pausedHardwareTarget != nil {
                pausedHardwareTarget = nil
                pausedHardwareCurve = nil
                pausedSoftwareOwner = nil
                resumeRequestedAt = now
                return [.resumePausedTarget]
            }
            return []

        case .userRequest(let target):
            // 用户接管：记下目标与归属，清掉暂停的跟进。
            snapshot.target = target
            followUpOwner = .user
            followUpTarget = target
            if target.isSoftwareControlled {
                softwareOwner = .user
            }
            pausedHardwareTarget = nil
            pausedHardwareCurve = nil
            return []

        case .commandAcknowledged(let generation):
            lastAcknowledgedGeneration = generation
            return []

        case .timerFired(let token):
            if token == timerToken {
                timerToken = nil
                timerExpiredWaiting = false
                return [.readBack]
            }
            if token == fullChargeToken {
                fullChargeToken = nil
                return endCharging(now: now)
            }
            return []

        case .connectionLost:
            cancelOperation()
            cancelTimer()
            return [.cancelPending]

        case .chargingStarted:
            hasChargingObservation = true
            snapshot.isCharging = true
            chargingStartedFromOff = !snapshot.powerOn
            if !chargingOwned {
                chargingOwned = true
                chargingAcquireRequestedAt = now
                chargingBase = snapshot.target
                return [.readBack]
            }
            return []

        case .chargingEnded:
            snapshot.isCharging = false
            chargingOwned = false
            if let base = chargingBase {
                chargingBase = nil
                followUpTarget = base
                return [.resumePausedTarget]
            }
            return [.readBack]

        case .freezeChanged(let on):
            snapshot.freezeOn = on
            if on {
                if let target = snapshot.target, target.isSoftwareControlled {
                    pausedHardwareTarget = target
                    pausedHardwareCurve = target.curveLevels
                }
                return []
            }
            if pausedHardwareTarget != nil {
                pausedHardwareTarget = nil
                pausedHardwareCurve = nil
                resumeRequestedAt = now
                return [.resumePausedTarget]
            }
            return []
        }
    }

    // ------------------------------------------------------------ 私有辅助

    /// 是否具备控制条件（收到过遥测帧才算 READY）。
    func canControl() -> Bool {
        snapshot.telemetry != nil && snapshot.powerOn
    }

    /// 取消进行中的操作与跟进目标。
    private mutating func cancelOperation() {
        followUpTarget = nil
        followUpOwner = nil
        pausedHardwareTarget = nil
        pausedHardwareCurve = nil
    }

    /// 取消全部定时器令牌。
    private mutating func cancelTimer() {
        timerToken = nil
        fullChargeToken = nil
        timerExpiredWaiting = false
    }

    /// 结束充电随动：回到充电前的基准目标。
    private mutating func endCharging(now: Date) -> [SessionEffect] {
        chargingOwned = false
        snapshot.isCharging = false
        if let base = chargingBase {
            chargingBase = nil
            followUpTarget = base
            resumeRequestedAt = now
            return [.resumePausedTarget]
        }
        return []
    }
}
