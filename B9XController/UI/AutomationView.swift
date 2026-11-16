import SwiftUI

/// 场景联动页（对照原版“联动”页）：
/// 超频体验总开关 + 电池/充电/前台状态；充电随动、游戏联动、电池智能稳温；
/// 手动接管窗口滑块 + 优先级规则。
struct AutomationView: View {
    @EnvironmentObject private var controller: CoolerController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("场景联动")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                standbyCard
                chargeCard
                gameCard
                batteryCard
                overrideCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private var standbyCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "snowflake")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("超频体验")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("自动化待机")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                    Spacer()
                    Toggle("", isOn: $controller.automationStandby)
                        .labelsHidden()
                }
                Divider().background(Color.white.opacity(0.1))
                HStack {
                    statusColumn("电池", controller.batteryLevel >= 0 ? "\(controller.batteryLevel)%" : "--")
                    statusColumn("充电", controller.batteryCharging ? "是" : "否")
                    statusColumn("前台", "--")
                }
                Text("iOS 读不到电池温度与前台应用：电池显示电量，前台显示 --。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func statusColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
            Text(value)
                .font(.headline.monospaced())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chargeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("充电随动")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("手机充电时连接散热器并切换指定模式，不尝试软件关机。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                    Spacer()
                    Toggle("", isOn: $controller.chargeFollowEnabled)
                        .labelsHidden()
                }
                if controller.chargeFollowEnabled {
                    HStack {
                        Text("充电时切换到")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                        Picker("", selection: $controller.chargeFollowMode) {
                            Text("智能变频").tag(B9XProtocol.modeSmart)
                            Text("固定功率").tag(B9XProtocol.modeManual)
                            Text("超频模式").tag(B9XProtocol.modeOverclock)
                            Text("自定义曲线").tag(B9XProtocol.modeCustom)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }
                }
            }
        }
    }

    private var gameCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("游戏联动")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("指定游戏进入前台后拥有最高自动化优先级。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                    Spacer()
                    Toggle("", isOn: $controller.gameLinkageEnabled)
                        .labelsHidden()
                }
                if controller.gameLinkageEnabled {
                    Text("iOS 上 App 无法直接检测前台游戏。开启后请去快捷指令建自动化：打开游戏时运行“设置散热器模式”。")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Link("去快捷指令设置自动化", destination: URL(string: "shortcuts://")!)
                        .font(.subheadline)
                }
            }
        }
    }

    private var batteryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "thermometer")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("电池智能稳温")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("持续追踪电池温度，智能变频进入并维持你设定的温度区间。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                    Spacer()
                    Toggle("", isOn: $controller.batterySmartTempEnabled)
                        .labelsHidden()
                }
                if controller.batterySmartTempEnabled {
                    Text("iOS 读不到电池温度，用系统热状态代替：过热时降到区间下限，温热时取中间值。")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                    Stepper("区间下限 \(controller.batteryTempMin)°C", value: $controller.batteryTempMin, in: 20...40)
                        .foregroundStyle(.white)
                    Stepper("区间上限 \(controller.batteryTempMax)°C", value: $controller.batteryTempMax, in: 25...45)
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var overrideCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("手动接管窗口")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("手动切换模式后，联动暂时不抢回控制；场景变化后重新仲裁。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                Text("\(Int(controller.manualOverrideSeconds)) 秒")
                    .font(.title3.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                Slider(value: $controller.manualOverrideSeconds, in: 10...300, step: 10)
                    .tint(.b9xAccent)
                Text("优先级：游戏 > 电池温度 > 充电。超频体验与用户手动操作始终优先。")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
    }
}
