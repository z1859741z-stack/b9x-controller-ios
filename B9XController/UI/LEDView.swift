import SwiftUI

/// 灯效页：效果选择、颜色、周期、亮度。
struct LEDView: View {
    @EnvironmentObject private var controller: CoolerController

    @State private var selectedType: Int = 3
    @State private var colors: [Color] = [.cyan, .blue, .purple, .pink]
    @State private var period: Double = 40
    @State private var light: Double = 200
    @State private var colorful: Bool = false

    private var state: CoolerState { controller.state }

    private var sortedTypes: [(key: Int, value: String)] {
        B9XProtocol.ledTypes.sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if !controller.isConnected {
                    GlassCard {
                        Text("还没有连接散热器，灯效设置会在连接后生效。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }

                effectGrid
                colorCard
                slidersCard
                applyButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .onAppear {
            selectedType = state.ledType
            if !state.ledColors.isEmpty {
                colors = state.ledColors.prefix(4).map { Color(hex: $0) }
            }
            period = Double(state.ledPeriod)
            light = Double(state.ledLight)
            colorful = state.ledColorful
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("灯效")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("19 种灯效 · 颜色与速度可调")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.lightOn },
                set: { controller.setLightEnabled($0) }
            ))
            .labelsHidden()
        }
    }

    private var effectGrid: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("效果")
                    .font(.headline)
                    .foregroundStyle(.white)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 10) {
                    ForEach(sortedTypes, id: \.key) { item in
                        Button {
                            selectedType = item.key
                            apply()
                        } label: {
                            Text(item.value)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(selectedType == item.key ? Color.b9xAccent : Color.b9xCard2)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    private var colorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("颜色（最多 4 个）")
                    .font(.headline)
                    .foregroundStyle(.white)
                ForEach(0..<min(colors.count, 4), id: \.self) { i in
                    ColorPicker("颜色 \(i + 1)", selection: $colors[i])
                        .foregroundStyle(.white)
                }
                if selectedType == 19 {
                    Toggle("多彩律动", isOn: $colorful)
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var slidersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("流转速度")
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(period))")
                            .foregroundStyle(Color.b9xAccentLight)
                            .monospaced()
                    }
                    .font(.subheadline)
                    Slider(value: $period, in: 0...255, step: 1)
                        .tint(.b9xAccent)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("亮度")
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(light))")
                            .foregroundStyle(Color.b9xAccentLight)
                            .monospaced()
                    }
                    .font(.subheadline)
                    Slider(value: $light, in: 0...255, step: 1)
                        .tint(.b9xAccent)
                }
            }
        }
    }

    private var applyButton: some View {
        Button {
            apply()
        } label: {
            Text("应用灯效")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.b9xAccent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func apply() {
        let rgb = colors.prefix(4).map { $0.toRGBInt() }
        controller.applyLed(
            type: selectedType,
            period: Int(period),
            colors: rgb,
            light: Int(light),
            colorful: colorful
        )
    }
}

extension Color {
    /// 取 RGB 整数（0xRRGGBB），与协议的 colors 参数一致。
    func toRGBInt() -> Int {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
    }
}
