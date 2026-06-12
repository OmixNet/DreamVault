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

    public struct Status: Equatable, Sendable {
        public let enabled: Bool               // plist 文件存在 + launchd 加载
        public let nextRunAt: Date?            // 从 plist 读 StartCalendarInterval
        public let lastRunAt: Date?            // 从 .dream/nightly-stdout.log 推断
        public let lastExitCode: Int?          // 最近一次运行退出码
        public let lastError: String?          // 注册/反注册错误
    }

    public func setEnabled(_ enabled: Bool, vaultPath: String,
                           hour: Int = 3, minute: Int = 0) -> Status {
        var lastError: String? = nil
        let fm = FileManager.default
        let agentsDir = "\(NSHomeDirectory())/Library/LaunchAgents"
        try? fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        let plistURL = URL(fileURLWithPath: Self.plistPath)
        if enabled {
            writePlist(vaultPath: vaultPath, hour: hour, minute: minute, to: plistURL)
            // launchctl bootstrap：旧 job 存在时会失败，先 bootout 一次
            runLaunchctl(["bootout",
                          "gui/\(getuid())/\(Self.jobLabel)"])
            runLaunchctl(["bootstrap",
                          "gui/\(getuid())",
                          Self.plistPath])
        } else {
            runLaunchctl(["bootout",
                          "gui/\(getuid())/\(Self.jobLabel)"])
            try? fm.removeItem(at: plistURL)
        }
        let status = currentStatus()
        return status
    }

    /// 读取 plist + launchctl print-cache 给完整状态
    public func currentStatus() -> Status {
        let fm = FileManager.default
        let enabled = fm.fileExists(atPath: Self.plistPath)

        // nextRunAt：从 plist 读 StartCalendarInterval
        var nextRunAt: Date? = nil
        if enabled,
           let data = try? Data(contentsOf: URL(fileURLWithPath: Self.plistPath)),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let cal = plist["StartCalendarInterval"] as? [String: Any],
           let h = cal["Hour"] as? Int,
           let m = cal["Minute"] as? Int {
            nextRunAt = Self.nextRunDate(hour: h, minute: m)
        }

        // lastRunAt + lastExitCode：从 stdout log 解析
        let stdoutLog = "\(NSHomeDirectory())/.dreamvault/nightly-stdout.log"
        var lastRunAt: Date? = nil
        var lastExitCode: Int? = nil
        if let data = try? String(contentsOfFile: stdoutLog, encoding: .utf8) {
            // 简单解析：最近一行 "Dream done: ... exit=N"
            let lines = data.components(separatedBy: "\n")
            for line in lines.reversed() {
                if line.contains("exit=") {
                    // 找第一个数字
                    let regex = try? NSRegularExpression(pattern: #"exit=(-?\d+)"#)
                    let range = NSRange(line.startIndex..., in: line)
                    if let m = regex?.firstMatch(in: line, range: range),
                       let r = Range(m.range(at: 1), in: line),
                       let n = Int(line[r]) {
                        lastExitCode = n
                    }
                    break
                }
            }
            // 文件 mtime 作 lastRunAt 兜底
            if let attrs = try? fm.attributesOfItem(atPath: stdoutLog),
               let date = attrs[.modificationDate] as? Date {
                lastRunAt = date
            }
        }

        return Status(enabled: enabled, nextRunAt: nextRunAt,
                      lastRunAt: lastRunAt, lastExitCode: lastExitCode,
                      lastError: nil)
    }

    /// 算下一次 h:m 的 Date
    private static func nextRunDate(hour: Int, minute: Int) -> Date? {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let candidate = cal.date(from: components) else { return nil }
        if candidate < now {
            return cal.date(byAdding: .day, value: 1, to: candidate)
        }
        return candidate
    }

    private func writePlist(vaultPath: String, hour: Int, minute: Int, to url: URL) {
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
                <key>Hour</key><integer>\(hour)</integer>
                <key>Minute</key><integer>\(minute)</integer>
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
