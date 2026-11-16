import SwiftUI

/// 连接页：扫描 B9X 系列设备并连接。
struct ConnectView: View {
    @EnvironmentObject private var controller: CoolerController

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
                                .foregroundStyle(.white)
                            Spacer()
                            Button("清除") { controller.clearError() }
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xAccentLight)
                        }
                    }
                }

                demoEntry
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("冰环FLY")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                    Spacer()
                    Text(controller.state.deviceName)
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Divider().background(Color.white.opacity(0.1))
                infoRow("固件版本", controller.state.firmwareVersion.isEmpty ? "—" : controller.state.firmwareVersion)
                infoRow("MAC 地址", controller.state.mac.isEmpty ? "—" : controller.state.mac)
                infoRow("连接状态", controller.connection.rawValue)
                Button(role: .destructive) {
                    controller.disconnect()
                } label: {
                    Text("断开连接")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
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
                        .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                    Spacer()
                    if controller.connection == .scanning {
                        ProgressView()
                    }
                }
                if controller.connection == .scanning && controller.devices.isEmpty {
                    Text("正在扫描 B6X / B7X / B8X / B9X…")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                } else if controller.devices.isEmpty {
                    Text("还没找到设备。请确认散热器已上电开机，手机蓝牙已开启。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
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
                                    .foregroundStyle(.white)
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
                .foregroundStyle(.white)
        }
    }
}
