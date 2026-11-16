import SwiftUI

/// 灯效页（对照原版灯光页）：灯光总开关 + 灯效模式切换 + 色轮选色 +
/// 颜色列表（按模式 min/max，长按删除，恢复默认）+ 速度三档 + 亮度。
/// 点选/改动立即下发，不等“应用”按钮。
struct LEDView: View {
    @EnvironmentObject private var controller: CoolerController

    @State private var selectedType: Int = 3
    @State private var colors: [Color] = LEDDefaults.colors(for: 3)
    @State private var selectedChip = 0
    @State private var wheelColor: Color = .red
    @State private var uiSpeed: Int = 1 // 0 慢 / 1 中 / 2 快，默认中
    @State private var brightness: Int = 100 // 0...100
    @State private var colorful: Bool = false
    @State private var showEffectSheet = false

    private var state: CoolerState { controller.state }

    private var colorRange: (min: Int, max: Int) {
        LEDDefaults.colorRange(for: selectedType)
    }

    private var modeName: String {
        LEDDefaults.modes.first { $0.id == selectedType }?.name
            ?? B9XProtocol.ledTypes[selectedType] ?? "未知灯效"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                lightCard
                effectCard
                colorCard
                speedCard
                brightnessCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("灯光")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadFromState()
        }
        .sheet(isPresented: $showEffectSheet) {
            effectPickerSheet
        }
    }

    private func loadFromState() {
        if LEDDefaults.modes.contains(where: { $0.id == state.ledType }) {
            selectedType = state.ledType
        } else if state.ledType != 0 {
            selectedType = 3
        }
        if !state.ledColors.isEmpty {
            let loaded = state.ledColors.prefix(8).map { Color(hex: $0) }
            colors = Array(loaded)
        } else {
            colors = LEDDefaults.colors(for: selectedType)
        }
        selectedChip = 0
        wheelColor = colors.first ?? .red
        uiSpeed = LEDDefaults.uiSpeed(for: selectedType, raw: state.ledPeriod)
        brightness = min(max(state.ledLight, 0), 100)
        colorful = state.ledColorful
    }

    // ------------------------------------------------------------ 灯光总开关

    private var lightCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("灯光")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(state.lightOn ? "灯光已开启 · \(modeName)" : "灯光已关闭")
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
                Text("*快速连按 2 次散热器开关，可按照顺序切换灯光模式。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ------------------------------------------------------------ 灯效模式

    private var effectCard: some View {
        GlassCard {
            HStack {
                Text("灯效模式")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(modeName)
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                Button {
                    showEffectSheet = true
                } label: {
                    HStack(spacing: 2) {
                        Text("切换")
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.b9xAccent.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var effectPickerSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(LEDDefaults.modes, id: \.id) { mode in
                        Button {
                            selectedType = mode.id
                            colors = LEDDefaults.colors(for: mode.id)
                            selectedChip = 0
                            wheelColor = colors.first ?? .red
                            colorful = false
                            apply()
                            showEffectSheet = false
                        } label: {
                            HStack(spacing: 4) {
                                if selectedType == mode.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                }
                                Text(mode.name)
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(selectedType == mode.id ? Color.b9xAccent : Color.b9xCard2)
                            .foregroundStyle(selectedType == mode.id ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .navigationTitle("灯效模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showEffectSheet = false }
                }
            }
        }
    }

    // ------------------------------------------------------------ 颜色

    private var colorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("颜色")
                    .font(.headline)
                    .foregroundStyle(.primary)
                HSVWheelView(color: $wheelColor)
                    .frame(width: 260, height: 260)
                    .frame(maxWidth: .infinity)
                HStack {
                    Circle()
                        .fill(wheelColor)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                    Text(wheelColor.hexString)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("拖动圆盘选色")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Button {
                    applyCurrentColor()
                } label: {
                    Text("应用当前颜色")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.b9xCard2)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Text("\(colorRange.min)~\(colorRange.max)色；长按色块删除")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                    Spacer()
                    Button("恢复默认") {
                        colors = LEDDefaults.colors(for: selectedType)
                        selectedChip = 0
                        wheelColor = colors.first ?? .red
                        apply()
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.b9xAccent.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(colors.indices, id: \.self) { i in
                            Circle()
                                .fill(colors[i])
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle()
                                        .stroke(selectedChip == i ? Color.b9xAccentLight : Color.primary.opacity(0.2), lineWidth: selectedChip == i ? 3 : 1)
                                )
                                .onTapGesture {
                                    selectedChip = i
                                    wheelColor = colors[i]
                                }
                                .onLongPressGesture {
                                    guard colors.count > colorRange.min else { return }
                                    colors.remove(at: i)
                                    selectedChip = min(selectedChip, colors.count - 1)
                                    wheelColor = colors[selectedChip]
                                    apply()
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if selectedType == 19 {
                    Toggle("多彩律动", isOn: Binding(
                        get: { colorful },
                        set: {
                            colorful = $0
                            apply()
                        }
                    ))
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    /// 把圆盘当前颜色加入列表（未满时追加，满时替换当前选中色块），立即下发。
    private func applyCurrentColor() {
        if colors.count < colorRange.max {
            colors.append(wheelColor)
            selectedChip = colors.count - 1
        } else if !colors.isEmpty {
            colors[selectedChip] = wheelColor
        }
        apply()
    }

    // ------------------------------------------------------------ 速度 / 亮度

    private var speedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("速度")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Picker("", selection: Binding(
                    get: { uiSpeed },
                    set: {
                        uiSpeed = $0
                        apply()
                    }
                )) {
                    Text("慢速").tag(0)
                    Text("中速").tag(1)
                    Text("快速").tag(2)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var brightnessCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("亮度")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(brightness)%")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Color.b9xAccentLight)
                }
                Slider(
                    value: Binding(
                        get: { Double(brightness) },
                        set: {
                            brightness = Int($0)
                            apply()
                        }
                    ),
                    in: 0...100,
                    step: 1
                )
                .tint(.b9xAccent)
                HStack {
                    Text("暗")
                    Spacer()
                    Text("亮")
                }
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
            }
        }
    }

    // ------------------------------------------------------------ 下发

    private func apply() {
        let rgb = colors.map { $0.toRGBInt() }
        controller.applyLed(
            type: selectedType,
            period: LEDDefaults.speedRaw(for: selectedType, uiSpeed: uiSpeed),
            colors: rgb,
            light: brightness,
            colorful: colorful
        )
    }
}

// ------------------------------------------------------------ LED 常量（spec §2）

enum LEDDefaults {
    /// B9X 可用的灯效（无 SMART_ROTATION / THEME）。
    static let modes: [(id: Int, name: String)] = [
        (3, "彩虹流动"), (5, "呼吸"), (6, "渐变"), (4, "光环"),
        (11, "长亮"), (16, "多色旋转"), (17, "心跳"),
        (19, "音乐律动"), (20, "赛博朋克"), (21, "碰撞"),
    ]

    /// 各模式颜色数 min/max。
    static func colorRange(for type: Int) -> (min: Int, max: Int) {
        switch type {
        case 11: return (1, 1) // 常亮
        case 16: return (2, 3) // 多色旋转
        case 17, 19: return (8, 8) // 心跳 / 音乐律动固定 8 色
        case 20: return (1, 8) // 赛博朋克
        default: return (2, 8) // 流光 / 呼吸 / 渐变 / 切换 / 碰撞
        }
    }

    /// 默认 8 色盘（对照原版灯光页色块）。
    static let palette: [Color] = [
        Color(hex: 0xFF0000), Color(hex: 0xFF8000), Color(hex: 0xFFFF00), Color(hex: 0x00FF00),
        Color(hex: 0x00FFFF), Color(hex: 0x0000FF), Color(hex: 0x8000FF), Color(hex: 0xFF0080),
    ]

    static func colors(for type: Int) -> [Color] {
        let range = colorRange(for: type)
        if type == 11 {
            return [Color(hex: 0x6EE7FF)]
        }
        return Array(palette.prefix(range.max))
    }

    /// UI 速度档（0 慢 / 1 中 / 2 快）→ 协议 speedRaw（spec §2）。
    static func speedRaw(for type: Int, uiSpeed: Int) -> Int {
        let s = min(max(uiSpeed, 0), 2)
        switch type {
        case 4, 5, 16: // 切换 / 呼吸 / 多色旋转：[3,5,8]，快→慢
            return [3, 5, 8][2 - s]
        case 6: // 渐变：[6,8,10]
            return [6, 8, 10][2 - s]
        case 21: // 碰撞：[8,5,3]
            return [8, 5, 3][2 - s]
        default: // 其余：慢 115 / 中 58 / 快 1
            return [115, 58, 1][s]
        }
    }

    /// 协议 speedRaw → UI 速度档（进页时反推，匹配不到默认中速）。
    static func uiSpeed(for type: Int, raw: Int) -> Int {
        for s in 0...2 where speedRaw(for: type, uiSpeed: s) == raw {
            return s
        }
        return 1
    }
}

// ------------------------------------------------------------ HSV 色轮

/// HSV 色轮：角向色相 + 径向饱和度（中心白 → 边缘纯色），拖动选色。
/// 色相约定：红在正上方，顺时针增大（与选色计算共用同一约定）。
struct HSVWheelView: View {
    @Binding var color: Color

    private let hueColors: [Color] = [
        .red, .yellow, .green, .cyan, .blue, Color(red: 1, green: 0, blue: 1), .red,
    ]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: size / 2, y: size / 2)
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: hueColors),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        )
                    )
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, .white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                // 选中位置指示。
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                    .shadow(radius: 3)
                    .position(indicatorPosition(center: center, radius: radius))
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        color = colorAt(value.location, center: center, radius: radius)
                    }
            )
        }
    }

    private func hsvOf(_ color: Color) -> (h: Double, s: Double, v: Double) {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    private func indicatorPosition(center: CGPoint, radius: CGFloat) -> CGPoint {
        let hsv = hsvOf(color)
        let angle = CGFloat(hsv.h) * 2 * .pi - .pi / 2
        let r = CGFloat(hsv.s) * radius
        return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }

    private func colorAt(_ location: CGPoint, center: CGPoint, radius: CGFloat) -> Color {
        let dx = location.x - center.x
        let dy = location.y - center.y
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let hue = Double(angle / (2 * .pi))
        let saturation = min(1, Double(sqrt(dx * dx + dy * dy) / radius))
        return Color(hue: hue, saturation: saturation, brightness: 1)
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

    /// "#RRGGBB" 格式。
    var hexString: String {
        String(format: "#%06X", toRGBInt())
    }
}
