import SwiftUI

/// 型号目录条目（对照原版 DeviceCatalogView / device.catalog）。
/// 联名版名录只对 B9X 有实证（STUDY §4 的 14 个 edition.*），其余型号只列标准版，
/// 不编造联名版名字。红魔 / 黑鲨列出来是为了让用户知道原版支持它们，
/// 但当前版本只控制飞智 B 系列，点选后会明确提示暂不支持。
struct DeviceCatalogEntry: Identifiable, Hashable {
    let id: String
    let brand: String
    let model: String
    let editions: [String]
    let supported: Bool

    var displayName: String { "\(brand) \(model)" }

    static let catalog: [DeviceCatalogEntry] = [
        DeviceCatalogEntry(
            id: "b9x", brand: "飞智", model: "B9X",
            editions: ["标准版", "白色", "黑色", "AG联名", "EVA", "PANDAER", "丹恒·饮月", "凡人修仙传", "原神·丝柯克", "崩坏3", "昔涟", "甘雨", "航海王", "镜流"],
            supported: true
        ),
        DeviceCatalogEntry(id: "b8x", brand: "飞智", model: "B8X", editions: ["标准版"], supported: true),
        DeviceCatalogEntry(id: "b7x", brand: "飞智", model: "B7X", editions: ["标准版"], supported: true),
        DeviceCatalogEntry(id: "b6x", brand: "飞智", model: "B6X", editions: ["标准版"], supported: true),
        DeviceCatalogEntry(id: "rm8pro", brand: "红魔", model: "8 Pro", editions: ["标准版"], supported: false),
        DeviceCatalogEntry(id: "rm6proplus", brand: "红魔", model: "6 Pro+", editions: ["标准版"], supported: false),
        DeviceCatalogEntry(id: "rm6pro", brand: "红魔", model: "6 Pro", editions: ["标准版"], supported: false),
        DeviceCatalogEntry(id: "rm5pro", brand: "红魔", model: "5 Pro", editions: ["标准版"], supported: false),
        DeviceCatalogEntry(id: "bs6pro", brand: "黑鲨", model: "6 Pro", editions: ["标准版"], supported: false),
        DeviceCatalogEntry(id: "bs5pro", brand: "黑鲨", model: "5 Pro", editions: ["标准版", "联名版"], supported: false),
    ]
}

/// 设备页：型号目录 → 扫描连接 → 找不到设备排障 → 已保存设备。
/// 名字精确匹配由 Core 层（BLEManager 的 supportedNames 过滤）做，UI 只展示结果。
struct ConnectView: View {
    @EnvironmentObject private var controller: CoolerController
    @State private var selectedModel: DeviceCatalogEntry? = DeviceCatalogEntry.catalog.first
    @State private var unsupportedNote: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if controller.isConnected && !controller.demoMode {
                    connectedCard
                } else if controller.demoMode {
                    demoCard
                } else {
                    scanCard
                }

                if let error = controller.error {
                    GlassCard {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button("清除") { controller.clearError() }
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xAccentLight)
                        }
                    }
                }

                catalogCard
                savedDeviceCard
                demoEntry
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .alert("暂不支持", isPresented: Binding(
            get: { unsupportedNote != nil },
            set: { if !$0 { unsupportedNote = nil } }
        )) {
            Button("好", role: .cancel) { unsupportedNote = nil }
        } message: {
            Text(unsupportedNote ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("引擎核心 Plus")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                Text("散热器控制、状态查看与自动联动")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
            }
            Spacer()
            Image(systemName: "snowflake.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.b9xAccentLight)
        }
    }

    private var connectedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                    Text("已连接")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(controller.state.deviceName)
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Divider()
                infoRow("固件版本", controller.state.firmwareVersion.isEmpty ? "—" : controller.state.firmwareVersion)
                infoRow("MAC 地址", controller.state.mac.isEmpty ? "—" : controller.state.mac)
                infoRow("连接状态", controller.connection.rawValue)
                Button(role: .destructive) {
                    controller.disconnect()
                } label: {
                    Text("断开连接")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.red)
                        .background(Color.red.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var demoCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(Color.b9xAccentLight)
                        .frame(width: 10, height: 10)
                    Text("演示模式")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Flydigi B9X")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Text("正在用模拟数据预览完整界面，没有连接真实硬件。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                Button {
                    controller.exitDemo()
                } label: {
                    Text("退出演示")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.b9xAccent.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var scanCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("附近的散热器")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if controller.connection == .scanning {
                        ProgressView()
                    }
                }
                if controller.connection == .scanning && controller.devices.isEmpty {
                    Text("正在扫描\(selectedModel?.displayName ?? "飞智 B 系列")…")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                } else if controller.devices.isEmpty {
                    Text("还没找到设备。请确认散热器已上电开机，手机蓝牙已开启。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                    NavigationLink {
                        DeviceTroubleshootingView()
                    } label: {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("找不到设备？按步骤排查")
                                .font(.subheadline)
                        }
                        .foregroundStyle(Color.b9xAccentLight)
                    }
                }
                ForEach(controller.devices) { device in
                    Button {
                        controller.connect(device)
                    } label: {
                        HStack {
                            Image(systemName: "snowflake")
                                .foregroundStyle(Color.b9xAccentLight)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                Text("信号 \(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Spacer()
                            if controller.connection == .connecting {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                Button {
                    if controller.connection == .scanning {
                        controller.stopScan()
                    } else {
                        controller.scan()
                    }
                } label: {
                    Text(controller.connection == .scanning ? "停止扫描" : "扫描设备")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.b9xAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var catalogCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("型号与版本")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("先选型号再扫描；当前版本只控制飞智 B 系列。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                ForEach(DeviceCatalogEntry.catalog) { entry in
                    Button {
                        if entry.supported {
                            selectedModel = entry
                        } else {
                            unsupportedNote = "\(entry.displayName)暂不支持：当前版本只控制飞智 B6X / B7X / B8X / B9X。"
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                Text(entry.editions.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if !entry.supported {
                                Text("暂不支持")
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                            } else if selectedModel?.id == entry.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.b9xAccentLight)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    if entry.id != DeviceCatalogEntry.catalog.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    /// 已保存设备：Core 层只存了上次设备的 UUID（BLEManager.lastDeviceKey），
    /// 没有名字/型号列表，这里只展示“上次连接的设备”一行，不编造名字。
    private var savedDeviceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("已保存设备")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if controller.ble.hasLastDevice() {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上次连接的设备")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text("再次打开 App 会自动连接")
                                .font(.caption)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                        Spacer()
                        Button("连接") {
                            controller.ble.autoConnectLastDevice()
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.b9xAccentLight)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.b9xAccent.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    Text("还没有保存的设备。连接成功后会自动保存，下次打开直接连。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var demoEntry: some View {
        Button {
            controller.enterDemo()
        } label: {
            HStack {
                Image(systemName: "eye")
                Text("没有散热器？进入演示模式看看界面")
                    .font(.subheadline)
            }
            .foregroundStyle(Color.b9xAccentLight)
        }
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
    }
}

// ------------------------------------------------------------ 找不到设备排障页
// 对照原版 DeviceTroubleshootingView：分步骤教用户排查，不只给一句横幅。

struct DeviceTroubleshootingView: View {
    @EnvironmentObject private var controller: CoolerController

    private let steps: [(title: String, body: String)] = [
        ("确认供电", "散热器需要外接供电才能开机、才能被蓝牙发现。建议用 30W 以上 PD 充电头 + 好线供电，检查插头是否插紧。"),
        ("重新插拔", "把散热器电源拔掉，等 5 秒再插上，等指示灯亮起后再点“扫描设备”。"),
        ("退出其他控制软件", "散热器一次只能连一个 App。原版 App 或另一台手机上的控制软件还连着时，这边会一直找不到设备：先在那边彻底断开连接。"),
        ("确认手机蓝牙已开启", "去系统设置 → 蓝牙，确认开关已打开；也可以开关一次蓝牙再重新扫描。"),
        ("靠近设备再扫", "手机离散热器 1 米以内再扫描；金属桌面、其他蓝牙设备多时信号会受干扰。"),
        ("还是找不到", "重启手机蓝牙后重新扫描；如果多台手机都找不到，换一根供电线、换一个充电头再试一次。"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("找不到设备？按下面步骤逐一排查。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    GlassCard {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.b9xAccent)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(step.body)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.b9xTextDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Button {
                    controller.scan()
                } label: {
                    Text("重新扫描")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.b9xAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("找不到设备")
        .navigationBarTitleDisplayMode(.inline)
    }
}
