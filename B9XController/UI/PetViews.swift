import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ------------------------------------------------------------ 桌宠
//
// 导入桌宠 ZIP 包（UIDocumentPickerViewController 选 .zip）→ 用自研
// ZipArchive 解包 → PetManifest 清单解析 → PetPlayer + PetCanvas 播放。
// PetOverlayView 是浮在设备页上的桌宠层（集成由协调员做，本文件只交付组件）。
// 注意：本文件不碰 HomeView / DeviceView。

/// 桌宠导入页：选包、看清单、播预览、进设置。
struct PetView: View {
    @StateObject private var player = PetPlayer()
    @State private var settings = PetSettings.load()
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var importInfo: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("桌宠")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                statusCard
                previewCard
                Button {
                    showPicker = true
                } label: {
                    Label("导入桌宠包（.zip）", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .glassBackground(Color.b9xAccent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                if player.package != nil {
                    Button("移除当前桌宠包", role: .destructive) {
                        player.unload()
                        settings.packageName = nil
                        settings.save()
                        importInfo = nil
                    }
                    .buttonStyle(.glass)
                    .font(.subheadline)
                }
                Button {
                    showSettings = true
                } label: {
                    Label("桌宠设置", systemImage: "gearshape")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .glassBackground(in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.primary)
                }
                Text("桌宠是应用内覆盖层，不是系统悬浮窗。点按桌宠开面板、拖动可以移动、拖到底部关闭。包过大（>32MB）或动作帧超限（>300 帧）会拒绝导入。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("桌宠")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            PetDocumentPicker { url in
                importPackage(from: url)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                PetSettingsView(settings: $settings, player: player)
            }
        }
        .alert("导入失败", isPresented: $showError) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onDisappear {
            player.stop()
        }
    }

    private var statusCard: some View {
        GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.packageName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(importInfo ?? (player.package == nil ? "还没有导入桌宠包" : "已导入，点击下方预览可切换动画"))
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.enabled },
                    set: {
                        settings.enabled = $0
                        settings.save()
                        if $0 { player.play(animation: player.currentAnimation) } else { player.stop() }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    private var previewCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                PetCanvas(player: player, scale: settings.scale)
                    .frame(height: 220)
                if !player.animationNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(player.animationNames, id: \.self) { name in
                                Button(name) {
                                    player.play(animation: name)
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassBackground((player.currentAnimation == name ? Color.b9xAccent : Color.clear), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(player.currentAnimation == name ? .white : .primary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func importPackage(from url: URL) {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let package = try PetPackage.load(data: data, fileName: url.lastPathComponent)
            player.load(package: package)
            settings.packageName = package.fileName
            settings.enabled = true
            settings.save()
            let frames = package.manifest.totalFrames
            importInfo = "已导入“\(package.manifest.name)”（\(package.manifest.animations.count) 个动画，共 \(frames) 帧）"
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// ------------------------------------------------------------ 文件选择器

struct PetDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.zip], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// ------------------------------------------------------------ 画布

/// 桌宠画布：显示当前帧，按设置缩放；无包时显示占位。
struct PetCanvas: View {
    @ObservedObject var player: PetPlayer
    var scale: Double = 1.0

    var body: some View {
        ZStack {
            if let image = player.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "pawprint.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.b9xTextDim)
                    Text(player.package == nil ? "还没有桌宠" : "加载中…")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ------------------------------------------------------------ 悬浮层（交付给协调员集成到设备页）

/// 浮在设备页上的桌宠层：点按开面板、拖动移动、拖到底部关闭。
/// 用法（协调员集成）：`PetOverlayView(player:settings:)` 叠在设备页 ZStack 顶层。
struct PetOverlayView: View {
    @EnvironmentObject private var controller: CoolerController
    @ObservedObject var player: PetPlayer
    @Binding var settings: PetSettings

    @State private var showPanel = false
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private var state: CoolerState { controller.state }

    var body: some View {
        GeometryReader { geo in
            let baseX = settings.positionX * geo.size.width
            let baseY = settings.positionY * geo.size.height
            ZStack {
                if settings.enabled, player.package != nil {
                    PetCanvas(player: player, scale: settings.scale)
                        .frame(width: 120, height: 120)
                        .position(
                            x: min(max(baseX + dragOffset.width, 60), geo.size.width - 60),
                            y: min(max(baseY + dragOffset.height, 60), geo.size.height - 60)
                        )
                        .opacity(isDragging ? 0.7 : 1)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isDragging = true
                                    dragOffset = value.translation
                                }
                                .onEnded { value in
                                    isDragging = false
                                    let endY = baseY + value.translation.height
                                    if endY > geo.size.height - 80 {
                                        // 拖到底部关闭。
                                        settings.enabled = false
                                        settings.save()
                                        player.stop()
                                    } else {
                                        settings.positionX = min(max((baseX + value.translation.width) / geo.size.width, 0.05), 0.95)
                                        settings.positionY = min(max(endY / geo.size.height, 0.05), 0.95)
                                        settings.save()
                                    }
                                    dragOffset = .zero
                                }
                        )
                        .onTapGesture {
                            showPanel = true
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showPanel) {
            petPanelSheet
        }
    }

    /// 面板：电源/灯光/模式/连接，点按真实执行（调控制器现有方法）。
    private var petPanelSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                PetCanvas(player: player, scale: settings.scale)
                    .frame(height: 160)
                metricRow
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(settings.visibleControls, id: \.self) { key in
                        panelButton(for: key)
                    }
                }
                .padding(.horizontal, 20)
                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle(player.packageName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showPanel = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var metricRow: some View {
        HStack(spacing: 8) {
            ForEach(settings.visibleMetrics, id: \.self) { key in
                VStack(spacing: 2) {
                    Text(metricTitle(for: key))
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                    Text(metricValue(for: key))
                        .font(.subheadline.bold().monospaced())
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .glassBackground(in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 20)
    }

    private func metricTitle(for key: String) -> String {
        PetManifest.availableMetricKeys.first { $0.key == key }?.name ?? key
    }

    private func metricValue(for key: String) -> String {
        switch key {
        case "coldPlate": return String(format: "%.1f°C", state.temperatureValue)
        case "rpm": return "\(state.speed)"
        case "power": return "\(state.coldPercent)%"
        case "mode": return state.displayModeName
        case "firmware": return state.firmwareVersion.isEmpty ? "--" : state.firmwareVersion
        default: return "--"
        }
    }

    @ViewBuilder
    private func panelButton(for key: String) -> some View {
        switch key {
        case "power":
            // 当前构建没有独立的散热器关机指令：电源键映射为超频开关
            // （Freeze 开/关），是现有 API 里最接近“电源”的开关。
            Button {
                controller.setFreezeEnabled(!state.freezeMode)
            } label: {
                panelLabel(icon: "power", title: "电源", subtitle: state.freezeMode ? "超频开" : "超频关")
            }
        case "light":
            Button {
                controller.setLightEnabled(!state.lightOn)
            } label: {
                panelLabel(icon: "lightbulb.fill", title: "灯光", subtitle: state.lightOn ? "已开" : "已关")
            }
        case "mode":
            Button {
                cycleMode()
            } label: {
                panelLabel(icon: "snowflake", title: "模式", subtitle: state.displayModeName)
            }
        case "connect":
            Button {
                if controller.isConnected {
                    controller.disconnect()
                } else {
                    controller.scan()
                }
            } label: {
                panelLabel(icon: "bluetooth", title: "连接", subtitle: controller.isConnected ? "断开" : "扫描")
            }
        default:
            EmptyView()
        }
    }

    private func panelLabel(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.b9xAccentLight)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassBackground(in: RoundedRectangle(cornerRadius: 14))
    }

    private func cycleMode() {
        // 智能 → 手动 → 自定义曲线 → 智能。
        switch state.runMode {
        case B9XProtocol.modeSmart:
            controller.setManualPreset(state.manualPreset)
        case B9XProtocol.modeManual:
            controller.setCustomCurve(state.customLevels)
        default:
            controller.setSmartPreset(state.smartPreset)
        }
    }
}

// ------------------------------------------------------------ 桌宠设置

struct PetSettingsView: View {
    @Binding var settings: PetSettings
    @ObservedObject var player: PetPlayer

    var body: some View {
        List {
            Section("显示") {
                Toggle("启用桌宠", isOn: Binding(
                    get: { settings.enabled },
                    set: {
                        settings.enabled = $0
                        settings.save()
                        if $0 { player.play(animation: player.currentAnimation) } else { player.stop() }
                    }
                ))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("缩放")
                        Spacer()
                        Text(String(format: "%.1fx", settings.scale))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Color.b9xAccentLight)
                    }
                    Slider(value: $settings.scale, in: 0.5...2.0, step: 0.1) { _ in
                        settings.save()
                    }
                }
                Button("重置位置") {
                    settings.positionX = 0.5
                    settings.positionY = 0.75
                    settings.save()
                }
                .buttonStyle(.glass)
            }
            Section("面板上显示的参数") {
                ForEach(PetManifest.availableMetricKeys, id: \.key) { item in
                    Toggle(item.name, isOn: Binding(
                        get: { settings.visibleMetrics.contains(item.key) },
                        set: { on in
                            if on {
                                if !settings.visibleMetrics.contains(item.key) {
                                    settings.visibleMetrics.append(item.key)
                                }
                            } else {
                                settings.visibleMetrics.removeAll { $0 == item.key }
                            }
                            settings.save()
                        }
                    ))
                }
            }
            Section("面板上的控制按钮") {
                ForEach(PetManifest.availableControlKeys, id: \.key) { item in
                    Toggle(item.name, isOn: Binding(
                        get: { settings.visibleControls.contains(item.key) },
                        set: { on in
                            if on {
                                if !settings.visibleControls.contains(item.key) {
                                    settings.visibleControls.append(item.key)
                                }
                            } else {
                                settings.visibleControls.removeAll { $0 == item.key }
                            }
                            settings.save()
                        }
                    ))
                }
            }
            if let name = settings.packageName {
                Section("当前包") {
                    Text(name)
                    if let manifest = player.package?.manifest {
                        Text("\(manifest.animations.count) 个动画 · 共 \(manifest.totalFrames) 帧 · 清单版本 \(manifest.version)")
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
            }
        }
        .navigationTitle("桌宠设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
