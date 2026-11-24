import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 设置 JSON 文件（ShareLink 导出用；ZIP 格式以后再说）。
struct SettingsExportFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
    }
}

// ------------------------------------------------------------ 备份恢复
// 导出：ShareLink 分享 JSON；导入：文件选择器读 JSON。
// 不含蓝牙连接状态；法律确认记录不随备份导入（LegalText 第 2.5 条）。

struct BackupRestoreView: View {
    @EnvironmentObject private var controller: CoolerController
    @State private var showImport = false
    @State private var importMessage: String?
    @State private var showImportResult = false

    private var exportData: Data {
        (try? JSONEncoder().encode(controller.currentSettingsExport())) ?? Data()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("备份")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("导出当前设置（目标温度、曲线、灯效、模式与保护开关）。不含蓝牙连接状态，法律确认记录也不随备份导入。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            ShareLink(item: SettingsExportFile(data: exportData), preview: SharePreview("引擎核心 Plus 设置", image: Image(systemName: "square.and.arrow.up"))) {
                                Label("导出设置", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .glassBackground(Color.b9xAccent.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(.primary)
                            }
                            Button {
                                showImport = true
                            } label: {
                                Label("导入设置", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .glassBackground(Color.b9xAccent.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(.primary)
                            }
                        }
                        Text("ZIP 格式备份以后再说，目前只支持 JSON 设置文件。")
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("恢复前请注意")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("导入会覆盖现有设置，并在下次连接时影响模式与灯效。请确认备份来源后再导入。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("备份恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first,
                      let data = try? Data(contentsOf: url),
                      let settings = try? JSONDecoder().decode(B9XSettingsExport.self, from: data) else {
                    importMessage = "导入失败：文件格式不对"
                    showImportResult = true
                    return
                }
                controller.applySettingsImport(settings)
                importMessage = "设置已导入"
                showImportResult = true
            case .failure(let error):
                importMessage = "导入失败：\(error.localizedDescription)"
                showImportResult = true
            }
        }
        .alert("备份恢复", isPresented: $showImportResult) {
            Button("好", role: .cancel) { showImportResult = false }
        } message: {
            Text(importMessage ?? "")
        }
    }
}

// ------------------------------------------------------------ 通知与实时活动
// 开关项即可，不做小组件扩展（小组件/灵动岛需扩展 target，后续版本再做）。

struct NotificationSettingsView: View {
    @AppStorage("notifyOnDisconnect") private var notifyOnDisconnect = false
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var notifyStatus = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("散热器断连时发通知", isOn: Binding(
                            get: { notifyOnDisconnect },
                            set: { newValue in
                                if newValue {
                                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                                        DispatchQueue.main.async {
                                            notifyOnDisconnect = granted
                                            notifyStatus = granted ? "已授权" : "未授权，请去系统设置里允许通知"
                                        }
                                    }
                                } else {
                                    notifyOnDisconnect = false
                                    notifyStatus = ""
                                }
                            }
                        ))
                        .foregroundStyle(.primary)
                        if !notifyStatus.isEmpty {
                            Text(notifyStatus)
                                .font(.caption)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("锁屏实时活动", isOn: $appearance.liveActivityEnabled)
                            .foregroundStyle(.primary)
                        Text("实时活动与灵动岛需小组件扩展，后续版本实现；这里先留开关。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("通知与实时活动")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 系统信息

struct SystemInfoView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(spacing: 0) {
                        infoRow("软件版本", AppInfo.versionString)
                        Divider()
                        infoRow("系统版本", "iOS \(UIDevice.current.systemVersion)")
                        Divider()
                        infoRow("最低支持", "iOS 17.0")
                        Divider()
                        infoRow("设备", UIDevice.current.model)
                        Divider()
                        infoRow("Bundle ID", AppInfo.bundleID)
                    }
                }
                Text("版本与系统信息只读展示。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("系统信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.b9xTextDim)
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 8)
    }
}

// ------------------------------------------------------------ 语言
// 仅简体中文：跟随系统 / 简体中文，两个选项实际都是中文。

struct LanguageView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(AppLanguage.allCases, id: \.self) { option in
                            Button {
                                appearance.language = option
                            } label: {
                                HStack {
                                    Text(option.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if appearance.language == option {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.b9xAccentLight)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            if option != AppLanguage.allCases.last {
                                Divider()
                            }
                        }
                    }
                }
                Text("当前版本仅提供简体中文。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 媒体背景
// 选图 + 遮罩滑杆：图片存 Application Support，遮罩盖在背景图上。

struct MediaBackgroundView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var saveFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("应用背景")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if let image = appearance.backgroundImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            Text("未设置背景图，使用系统背景色。")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                        HStack(spacing: 10) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label("选择图片", systemImage: "photo")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .glassBackground(Color.b9xAccent.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(.primary)
                            }
                            if appearance.hasCustomBackground {
                                Button(role: .destructive) {
                                    appearance.clearBackgroundImage()
                                } label: {
                                    Text("清除")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .glassBackground(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("壁纸遮罩")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(Int(appearance.mediaDimming * 100))%")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(Color.b9xAccentLight)
                        }
                        Slider(value: $appearance.mediaDimming, in: 0...0.8, step: 0.05)
                            .tint(.b9xAccent)
                        Text("遮罩越深，背景图越暗、文字越清楚。")
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("媒体背景")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, newValue in
            guard let item = newValue else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    saveFailed = true
                    return
                }
                if !appearance.saveBackgroundImage(image) {
                    saveFailed = true
                }
            }
        }
        .alert("保存失败", isPresented: $saveFailed) {
            Button("好", role: .cancel) { saveFailed = false }
        } message: {
            Text("背景图保存失败，请换一张图片再试。")
        }
    }
}
