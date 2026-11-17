import SwiftUI

// ------------------------------------------------------------ 主题
// v2：全 App 跟随系统外观。卡片/背景/次要文字一律用系统语义色，
// 亮色暗色都好看；只有强调色（蓝/青）与设备示意图保持固定配色。

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

    /// 页面背景：跟随系统。
    static let b9xBackground = Color(.systemBackground)
    /// 卡片背景：跟随系统。
    static let b9xCard = Color(.secondarySystemBackground)
    /// 卡片内次级背景（未选中按钮等）：跟随系统。
    static let b9xCard2 = Color(.tertiarySystemBackground)
    /// 强调蓝。
    static let b9xAccent = Color(hex: 0x5B8CFF)
    /// 强调青：亮色下用深一点的蓝，暗色下用亮青，保证两边都看得清。
    static let b9xAccentLight = Color(UIColor { trait in
        if trait.userInterfaceStyle == .dark {
            return UIColor(red: 0x6E / 255, green: 0xE7 / 255, blue: 0xFF / 255, alpha: 1)
        }
        return UIColor(red: 0x0B / 255, green: 0x5E / 255, blue: 0xD6 / 255, alpha: 1)
    })
    /// 次要文字：跟随系统。
    static let b9xTextDim = Color.secondary
    /// 底栏选中胶囊：原版冰环 X 是中性灰（实测 B−R≈10），不是蓝色；
    /// 亮色用 systemGray3，暗色用半透明白，照原版明暗走。
    static let tabSelectionFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.22)
            : UIColor.systemGray3
    })
}

    /// 液态玻璃是否可用：最低部署目标就是 iOS 26，本机上恒为 true；
/// 保留这个判断是为了在外观页里按原版文案显示降级提示分支。
enum GlassSupport {
    static var isLiquidGlassAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

/// 玻璃开关：与底部导航栏共用 sharedLiquidGlass（同一个液态玻璃组件）。
/// 开 = 绿色 tint 玻璃 + 白色圆钮右滑；关 = 无 tint 玻璃 + 圆钮左滑。
/// 圆钮位置跟随绑定值（真实连接态），不做假乐观。
struct GlassToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.75)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .frame(width: 51, height: 31)
                    .sharedLiquidGlass(in: Capsule(), tint: isOn ? .green.opacity(0.55) : nil)
                Circle()
                    .fill(.white)
                    .frame(width: 27, height: 27)
                    .padding(2)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("连接开关")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

/// 圆角卡片（对照原版卡片样式），材质跟随外观设置：
/// 液态玻璃 → .glassEffect；磨砂模糊 → .ultraThinMaterial；普通 → 纯色 + 透明度滑杆。
struct GlassCard<Content: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            switch appearance.effectiveMaterial {
            case .glass:
                content
                    .padding(16)
                    .glassEffect(
                        .regular.tint(Color(.secondarySystemBackground).opacity(1 - appearance.cardOpacity)),
                        in: RoundedRectangle(cornerRadius: 20)
                    )
            case .frosted:
                content
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .background(
                        Color.b9xCard.opacity(appearance.cardOpacity * 0.35),
                        in: RoundedRectangle(cornerRadius: 20)
                    )
            case .plain:
                content
                    .padding(16)
                    .background(
                        Color.b9xCard.opacity(appearance.cardOpacity),
                        in: RoundedRectangle(cornerRadius: 20)
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)
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
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(String(format: "%.1f", temperature))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("°C")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.b9xTextDim)
                }
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

/// 数值滑杆：连续值，标题行显示“标题 数值 · 百分比”，不显示电压。
/// 拖动中 onChange 实时回调，松手时 onEditingEnded 再回调一次做确认。
struct ValueSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let display: String
    let onChange: (Double) -> Void
    let onEditingEnded: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(display)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Color.b9xAccentLight)
            }
            Slider(
                value: value,
                in: range,
                step: step,
                onEditingChanged: { editing in
                    dragging = editing
                    if !editing {
                        onEditingEnded(value.wrappedValue)
                    }
                }
            )
            .tint(.b9xAccent)
            .onChange(of: value.wrappedValue) { _, newValue in
                if dragging {
                    onChange(newValue)
                }
            }
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
                    .foregroundStyle(.primary)
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

/// 散热器示意图：圆形金属外圈 + 网纹 + 中央 Y 形标志（对照原版截图，
/// 不要只放雪花）。这是产品图示，配色固定，不跟随系统。
struct CoolerImageView: View {
    var body: some View {
        ZStack {
            // 金属外圈。
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xF2F3F5), Color(hex: 0xC9CDD4), Color(hex: 0x9AA0AB)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // 内盘。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x4A5262), Color(hex: 0x232833)],
                        center: .center,
                        startRadius: 8,
                        endRadius: 62
                    )
                )
                .padding(7)
            // 网纹：同心圆 + 放射线，裁成圆形。
            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1)
                        .rotationEffect(.degrees(Double(i) * 15))
                }
                ForEach([18, 30, 42, 54], id: \.self) { r in
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        .frame(width: CGFloat(r) * 2, height: CGFloat(r) * 2)
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(Circle())
            // Y 形标志。
            YMarkShape()
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: 0x8FB7FF), Color(hex: 0x3D6FE0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 44, height: 52)
            // 左上高光。
            Circle()
                .trim(from: 0.55, to: 0.8)
                .stroke(Color.white.opacity(0.55), lineWidth: 3)
                .padding(4)
        }
    }
}

/// Y 形标志路径（归一化 0...1 坐标内绘制）。
struct YMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let topY = rect.minY + rect.height * 0.04
        let midY = rect.minY + rect.height * 0.52
        let bottomY = rect.maxY - rect.height * 0.04
        let leftX = rect.minX + rect.width * 0.06
        let rightX = rect.maxX - rect.width * 0.06
        let midX = rect.midX
        p.move(to: CGPoint(x: leftX, y: topY))
        p.addLine(to: CGPoint(x: midX, y: midY))
        p.addLine(to: CGPoint(x: rightX, y: topY))
        p.move(to: CGPoint(x: midX, y: midY))
        p.addLine(to: CGPoint(x: midX, y: bottomY))
        return p
    }
}

// ------------------------------------------------------------ 液态玻璃封装

extension View {
    /// 全 App 唯一的液态玻璃组件（iOS 26 .glassEffect(.regular)，带折射与高光）。
    /// 底部导航栏与首页“连接”开关（GlassToggle）共用这一份，不走外观设置的
    /// 磨砂回退，背板透明、不垫白色，保证两者质感完全一致。
    func sharedLiquidGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if let tint {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.glassEffect(.regular, in: shape)
        }
    }

    /// 按外观设置给任意形状套材质（卡片用圆角矩形，底栏用胶囊）。
    @ViewBuilder func appearanceMaterial<S: Shape>(_ shape: S) -> some View {
        let appearance = AppearanceSettings.shared
        switch appearance.effectiveMaterial {
        case .glass:
            self.glassEffect(.regular, in: shape)
        case .frosted:
            self.background(.ultraThinMaterial, in: shape)
        case .plain:
            self.background(Color.b9xCard.opacity(appearance.cardOpacity), in: shape)
        }
    }

    /// 底栏专用：真正的液态玻璃（原版是圆角矩形、不是全胶囊）。
    @ViewBuilder func tabBarGlass() -> some View {
        self.sharedLiquidGlass(in: RoundedRectangle(cornerRadius: 16))
    }

    /// 旧入口（兼容）：按开关决定用液态玻璃还是超薄材质。
    @ViewBuilder func conditionalGlass(_ enabled: Bool) -> some View {
        if enabled {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: .capsule)
        }
    }
}
