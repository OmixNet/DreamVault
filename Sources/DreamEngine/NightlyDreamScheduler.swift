import Foundation
import AppKit

/// P3-T9: 注册 / 取消 launchd 定时任务。
///
/// 当前实现：写日志 + 用 `launchctl` 调用 launchd。
/// 完整实现：macOS 13+ 用 SMAppService 替代 shell 调用（更干净）。
///
/// 真生产代码应通过 SMAppService：
/// ```swift
/// let service = SMAppService.agent(plistName: "com.OmixNet.dreamvault.dream")
/// if enabled {
///     try await service.register()
/// } else {
///     try await service.unregister()
/// }
/// ```
///
/// 这里为保持 T7 可工作，先 stub：把 enable/disable + vault 路径写到一个本地文件
/// 给后续 launchd job 读。`launchctl` 真注册留给 T9 follow-up。
@MainActor
public final class NightlyDreamScheduler {
    public static let shared = NightlyDreamScheduler()

    /// launchd job label（与 scripts/install.sh 里的 plist 一致）
    public static let jobLabel = "com.OmixNet.dreamvault.dream"
    /// launchd plist 用户路径
    public static let plistPath: String = "\(NSHomeDirectory())/Library/LaunchAgents/\(jobLabel).plist"

    private init() {}

    public func setEnabled(_ enabled: Bool, vaultPath: String) {
        let log = "[\(Self.timestamp())] nightlyDreamEnabled=\(enabled) vault=\(vaultPath)\n"
        let logFile = "\(NSHomeDirectory())/.dreamvault/nightly-scheduler.log"
        try? log.data(using: .utf8)?.write(to: URL(fileURLWithPath: logFile),
                                          options: .atomic)

        // 简易 launchd 注册：用 launchctl bootstrap / bootout
        let fm = FileManager.default
        let agentsDir = "\(NSHomeDirectory())/Library/LaunchAgents"
        try? fm.createDirectory(atPath: agentsDir,
                                withIntermediateDirectories: true)
        let plistURL = URL(fileURLWithPath: Self.plistPath)
        if enabled {
            writePlist(vaultPath: vaultPath, to: plistURL)
            runLaunchctl(["bootstrap",
                          "gui/\(getuid())",
                          Self.plistPath])
        } else {
            runLaunchctl(["bootout",
                          "gui/\(getuid())/\(Self.jobLabel)"])
            try? fm.removeItem(at: plistURL)
        }
    }

    public func currentEnabled() -> Bool {
        FileManager.default.fileExists(atPath: Self.plistPath)
    }

    private func writePlist(vaultPath: String, to url: URL) {
        let dreamBin = Bundle.main.executableURL?.path ?? "/usr/local/bin/dream"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Self.jobLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(dreamBin)</string>
                <string>run</string>
                <string>--vault</string>
                <string>\(vaultPath)</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key><integer>3</integer>
                <key>Minute</key><integer>0</integer>
            </dict>
            <key>StandardOutPath</key><string>\(NSHomeDirectory())/.dreamvault/nightly-stdout.log</string>
            <key>StandardErrorPath</key><string>\(NSHomeDirectory())/.dreamvault/nightly-stderr.log</string>
            <key>RunAtLoad</key><false/>
        </dict>
        </plist>
        """
        try? plist.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
