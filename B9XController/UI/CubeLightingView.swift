import SwiftUI

// ------------------------------------------------------------ 魔方灯效（黑鲨专属）
//
// 逐帧编辑器（CubeFrame 格子点选颜色）→ 经控制器 sendCubeFrame 下发；
// 多帧序列可保存到本地（UserDefaults）。
//
// 下发已接入控制器（`controller.sendCubeFrame(pixels:)`，红魔专属）。
// 格子尺寸取 5×5（原包 CubeFrame 的具体尺寸静态层未确认，是假设值；
// 按实际尺寸改 `CubeFrame.gridSize` 即可）。

/// 一帧魔方灯效：格子颜色数组（0xRRGGBB，按行优先）。
struct CubeFrame: Codable, Equatable, Identifiable {
    static let gridSize = 5
    static let pixelCount = gridSize * gridSize

    let id: UUID
    var name: String
    var pixels: [UInt32]

    init(name: String, pixels: [UInt32]? = nil) {
        self.id = UUID()
        self.name = name
        self.pixels = pixels ?? Array(repeating: 0x000000, count: Self.pixelCount)
    }

    static let empty = CubeFrame(name: "新帧")
}

/// 多帧序列的本地保存（UserDefaults JSON）。
struct CubeSequenceStore {
    static let defaultsKey = "enginecore.cubeSequence.v1"

    static func load() -> [CubeFrame] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let frames = try? JSONDecoder().decode([CubeFrame].self, from: data) else {
            return []
        }
        return frames
    }

    static func save(_ frames: [CubeFrame]) {
        if let data = try? JSONEncoder().encode(frames) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

struct CubeLightingView: View {
    @EnvironmentObject private var controller: CoolerController

    @State private var frames: [CubeFrame] = CubeSequenceStore.load()
    @State private var selectedFrameIndex = 0
    @State private var selectedColor: Color = .red
    @State private var resultMessage: String?
    @State private var isSending = false

    private var state: CoolerState { controller.state }

    /// 仅黑鲨可用。本 App 目前只接飞智 B9X，此处恒为 false。
    private var isBlackShark: Bool {
        state.deviceName.contains("BlackShark")
    }

    private var currentFrame: CubeFrame? {
        guard frames.indices.contains(selectedFrameIndex) else { return nil }
        return frames[selectedFrameIndex]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("魔方灯效")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isBlackShark {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                                Text("当前设备不支持魔方灯效")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }
                            Text("魔方灯效仅支持黑鲨系列。当前连接的是 \(state.deviceName.isEmpty ? "未连接的设备" : state.deviceName)。下面仍可编辑并保存帧序列，下发需连上黑鲨设备并等 Core 接入。")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xTextDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                editorCard
                framesCard
                Button(action: sendCurrentFrame) {
                    Text(isSending ? "下发中…" : "下发当前帧到设备")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .glassBackground((currentFrame != nil && !isSending ? Color.b9xAccent : Color.clear), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(currentFrame != nil && !isSending ? .white : Color.b9xTextDim)
                }
                .disabled(currentFrame == nil || isSending)
                if let message = resultMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("点格子涂上当前选中的颜色；帧序列保存在本机，可随时回来接着编。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("魔方灯效")
        .navigationBarTitleDisplayMode(.inline)
    }

    // ------------------------------------------------------------ 编辑器

    private var editorCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack {
                    Text(currentFrame?.name ?? "还没有帧")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("新建帧") {
                        frames.append(CubeFrame(name: "第 \(frames.count + 1) 帧"))
                        selectedFrameIndex = frames.count - 1
                        CubeSequenceStore.save(frames)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                }
                if let frame = currentFrame {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: CubeFrame.gridSize), spacing: 6) {
                        ForEach(frame.pixels.indices, id: \.self) { i in
                            Button {
                                frames[selectedFrameIndex].pixels[i] = UInt32(selectedColor.toRGBInt())
                                CubeSequenceStore.save(frames)
                            } label: {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(hex: Int(frame.pixels[i])))
                                    .frame(height: 44)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Text("当前颜色")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Circle()
                            .fill(selectedColor)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                        Text(selectedColor.hexString)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("全黑") {
                            frames[selectedFrameIndex].pixels = Array(repeating: 0, count: CubeFrame.pixelCount)
                            CubeSequenceStore.save(frames)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    }
                } else {
                    Text("点右上角“新建帧”开始编辑。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
                HSVWheelView(color: $selectedColor)
                    .frame(width: 220, height: 220)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var framesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("帧序列（\(frames.count) 帧）")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if frames.isEmpty {
                    Text("还没有保存任何帧。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                } else {
                    ForEach(frames.indices, id: \.self) { i in
                        HStack {
                            Button {
                                selectedFrameIndex = i
                            } label: {
                                HStack {
                                    // 帧缩略：5×5 小格。
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: CubeFrame.gridSize), spacing: 1) {
                                        ForEach(frames[i].pixels.indices, id: \.self) { j in
                                            Color(hex: Int(frames[i].pixels[j]))
                                                .frame(height: 8)
                                        }
                                    }
                                    .frame(width: 52)
                                    Text(frames[i].name)
                                        .font(.subheadline)
                                        .foregroundStyle(selectedFrameIndex == i ? Color.b9xAccentLight : .primary)
                                    if selectedFrameIndex == i {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color.b9xAccentLight)
                                    }
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                frames.remove(at: i)
                                selectedFrameIndex = min(selectedFrameIndex, max(0, frames.count - 1))
                                CubeSequenceStore.save(frames)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sendCurrentFrame() {
        guard let frame = currentFrame else { return }
        controller.sendCubeFrame(pixels: frame.pixels)
        isSending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            isSending = false
            resultMessage = "已发送当前帧（红魔通道，帧结构未验证）。"
        }
    }
}
