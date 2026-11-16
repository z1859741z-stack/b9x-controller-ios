import SwiftUI

// ------------------------------------------------------------ 主题（对照片：深色 + 圆角卡片 + 蓝色强调）

extension Color {
    init(hex: Int, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static let b9xBackground = Color(hex: 0x0A0E16)
    static let b9xCard = Color(hex: 0x151B28)
    static let b9xCard2 = Color(hex: 0x1A2233)
    static let b9xAccent = Color(hex: 0x5B8CFF)
    static let b9xAccentLight = Color(hex: 0x6EE7FF)
    static let b9xTextDim = Color(hex: 0x8A94A6)
}

/// 圆角深色卡片（对照片里的卡片样式）。
struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(Color.b9xCard)
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

/// 制冷面温度环。
struct TemperatureRing: View {
    var temperature: Double
    var targetTemperature: Int
    var speed: Int

    private var progress: Double {
        min(max((temperature + 20) / 60, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(
                    LinearGradient(
                        colors: [.b9xAccentLight, .b9xAccent, Color(hex: 0xA78BFA)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(String(format: "%.1f", temperature))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                + Text("°C")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.b9xTextDim)
                Text("制冷面温度")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                Text("目标 \(targetTemperature)°C · 风扇 \(speed) RPM")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
            }
        }
        .frame(width: 220, height: 220)
    }
}

/// 档位滑杆：按 B9X 档位表 [0, 19, 38, 57, 77, 95, 115, 134] 步进。
struct LevelSlider: View {
    let title: String
    let level: Int
    let onChange: (Int) -> Void

    @State private var index: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(level) · \(B9XProtocol.voltsLabel(level))")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Color.b9xAccentLight)
            }
            Slider(
                value: Binding(
                    get: { Double(B9XProtocol.levels.firstIndex(of: level) ?? 0) },
                    set: { newValue in
                        let idx = Int(newValue)
                        if idx >= 0 && idx < B9XProtocol.levels.count {
                            onChange(B9XProtocol.levels[idx])
                        }
                    }
                ),
                in: 0...Double(B9XProtocol.levels.count - 1),
                step: 1
            )
            .tint(.b9xAccent)
            HStack {
                Text("关")
                Spacer()
                Text("最大")
            }
            .font(.caption)
            .foregroundStyle(Color.b9xTextDim)
        }
        .onAppear {
            index = Double(B9XProtocol.levels.firstIndex(of: level) ?? 0)
        }
    }
}

/// 小统计格。
struct StatCell: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.bold().monospaced())
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.b9xCard2)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// 散热器示意图（圆形 + 雪花，代替产品实拍图）。
struct CoolerImageView: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.05))
            Circle().stroke(Color.white.opacity(0.3), lineWidth: 5)
            Circle().stroke(Color.b9xAccentLight.opacity(0.4), lineWidth: 1).padding(12)
            Image(systemName: "snowflake")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(Color.b9xAccentLight)
        }
    }
}

/// 按开关决定用液态玻璃还是超薄材质（外观设置里的玻璃开关）。
extension View {
    @ViewBuilder func conditionalGlass(_ enabled: Bool) -> some View {
        if enabled {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: .capsule)
        }
    }
}
