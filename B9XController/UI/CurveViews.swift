import SwiftUI

// ------------------------------------------------------------ 红魔曲线编辑器
//
// 调 controller.setRedMagicCurve（九点曲线）。飞智九点曲线不动，
// 已在 DeviceView 里，不归本文件管。
//
// 下发已接入控制器（`controller.setRedMagicCurve(_:)`）。
// 九点编辑与本地保存（UserDefaults，键与原包一致的 redMagicCurves）
// 是真实实现；未连红魔时仅保存不发送。红魔曲线只在红魔设备上生效，
// B9X 上仅本地保存。

/// 红魔曲线本地保存（UserDefaults JSON；键名与原包 redMagicCurves 对应）。
struct RedMagicCurveStore {
    static let defaultsKey = "redMagicCurves"
    static let boostKey = "redMagicBoostAllowed"

    static func loadLevels() -> [Int] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let levels = try? JSONDecoder().decode([Int].self, from: data),
              levels.count == 9 else {
            return B9XProtocol.defaultCurveLevels
        }
        return levels
    }

    static func saveLevels(_ levels: [Int]) {
        if let data = try? JSONEncoder().encode(levels) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func loadBoostAllowed() -> Bool {
        UserDefaults.standard.bool(forKey: boostKey)
    }

    static func saveBoostAllowed(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: boostKey)
    }
}

struct RedMagicCurveView: View {
    @EnvironmentObject private var controller: CoolerController

    @State private var levels: [Int] = RedMagicCurveStore.loadLevels()
    @State private var boostAllowed: Bool = RedMagicCurveStore.loadBoostAllowed()
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private var state: CoolerState { controller.state }

    private var isRedMagic: Bool {
        state.deviceName.contains("RedMagic")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("红魔曲线")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isRedMagic {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color.b9xAccentLight)
                                Text("红魔设备专属")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }
                            Text("红魔曲线只在红魔设备上生效。当前连接的是 \(state.deviceName.isEmpty ? "未连接的设备" : state.deviceName)，下面仍可编辑并保存在本机，连上红魔设备后再下发。")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xTextDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                curveCard
                boostCard
                Button(action: applyCurve) {
                    Text("应用到设备")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.b9xAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                if let message = resultMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(resultIsError ? .red : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("九点曲线：从冷到热九个温度点的制冷档位（1–8 档）。飞智的九点曲线在设备页里改，不在这里。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("红魔曲线")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var curveCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("九点曲线")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("恢复默认") {
                        levels = B9XProtocol.defaultCurveLevels
                        RedMagicCurveStore.saveLevels(levels)
                        resultMessage = nil
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                }
                ForEach(levels.indices, id: \.self) { i in
                    HStack {
                        Text("点 \(i + 1)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .frame(width: 44, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(levels[i]) },
                            set: {
                                levels[i] = Int($0)
                                RedMagicCurveStore.saveLevels(levels)
                            }
                        ), in: 1...8, step: 1)
                        .tint(.b9xAccent)
                        Text("\(levels[i]) 档")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Color.b9xAccentLight)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var boostCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("允许破坏神增压", isOn: Binding(
                    get: { boostAllowed },
                    set: {
                        boostAllowed = $0
                        RedMagicCurveStore.saveBoostAllowed($0)
                    }
                ))
                .foregroundStyle(.primary)
                Text("开增压后曲线最高点可突破常规上限，制冷更强、功耗与发热也更高。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyCurve() {
        controller.setRedMagicCurve(levels)
        resultIsError = false
        resultMessage = "曲线已保存并下发（红魔通道，帧结构未验证；未连红魔时仅保存）。"
    }
}
