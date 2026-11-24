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
    /// 逐颗选色环：12 颗灯珠的颜色（点选改色）。
    @State private var pixelColors: [Color] = Array(repeating: Color(hex: 0x6EE7FF), count: 12)
    @State private var selectedPixel = 0
    @State private var modeLightingNote: String?

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
                previewCard
                colorCard
                pixelRingCard
                speedCard
                brightnessCard
                modeLightingCard
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
                    .glassBackground(Color.b9xAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var effectPickerSheet: some View {
        NavigationStack {
            ScrollView {
                // 同组液态玻璃控件放进一个容器：统一取样、相邻玻璃过渡一致（间距 < 控件间隙，不会融成一块）。
                GlassEffectContainer(spacing: 4) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(LEDDefaults.modes, id: \.id) { mode in
                            Button {
                                selectedType = mode.id
                                if let saved = LEDModeLightingStore.load(for: mode.id) {
                                    colors = saved.colors.map { Color(hex: $0) }
                                    uiSpeed = LEDDefaults.uiSpeed(for: mode.id, raw: saved.period)
                                    brightness = saved.light
                                    colorful = saved.colorful
                                    modeLightingNote = "已载入“\(mode.name)”保存的灯效"
                                } else {
                                    colors = LEDDefaults.colors(for: mode.id)
                                    selectedChip = 0
                                    wheelColor = colors.first ?? .red
                                    colorful = false
                                    modeLightingNote = nil
                                }
                                selectedChip = 0
                                wheelColor = colors.first ?? .red
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
                                .glassBackground((selectedType == mode.id ? Color.b9xAccent : Color.clear), in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(selectedType == mode.id ? .white : .primary)
                            }
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
                        .glassBackground(in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.primary)
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
                    .glassBackground(Color.b9xAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
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

    /// 把灯环的 12 颗颜色（取前 8 颗）发到设备。
    private func applyPixelRing() {
        let rgb = pixelColors.prefix(8).map { $0.toRGBInt() }
        controller.applyLed(
            type: selectedType,
            period: LEDDefaults.speedRaw(for: selectedType, uiSpeed: uiSpeed),
            colors: rgb,
            light: brightness,
            colorful: colorful
        )
    }

    // ------------------------------------------------------------ 实时预览

    /// Canvas 实时预览：先看效果再下发（TimelineView 驱动动画）。
    private var previewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("实时预览")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("先预览，再下发")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                }
                LEDPreviewView(
                    type: selectedType,
                    colors: colors,
                    brightness: brightness,
                    speed: uiSpeed
                )
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                Text("预览只是示意（按当前颜色/速度/亮度模拟），实际效果以散热器为准。改颜色、速度、亮度会立即下发，和以前一样。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ------------------------------------------------------------ 逐颗选色环

    private var pixelRingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("逐颗选色")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("点灯珠改色")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                }
                PixelRingView(colors: $pixelColors, selected: $selectedPixel, wheelColor: wheelColor)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text("已选第 \(selectedPixel + 1) 颗 · \(pixelColors[selectedPixel].hexString)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("点色轮改色，再点灯珠上色")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Button {
                    applyPixelRing()
                } label: {
                    Text("把灯环颜色发到设备")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .glassBackground(in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.primary)
                }
                Text("灯环共 12 颗，下发时取前 8 颗颜色（协议上限 8 色）。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ------------------------------------------------------------ 模式独立灯效

    private var modeLightingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("模式独立灯效")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if LEDModeLightingStore.load(for: selectedType) != nil {
                        Text("已保存")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassBackground(Color.b9xAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color.b9xAccentLight)
                    }
                }
                Text("每个灯效模式可以绑一套自己的灯效（颜色/速度/亮度）。切换模式时自动载入该模式保存的灯效，没保存过就用默认。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = modeLightingNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                // 同组液态玻璃控件放进一个容器：统一取样、相邻玻璃过渡一致（间距 < 控件间隙，不会融成一块）。
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 10) {
                        Button {
                            LEDModeLightingStore.save(LEDProfile(
                                type: selectedType,
                                colors: colors.map { $0.toRGBInt() },
                                period: LEDDefaults.speedRaw(for: selectedType, uiSpeed: uiSpeed),
                                light: brightness,
                                colorful: colorful
                            ))
                            modeLightingNote = "已保存为“\(modeName)”的灯效"
                        } label: {
                            Text("保存为此模式的灯效")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .glassBackground(Color.b9xAccent, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                        }
                        Button {
                            LEDModeLightingStore.remove(for: selectedType)
                            modeLightingNote = "已清除“\(modeName)”保存的灯效，下次切回来用默认"
                        } label: {
                            Text("清除保存")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .glassBackground(in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
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

// ------------------------------------------------------------ 实时预览 + 逐颗选色 + 模式独立灯效

/// 灯效实时预览：TimelineView 驱动，Canvas 画 12 颗灯珠的动画。
/// 按模式给不同的动法（彩虹流动转圈、呼吸/心跳整体明暗、其余按颜色轮换），
/// 只是示意，不代表设备上的精确时序。
struct LEDPreviewView: View {
    var type: Int
    var colors: [Color]
    var brightness: Int
    var speed: Int // 0 慢 / 1 中 / 2 快

    private var dotCount: Int { 12 }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 14
                let speedFactor: Double = [0.5, 1.0, 2.0][min(max(speed, 0), 2)]
                let bright = Double(brightness) / 100.0
                let palette = colors.isEmpty ? [Color(hex: 0x6EE7FF)] : colors
                for i in 0..<dotCount {
                    let angle = Double(i) / Double(dotCount) * 2 * .pi - .pi / 2
                    let point = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                    var color = palette[i % palette.count]
                    var alpha = bright
                    var scale: CGFloat = 1
                    switch type {
                    case 3: // 彩虹流动：颜色沿环转动。
                        let shift = Int(t * 4 * speedFactor) % palette.count
                        color = palette[(i + shift) % palette.count]
                    case 5, 17: // 呼吸 / 心跳：整体明暗脉冲。
                        let pulse = 0.5 + 0.5 * sin(t * 2.5 * speedFactor)
                        alpha = bright * (0.25 + 0.75 * pulse)
                        scale = 0.8 + 0.3 * CGFloat(pulse)
                    case 11: // 长亮：静止。
                        break
                    case 16, 20, 21: // 多色旋转 / 赛博朋克 / 碰撞：逐颗轮亮。
                        let active = Int(t * 6 * speedFactor) % dotCount
                        alpha = (i == active || i == (active + 1) % dotCount) ? bright : bright * 0.25
                    default: // 渐变等：颜色缓慢轮换。
                        let shift = Int(t * 2 * speedFactor) % palette.count
                        color = palette[(i + shift) % palette.count]
                    }
                    let dot = Path(ellipseIn: CGRect(
                        x: point.x - 7 * scale, y: point.y - 7 * scale,
                        width: 14 * scale, height: 14 * scale
                    ))
                    context.fill(dot, with: .color(color.opacity(max(0.05, alpha))))
                }
            }
        }
    }
}

/// 逐颗选色环：12 颗灯珠排成环，点哪颗就把色轮当前颜色涂到哪颗上。
struct PixelRingView: View {
    @Binding var colors: [Color]
    @Binding var selected: Int
    var wheelColor: Color

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size / 2 - 16
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2)
                ForEach(colors.indices, id: \.self) { i in
                    let angle = Double(i) / Double(colors.count) * 2 * .pi - .pi / 2
                    let point = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                    Circle()
                        .fill(colors[i])
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(selected == i ? Color.white : Color.primary.opacity(0.25),
                                        lineWidth: selected == i ? 3 : 1)
                        )
                        .shadow(radius: selected == i ? 4 : 0)
                        .position(point)
                        .onTapGesture {
                            selected = i
                            colors[i] = wheelColor
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 一个模式绑定的灯效（颜色/速度原始值/亮度/多彩开关）。
struct LEDProfile: Codable, Equatable {
    var type: Int
    var colors: [Int]
    var period: Int
    var light: Int
    var colorful: Bool
}

/// 模式独立灯效的本地保存（UserDefaults JSON，key 为模式 id）。
enum LEDModeLightingStore {
    static let defaultsKey = "enginecore.ledModeLighting.v1"

    private static func loadAll() -> [String: LEDProfile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: LEDProfile].self, from: data) else {
            return [:]
        }
        return map
    }

    static func load(for type: Int) -> LEDProfile? {
        loadAll()[String(type)]
    }

    static func save(_ profile: LEDProfile) {
        var map = loadAll()
        map[String(profile.type)] = profile
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func remove(for type: Int) {
        var map = loadAll()
        map.removeValue(forKey: String(type))
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
