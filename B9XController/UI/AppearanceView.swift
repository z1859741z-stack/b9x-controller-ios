import SwiftUI

/// 外观页（对照原版 AppearanceView + CardAppearanceView）：
/// 材质三档 + 卡片/按钮透明度滑杆 + 动画时长 + 开屏动画开关 + 默认页面。
/// 外观跟随系统（浅色 / 深色自动切换），不做手动主题切换。
struct AppearanceView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("卡片材质")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        ForEach(CardMaterial.allCases, id: \.self) { material in
                            Button {
                                appearance.cardMaterial = material
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(material.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(material.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(Color.b9xTextDim)
                                    }
                                    Spacer()
                                    if appearance.cardMaterial == material {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.b9xAccentLight)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            if material != CardMaterial.allCases.last {
                                Divider()
                            }
                        }
                        if !GlassSupport.isLiquidGlassAvailable {
                            Text("当前系统使用兼容磨砂效果。")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        } else if appearance.cardMaterial == .glass {
                            Text("当前系统支持液态玻璃。")
                                .font(.caption)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("液态玻璃卡片", isOn: $appearance.glassEnabled)
                            .foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("卡片透明度")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(Int(appearance.cardOpacity * 100))%")
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(Color.b9xAccentLight)
                            }
                            Slider(value: $appearance.cardOpacity, in: 0.3...1.0, step: 0.05)
                                .tint(.b9xAccent)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("按钮透明度")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(Int(appearance.buttonOpacity * 100))%")
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(Color.b9xAccentLight)
                            }
                            Slider(value: $appearance.buttonOpacity, in: 0.3...1.0, step: 0.05)
                                .tint(.b9xAccent)
                            Text("按钮透明度用于首页模式按钮等填充按钮。")
                                .font(.caption)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("界面动画", isOn: $appearance.animationsEnabled)
                            .foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("动画时长")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(String(format: "%.1f 秒", appearance.animationDuration))
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(Color.b9xAccentLight)
                            }
                            Slider(value: $appearance.animationDuration, in: 0.1...1.0, step: 0.05)
                                .tint(.b9xAccent)
                                .disabled(!appearance.animationsEnabled)
                        }
                        Toggle("开屏动画", isOn: $appearance.startupAnimationEnabled)
                            .foregroundStyle(.primary)
                        HStack {
                            Text("打开时默认页面")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Picker("", selection: $appearance.defaultTab) {
                                Text("首页").tag("home")
                                Text("自动化").tag("automation")
                                Text("我的").tag("my")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 210)
                        }
                    }
                }

                Text("外观跟随系统（浅色 / 深色自动切换）。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .contentMargins(.bottom, 16, for: .scrollContent)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}
