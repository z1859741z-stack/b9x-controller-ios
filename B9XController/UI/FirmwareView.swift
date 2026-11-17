import SwiftUI

// ------------------------------------------------------------ 固件刷写
//
// 仅红魔 8 Pro 可用。流程照搬原包：核对型号 → 手输确认语 → SHA256 校验 →
// 传输 → 刷后静默重连核对版本。风险文案写明“可能变砖”。
//
// 固件镜像与阶段类型用 Core 的 `FirmwareImage` / `FirmwareStage`
//（Models/FirmwareImage.swift），固件文件在 B9XController/Firmware/。
// 刷写已接入控制器（Telink OTA）：stage/progress 直接读控制器，
// “开始刷写”调 `controller.startFirmwareFlash(image:consent:)`。
// 本 App 目前只支持飞智 B9X，型号核对在当前构建里恒为“不支持”。

struct FirmwareView: View {
    @EnvironmentObject private var controller: CoolerController

    /// 原包确认语（firmware.consentPhrase），以控制器上的静态常量为准。
    static let consentPhrase = CoolerController.firmwareConsentPhrase

    @State private var selectedImage: FirmwareImage?
    @State private var consentInput = ""
    @State private var showResult = false
    @State private var resultMessage = ""

    /// 刷写阶段与进度直接读控制器（单事实来源）。
    private var stage: FirmwareStage { controller.firmwareStage }
    private var progress: Double { controller.firmwareProgress }

    private var state: CoolerState { controller.state }

    /// 包内自带的三版固件（8.4.7 官方 / 8.5.2R5 标准 / 8.5.3R5 超频），
    /// 以控制器在启动时载入的为准，空时回退到直接读包。
    private var bundledImages: [FirmwareImage] {
        controller.firmwareImages.isEmpty ? FirmwareImage.bundledImages() : controller.firmwareImages
    }

    /// 仅红魔 8 Pro 可刷。本 App 目前只接飞智 B9X，此处恒为 false，
    /// 进页即提示不支持；红魔通道由 Core 接入后此判断自动放行。
    private var isRedMagic8Pro: Bool {
        let name = state.deviceName
        return name.contains("RedMagic") && name.contains("8 Pro")
    }

    private var consentMatches: Bool {
        consentInput == Self.consentPhrase
    }

    private var canStart: Bool {
        isRedMagic8Pro && selectedImage != nil && consentMatches && !stageIsActive(stage)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("固件刷写")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                riskCard
                if !isRedMagic8Pro {
                    unsupportedCard
                } else {
                    modelCard
                    imageCard
                    consentCard
                    progressCard
                    Button(action: startFlash) {
                        Text(stageIsActive(stage) ? "刷写进行中…" : "开始刷写")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(canStart ? Color.b9xAccent : Color.b9xCard2)
                            .foregroundStyle(canStart ? .white : Color.b9xTextDim)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canStart)
                    if stageIsActive(stage) {
                        Button("取消刷写", role: .destructive, action: cancelFlash)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("固件刷写")
        .navigationBarTitleDisplayMode(.inline)
        .alert("刷写结果", isPresented: $showResult) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    // ------------------------------------------------------------ 阶段文案（Core 的 FirmwareStage 只有 displayName）

    private func stageIsActive(_ stage: FirmwareStage) -> Bool {
        switch stage {
        case .idle, .failed, .cancelled: return false
        default: return true
        }
    }

    private func stageDetail(_ stage: FirmwareStage) -> String {
        switch stage {
        case .idle: return "选好固件并输入确认语后开始。"
        case .preparing: return "正在准备刷写环境，请保持 App 在前台。"
        case .validating: return "正在做 SHA256 校验，确认固件完整无损。"
        case .transferring: return "正在把固件传给散热器，别断开蓝牙、别切后台。"
        case .submitting: return "正在让设备写入固件。"
        case .deviceAccepted: return "设备已接受固件，正在写入。"
        case .transferred: return "固件已传完，设备正在重启生效。"
        case .waitingForDevice: return "设备重启中，正在静默重连并核对版本。"
        case .failed(let message): return message
        case .cancelled: return "刷写已取消，设备不受影响。"
        }
    }

    // ------------------------------------------------------------ 风险与型号

    private var riskCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("刷固件有风险，可能变砖")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Text("刷写中途断开蓝牙、切后台、手机没电，都可能导致散热器无法启动（变砖），且不在保修范围内。刷之前请确认电量充足、蓝牙稳定、全程保持 App 在前台。刷写前会先做 SHA256 校验，刷完会静默重连并核对版本号。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unsupportedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("当前设备不支持刷固件")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Text("固件刷写仅支持红魔 8 Pro。当前连接的是 \(state.deviceName.isEmpty ? "未连接的设备" : state.deviceName)，不在支持范围内。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("下面是刷写流程说明（仅供了解，当前无法操作）：核对型号 → 手输确认语 → SHA256 校验 → 传输 → 刷后静默重连核对版本。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(FirmwareImage.bundledFileNames, id: \.file) { entry in
                        HStack {
                            Text("\(entry.version) \(entry.kind.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(entry.file)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }
            }
        }
    }

    private var modelCard: some View {
        GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("型号核对")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("已连接：\(state.deviceName) · 当前固件 \(state.firmwareVersion.isEmpty ? "未知" : state.firmwareVersion)")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
        }
    }

    // ------------------------------------------------------------ 选固件 / 确认语 / 进度

    private var imageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("选择固件")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if bundledImages.isEmpty {
                    Text("固件文件未打包进 App：请把 B9XController/Firmware/*.bin 加进 App target 再试。")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(bundledImages) { image in
                    Button {
                        selectedImage = image
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(image.name)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                Text("\(image.kind.displayName) · \(image.size / 1024)KB")
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Spacer()
                            if selectedImage?.id == image.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.b9xAccentLight)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                Text("8.4.7 为官方原版；8.5.2R5 为标准版；8.5.3R5 为超频版（支持更高转速，风险也更高）。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var consentCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("手输确认语")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("请一字不差地输入下面这句话，输不对不让刷：")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                Text("“\(Self.consentPhrase)”")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.b9xCard2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                TextField("在此输入确认语", text: $consentInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !consentInput.isEmpty && !consentMatches {
                    Text("和确认语对不上，请一字不差地重输（注意标点）。")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if consentMatches {
                    Text("确认语正确，可以开始刷写。")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text("传输前会对固件做 SHA256 校验：校验不过直接拒绝，不会往设备里写。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("刷写进度")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(stage.displayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(stageIsActive(stage) ? Color.b9xAccentLight : Color.b9xTextDim)
                }
                ProgressView(value: progress)
                    .tint(.b9xAccent)
                Text(stageDetail(stage))
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ------------------------------------------------------------ 刷写

    private func startFlash() {
        guard let image = selectedImage, consentMatches else { return }
        Task {
            await controller.startFirmwareFlash(image: image, consent: consentInput)
            switch controller.firmwareStage {
            case .failed(let message):
                resultMessage = message
                showResult = true
            case .transferred, .waitingForDevice, .deviceAccepted:
                resultMessage = "固件已传完，设备正在重启生效，稍后会静默重连并核对版本。"
                showResult = true
            case .cancelled:
                resultMessage = "刷写已取消，设备不受影响。"
                showResult = true
            default:
                break
            }
        }
    }

    private func cancelFlash() {
        controller.cancelFirmwareFlash()
    }
}
