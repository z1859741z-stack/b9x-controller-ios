import AVFoundation
import SwiftUI

// ------------------------------------------------------------ 音乐律动
//
// 麦克风采周围声音（AVAudioEngine）→ 本地三频段分析（低/中/高 +
// 灵敏度 + 音量）→ 10 种律动样式 → 经控制器现有 applyLed（type 19，
// 固定 8 色）下发。离开页面即停；音频只在内存里算频段，不保存、不上传。
//
// 需要 8.5.2 / 8.5.3 R4/R5 固件才支持音乐律动灯效；旧固件上灯效
// 可能没反应。另注意：录音要在 Info.plist 里配 NSMicrophoneUsageDescription，
// 否则系统会拒绝录音权限申请（本文件只负责申请与提示，见 permissionNote）。

/// 10 种律动样式（与原包 MusicView 的 10 种同名）。
enum MusicPattern: Int, CaseIterable, Identifiable {
    case bassPulse = 0      // 低音脉冲
    case beatChase          // 节拍追光
    case symphony           // 高低音交响
    case echo               // 节拍回响
    case drumSpread         // 鼓点扩散
    case dualWings          // 双翼声浪
    case fourZone           // 四区频谱
    case starPoints         // 高频星点
    case waveStretch        // 声浪舒展
    case dualPillars        // 双翼音柱

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .bassPulse: return "低音脉冲"
        case .beatChase: return "节拍追光"
        case .symphony: return "高低音交响"
        case .echo: return "节拍回响"
        case .drumSpread: return "鼓点扩散"
        case .dualWings: return "双翼声浪"
        case .fourZone: return "四区频谱"
        case .starPoints: return "高频星点"
        case .waveStretch: return "声浪舒展"
        case .dualPillars: return "双翼音柱"
        }
    }
}

/// 三频段分析结果（0...1，均已做灵敏度缩放）。
struct BandLevels {
    var low: Double = 0
    var mid: Double = 0
    var high: Double = 0
    var volume: Double = 0
}

/// 本地三频段分析器：两路一阶低通拆出低/中/高能量，纯时域算，
/// 不用 FFT，够驱动灯效且开销小。音频不保存。
final class MusicAnalyzer {
    private var lpLow: Double = 0   // ~200Hz 低通
    private var lpMid: Double = 0   // ~2kHz 低通
    private var sampleRate: Double = 44100

    func reset(sampleRate: Double) {
        self.sampleRate = sampleRate
        lpLow = 0
        lpMid = 0
    }

    /// 对一帧单声道采样做频段能量估计。
    func analyze(samples: [Float]) -> BandLevels {
        guard !samples.isEmpty else { return BandLevels() }
        let aLow = 1 - exp(-2 * Double.pi * 200 / sampleRate)
        let aMid = 1 - exp(-2 * Double.pi * 2000 / sampleRate)
        var eLow: Double = 0, eMid: Double = 0, eHigh: Double = 0, eAll: Double = 0
        for s in samples {
            let x = Double(s)
            lpLow += aLow * (x - lpLow)
            lpMid += aMid * (x - lpMid)
            let low = lpLow
            let mid = lpMid - lpLow
            let high = x - lpMid
            eLow += low * low
            eMid += mid * mid
            eHigh += high * high
            eAll += x * x
        }
        let n = Double(samples.count)
        // 能量开方 + 压缩到 0...1（语音/音乐常见幅度下灵敏度适中）。
        func norm(_ e: Double) -> Double {
            min(1, sqrt(e / n) * 4)
        }
        return BandLevels(low: norm(eLow), mid: norm(eMid), high: norm(eHigh), volume: norm(eAll))
    }
}

/// 律动引擎：管 AVAudioEngine 与下发节流（每 150ms 最多发一次灯效帧）。
@MainActor
final class MusicEngine: ObservableObject {
    @Published private(set) var levels = BandLevels()
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var statusMessage = "未开始"

    private var engine: AVAudioEngine?
    private var analyzer = MusicAnalyzer()
    private var lastSendAt = Date.distantPast
    private var time: Double = 0

    var pattern: MusicPattern = .bassPulse
    var sensitivity: Double = 1.0   // 0.2...3
    var brightness: Int = 100

    /// 申请录音权限并启动。权限被拒时只提示，不崩、不重试循环。
    func start() {
        guard !isRunning else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !granted {
                    self.permissionDenied = true
                    self.statusMessage = "没有录音权限：去“设置 → 引擎核心 Plus → 麦克风”打开后再试。"
                    return
                }
                self.permissionDenied = false
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            analyzer.reset(sampleRate: format.sampleRate)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                guard let channel = buffer.floatChannelData?.pointee else { return }
                let count = Int(buffer.frameLength)
                // 音频线程只拷贝采样；分析放主线程做，避免跨线程碰 analyzer。
                let samples = Array(UnsafeBufferPointer(start: channel, count: count))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleLevels(self.analyzer.analyze(samples: samples))
                }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            isRunning = true
            statusMessage = "正在听周围的声音…"
        } catch {
            statusMessage = "启动录音失败：\(error.localizedDescription)"
        }
    }

    private func handleLevels(_ raw: BandLevels) {
        // 灵敏度缩放 + 平滑（防灯效乱跳）。
        func scaled(_ v: Double) -> Double {
            min(1, v * sensitivity)
        }
        let next = BandLevels(
            low: levels.low * 0.6 + scaled(raw.low) * 0.4,
            mid: levels.mid * 0.6 + scaled(raw.mid) * 0.4,
            high: levels.high * 0.6 + scaled(raw.high) * 0.4,
            volume: levels.volume * 0.6 + scaled(raw.volume) * 0.4
        )
        levels = next
        time += 0.1
        // 下发节流：150ms 一帧。
        guard Date().timeIntervalSince(lastSendAt) >= 0.15 else { return }
        lastSendAt = Date()
        onFrame?(colors(for: next))
    }

    /// 每帧算出的 8 色（0xRRGGBB），由 View 接到后经 controller.applyLed 下发。
    var onFrame: (([Int]) -> Void)?

    /// 按样式把三频段能量画成 8 颗灯珠的颜色。
    func colors(for levels: BandLevels) -> [Int] {
        let t = time
        func rgb(_ hue: Double, _ brightness: Double) -> Int {
            let color = Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.95, brightness: min(1, max(0.08, brightness)))
            return color.toRGBInt()
        }
        func pulse(_ phase: Double) -> Double {
            0.5 + 0.5 * sin(t * 4 + phase)
        }
        switch pattern {
        case .bassPulse:
            let v = 0.25 + levels.low * 0.75
            return (0..<8).map { rgb(0.58 + Double($0) * 0.02, v) }
        case .beatChase:
            return (0..<8).map { i in
                let on = pulse(Double(i) * 0.8) * levels.volume
                return rgb(0.05 + Double(i) * 0.09, 0.15 + on * 0.85)
            }
        case .symphony:
            return (0..<8).map { i in
                let band = i < 4 ? levels.low : levels.high
                return rgb(i < 4 ? 0.62 : 0.08, 0.2 + band * 0.8)
            }
        case .echo:
            let decay = (0..<8).map { pow(0.75, Double($0)) }
            return (0..<8).map { i in
                rgb(0.75, 0.15 + levels.volume * decay[i] * 0.85)
            }
        case .drumSpread:
            let center = 3.5
            return (0..<8).map { i in
                let d = 1 - abs(Double(i) - center) / 4
                return rgb(0.0, 0.15 + levels.low * d * 0.85)
            }
        case .dualWings:
            return (0..<8).map { i in
                let side = i < 4 ? levels.low : levels.high
                return rgb(i < 4 ? 0.55 : 0.85, 0.2 + side * 0.8)
            }
        case .fourZone:
            let bands = [levels.low, levels.mid, levels.high, levels.volume]
            return (0..<8).map { i in
                let band = bands[(i / 2) % 4]
                return rgb(Double(i) * 0.12, 0.2 + band * 0.8)
            }
        case .starPoints:
            return (0..<8).map { i in
                let twinkle = (sin(t * 6 + Double(i) * 1.7) > 0.2) ? levels.high : 0.05
                return rgb(0.55 + Double(i) * 0.03, 0.1 + twinkle * 0.9)
            }
        case .waveStretch:
            return (0..<8).map { i in
                let wave = 0.5 + 0.5 * sin(t * 2 + Double(i) * 0.6)
                return rgb(0.45 + wave * 0.15, 0.15 + (levels.mid * 0.6 + wave * 0.4) * 0.8)
            }
        case .dualPillars:
            return (0..<8).map { i in
                let pillar = i % 2 == 0 ? levels.low : levels.high
                return rgb(i % 2 == 0 ? 0.6 : 0.1, 0.2 + pillar * 0.8)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        engine = nil
        isRunning = false
        levels = BandLevels()
        statusMessage = "已停止"
    }
}

struct MusicView: View {
    @EnvironmentObject private var controller: CoolerController
    @StateObject private var engine = MusicEngine()
    @State private var pattern: MusicPattern = .bassPulse
    @State private var sensitivity: Double = 1.0
    @State private var brightness: Int = 100

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("音乐律动")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundStyle(Color.b9xAccentLight)
                            Text(engine.isRunning ? "律动进行中" : "未开始")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button(engine.isRunning ? "停止" : "开始聆听") {
                                if engine.isRunning {
                                    engine.stop()
                                } else {
                                    engine.pattern = pattern
                                    engine.sensitivity = sensitivity
                                    engine.brightness = brightness
                                    engine.start()
                                }
                            }
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.b9xAccent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Text(engine.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                        if engine.permissionDenied {
                            Button("去设置打开麦克风权限") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.subheadline)
                        }
                        Text("需要 8.5.2 / 8.5.3 R4/R5 固件才支持音乐律动灯效；旧固件上灯效可能没反应。音频只在本地算频段，不保存、不上传。离开本页即停止聆听。")
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                levelCard
                patternCard
                sensitivityCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("音乐律动")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            engine.onFrame = { colors in
                controller.applyLed(type: 19, period: 1, colors: colors, light: engine.brightness, colorful: false)
            }
        }
        .onDisappear {
            engine.stop()
            engine.onFrame = nil
        }
        .onChange(of: pattern) { _, newValue in engine.pattern = newValue }
        .onChange(of: sensitivity) { _, newValue in engine.sensitivity = newValue }
        .onChange(of: brightness) { _, newValue in engine.brightness = newValue }
    }

    private var levelCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("实时频段")
                    .font(.headline)
                    .foregroundStyle(.primary)
                levelRow("低音", value: engine.levels.low, color: .blue)
                levelRow("中音", value: engine.levels.mid, color: .green)
                levelRow("高音", value: engine.levels.high, color: .orange)
                levelRow("音量", value: engine.levels.volume, color: .b9xAccentLight)
            }
        }
    }

    private func levelRow(_ title: String, value: Double, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(width: 40, alignment: .leading)
            ProgressView(value: value)
                .tint(color)
            Text(String(format: "%.0f%%", value * 100))
                .font(.subheadline.monospaced())
                .foregroundStyle(Color.b9xTextDim)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var patternCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("律动样式")
                    .font(.headline)
                    .foregroundStyle(.primary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(MusicPattern.allCases) { item in
                        Button {
                            pattern = item
                        } label: {
                            Text(item.name)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(pattern == item ? Color.b9xAccent : Color.b9xCard2)
                                .foregroundStyle(pattern == item ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    private var sensitivityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("灵敏度")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(format: "%.1fx", sensitivity))
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Color.b9xAccentLight)
                }
                Slider(value: $sensitivity, in: 0.2...3.0, step: 0.1)
                    .tint(.b9xAccent)
                HStack {
                    Text("亮度")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(brightness)%")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Color.b9xAccentLight)
                }
                Slider(value: Binding(
                    get: { Double(brightness) },
                    set: { brightness = Int($0) }
                ), in: 0...100, step: 1)
                .tint(.b9xAccent)
            }
        }
    }
}
