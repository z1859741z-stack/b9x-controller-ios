import SwiftUI

/// 法律确认记录：条款版本 + 确认时间 + 阅读语言，存 UserDefaults，
/// 不随设置备份导入（LegalText 第 2.5 条）。
/// 注意：LegalText.version 只是展示标签“条款版本”，不是版本号；
/// 条款版本号由这里的 currentTermsVersion 维护，条款实质变更时改它就会重新提示。
enum LegalConsentStore {
    static let currentTermsVersion = "1.0"

    private enum Key {
        static let acceptedVersion = "legal.acceptedTermsVersion"
        static let acceptedAt = "legal.acceptedAt"
        static let acceptedLanguage = "legal.acceptedLanguage"
    }

    static var isAccepted: Bool {
        UserDefaults.standard.string(forKey: Key.acceptedVersion) == currentTermsVersion
    }

    static func recordAcceptance(language: String = "zh-Hans") {
        let defaults = UserDefaults.standard
        defaults.set(currentTermsVersion, forKey: Key.acceptedVersion)
        defaults.set(Date(), forKey: Key.acceptedAt)
        defaults.set(language, forKey: Key.acceptedLanguage)
    }

    static var acceptedAt: Date? {
        UserDefaults.standard.object(forKey: Key.acceptedAt) as? Date
    }
}

// ------------------------------------------------------------ 关于作者
// 只有这一页。绝不要出现抖音主页、支持作者/赞赏、特别鸣谢这三行
//（原版 AuthorView 的定长 TupleView 删不掉行，我们重写后根本不建这三行）。

struct AuthorView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(spacing: 12) {
                        Image("BearLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        Text(LegalText.authorRole)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text(LegalText.authorSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("反馈")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(LegalText.authorFeedback)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("z1859741z@gmail.com", destination: URL(string: "mailto:z1859741z@gmail.com")!)
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("关于作者")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 开源与许可

struct LicensesView: View {
    /// 我们实际用的框架（任务指定列表）。
    private let frameworks = ["SwiftUI", "CoreBluetooth", "AppIntents", "Charts", "AVFoundation", "CryptoKit"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LegalText.license_subtitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(LegalText.license_nativeCode)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(LegalText.license_systemFrameworks)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("系统框架")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        ForEach(frameworks, id: \.self) { name in
                            HStack {
                                Text(name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("Apple 系统框架")
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            if name != frameworks.last {
                                Divider()
                            }
                        }
                        Text("第三方组件的版权与许可声明，仍照各组件自己的规矩保留（LegalText 第 22 条）。")
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("开源与许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 用户协议与免责声明
// LegalText.sections 33 条全文渲染，标题 + 正文，顺序不动，一字不改。

struct LegalDocumentView: View {
    /// 我的页里打开时为 true：只读重看，不修改已保存的确认记录。
    var readOnly = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(LegalText.intro)
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(LegalText.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(section.body)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(LegalText.footer)
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                if readOnly {
                    Text(LegalText.readOnlyFooter)
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle(LegalText.navTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 首启法律门（全屏）

/// 首次启动全屏出协议：“同意并继续”才启动蓝牙连接；
/// “暂不同意”进 declined 状态，不启动设备连接。
struct LegalConsentView: View {
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(LegalText.title)
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Text(LegalText.intro)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(LegalText.sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(section.body)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text(LegalText.footer)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                VStack(spacing: 10) {
                    Button {
                        onAccept()
                    } label: {
                        Text(LegalText.accept)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.b9xAccent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        onDecline()
                    } label: {
                        Text(LegalText.decline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.primary.opacity(0.08))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .background(Color.b9xBackground)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// 暂不同意后的状态页：不启动设备连接，可重新阅读条款再决定。
struct LegalDeclinedView: View {
    var onReadAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("BearLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 24))
            Text(LegalText.declinedTitle)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text(LegalText.declinedBody)
                .font(.subheadline)
                .foregroundStyle(Color.b9xTextDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            Button {
                onReadAgain()
            } label: {
                Text(LegalText.readAgain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.b9xAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 40)
            Spacer()
        }
        .background(Color.b9xBackground)
    }
}
