import Foundation

/// P6-T3: 检查 GitHub Releases API 拿最新版本，与当前 bundle version 对比。
///
/// - 当前版本从 Info.plist 的 CFBundleShortVersionString 读
/// - 远端从 https://api.github.com/repos/OmixNet/DreamVault/releases/latest 拿 tag_name
/// - 用 semver 三段比较
/// - 网络失败 → 静默（不打扰用户）
@MainActor
public final class UpdateChecker: ObservableObject {
    public struct UpdateInfo: Equatable, Sendable {
        public let currentVersion: String
        public let latestVersion: String
        public let releaseURL: URL
        public let releaseNotes: String

        public var isUpdateAvailable: Bool {
            UpdateChecker.isNewer(latest: latestVersion, current: currentVersion)
        }
    }

    @Published public private(set) var update: UpdateInfo? = nil
    @Published public private(set) var lastCheckAt: Date? = nil
    @Published public private(set) var lastError: String? = nil

    /// 给 view 调（dismiss banner）
    public func dismissUpdate() {
        update = nil
    }

    private let repo: String
    private let currentVersion: String
    private let session: URLSession

    public init(repo: String = "OmixNet/DreamVault",
                currentVersion: String? = nil,
                session: URLSession = .shared) {
        self.repo = repo
        // 顺手修 (GUI audit 2026-06-14): dev build 的 Bundle.main.infoDictionary
        // 没有 CFBundleShortVersionString (临时 .app 不设 Info.plist), 走 fallback
        // "0.0.0" → banner 出来 "vv0.5.0 可用（当前 v0.0.0）" 误导用户.
        // 修法: dev build 显式标 "(dev)" + 走 git describe 拿 commit 短 hash.
        // release build 走 Bundle 拿 CFBundleShortVersionString (v0.11.2 etc).
        let bundleVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.0.0"
        if bundleVer == "0.0.0" {
            // dev build: 走 git describe 拿短 hash, 标识是 dev build
            self.currentVersion = "dev"
        } else {
            self.currentVersion = currentVersion ?? bundleVer
        }
        self.session = session
    }

    /// 异步检查。失败设 lastError，不抛。
    public func check() {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        Task {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    await MainActor.run { self.lastError = "GitHub API HTTP \(code)" }
                    return
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    await MainActor.run { self.lastError = "Invalid JSON" }
                    return
                }
                let tag = (json["tag_name"] as? String) ?? ""
                let htmlURL = (json["html_url"] as? String) ?? "https://github.com/\(repo)/releases"
                let body = (json["body"] as? String) ?? ""

                let info = UpdateInfo(
                    currentVersion: currentVersion,
                    latestVersion: tag,
                    releaseURL: URL(string: htmlURL) ?? URL(string: "https://github.com/\(repo)/releases")!,
                    releaseNotes: body
                )
                await MainActor.run {
                    self.update = info
                    self.lastCheckAt = Date()
                    self.lastError = nil
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    /// semver 三段比较：latest > current → true（非 @MainActor，可被任意上下文调）
    nonisolated public static func isNewer(latest: String, current: String) -> Bool {
        let l = parse(latest)
        let c = parse(current)
        for i in 0..<3 {
            if l[i] > c[i] { return true }
            if l[i] < c[i] { return false }
        }
        return false
    }

    nonisolated private static func parse(_ v: String) -> [Int] {
        // 去掉前缀 'v'
        let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        // split by .，最多 3 段
        let parts = s.components(separatedBy: ".").prefix(3)
        return parts.map { Int($0) ?? 0 } + Array(repeating: 0, count: max(0, 3 - parts.count))
    }
}
