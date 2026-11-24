import PhotosUI
import SwiftUI
import UIKit

// ------------------------------------------------------------ LCD 屏显（黑鲨 6 Pro 专属）
//
// 选图 → 预览 → 转 RGB565 → 经控制器 uploadLCD 上传，进度与结果提示。
//
// 上传已接入控制器（`controller.uploadLCD(image:)`，黑鲨 6 Pro 专属）。
// 屏分辨率取 240×240（原包 BlackSharkLCD 的具体尺寸静态层未确认，
// 是假设值；按实际尺寸改 `lcdPixelSize` 即可）。

struct LCDView: View {
    @EnvironmentObject private var controller: CoolerController

    /// 假设的 LCD 分辨率（见文件头注释）。
    static let lcdPixelSize = CGSize(width: 240, height: 240)

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var rgb565Size = 0
    @State private var isUploading = false
    @State private var progress: Double = 0
    @State private var resultMessage: String?
    @State private var uploadSucceeded: Bool?

    private var state: CoolerState { controller.state }

    /// 仅黑鲨 6 Pro 可用。本 App 目前只接飞智 B9X，此处恒为 false。
    private var isBlackShark6Pro: Bool {
        state.deviceName.contains("BlackShark") && state.deviceName.contains("6 Pro")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("自定义屏显")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isBlackShark6Pro {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                                Text("当前设备不支持自定义屏显")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }
                            Text("LCD 自定义屏显仅支持黑鲨 6 Pro。当前连接的是 \(state.deviceName.isEmpty ? "未连接的设备" : state.deviceName)。下面仍可先选图预览转换效果，上传需连上黑鲨 6 Pro 并等 Core 接入上传通道。")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xTextDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                previewCard
                infoCard
                Button(action: upload) {
                    Text(isUploading ? "上传中…" : "上传到散热器")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .glassBackground((selectedImage != nil && !isUploading ? Color.b9xAccent : Color.clear), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(selectedImage != nil && !isUploading ? .white : Color.b9xTextDim)
                }
                .disabled(selectedImage == nil || isUploading)
                if isUploading {
                    ProgressView(value: progress)
                        .tint(.b9xAccent)
                }
                if let message = resultMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle((uploadSucceeded ?? false) ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("自定义屏显")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var previewCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black)
                        .frame(width: 220, height: 220)
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 220, height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.gray)
                            Text("还没有选图")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                    }
                }
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Label("从相册选图", systemImage: "photo.on.rectangle")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .glassBackground(in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.primary)
                }
                .onChange(of: selectedItem) { _, newValue in
                    Task {
                        guard let item = newValue,
                              let data = try? await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { return }
                        await MainActor.run {
                            selectedImage = image
                            rgb565Size = LCDImageCodec.rgb565Size(for: image)
                            resultMessage = nil
                            uploadSucceeded = nil
                        }
                    }
                }
            }
        }
    }

    private var infoCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("转换说明")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("图片会按 \(Int(Self.lcdPixelSize.width))×\(Int(Self.lcdPixelSize.height)) 缩放并转成 RGB565（每像素 2 字节）再上传。转换后约 \(rgb565Size / 1024)KB。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func upload() {
        guard let image = selectedImage else { return }
        // 先本地转码（真实实现），再走上传通道。
        let payload = LCDImageCodec.rgb565(image: image)
        guard !payload.isEmpty else {
            resultMessage = "图片转换失败，换一张图再试。"
            uploadSucceeded = false
            return
        }
        isUploading = true
        progress = 0.1
        resultMessage = nil
        Task { @MainActor in
            let ok = await controller.uploadLCD(image: image)
            isUploading = false
            progress = ok ? 1 : 0
            uploadSucceeded = ok
            resultMessage = ok ? "上传成功，屏显已更新。" : "上传失败：仅黑鲨 6 Pro 可用（当前未连接黑鲨设备），或协议未验证导致设备无响应。"
        }
    }
}

/// 图片 → RGB565（原包 BlackSharkLCD.rgb565 的同款做法：缩放后逐像素打包）。
enum LCDImageCodec {
    static func rgb565(image: UIImage) -> Data {
        let size = LCDView.lcdPixelSize
        let width = Int(size.width)
        let height = Int(size.height)
        guard let cgImage = image.cgImage else { return Data() }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        var out = Data()
        out.reserveCapacity(width * height * 2)
        for i in 0..<(width * height) {
            let r = pixels[i * 4]
            let g = pixels[i * 4 + 1]
            let b = pixels[i * 4 + 2]
            let value = (UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3)
            out.append(UInt8(value >> 8))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    static func rgb565Size(for image: UIImage) -> Int {
        let size = LCDView.lcdPixelSize
        return Int(size.width * size.height * 2)
    }
}
