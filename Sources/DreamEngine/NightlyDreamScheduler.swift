import Foundation
import AppKit

/// P3-T9: 注册 / 取消 launchd 定时任务。
///
/// 路径选择（P8 修正）：**用户级 LaunchAgent**（写 `~/Library/LaunchAgents/` + `launchctl bootstrap gui/<uid>`），
/// 不是系统级（`/Library/LaunchDaemons/`，需 root + SMAppService helper binary）。
///
/// - 当前实现已经可用：写 plist + `launchctl bootstrap` / `bootout`。
/// - 注释里之前那段"stub / 应该用 SMAppService"是 P3 时期的占位文本。P8 文档
///   修正：DreamVault 是**用户级笔记 app + 用户级 scheduler**，`launchctl bootstrap`
///   路径是正确选择。SMAppService 主要服务"应用主 daemon / 菜单栏 app 守护进程"
///   这种需要系统级驻留的场景，**对 Nightly dream 反而是过度设计**。
/// - SwiftUI/SMAppService 不是"Swift 推荐就一定合适"。这里不迁 SMAppService，
///   理由：
///   1. SMAppService 注册到 `/Library/LaunchAgents/` (系统级)，跟当前的用户级冲突
///   2. SMAppService 调度粒度有限（agent 触发条件由 plist 决定，复杂日历调度仍要 plist）
///   3. 用户笔记 app 不需要 "always-running" daemon；`launchctl bootstrap gui/<uid>` 的
///      进程模型反而更对：用户退出 GUI → launchd job 跑独立的 `dream` 二进制 → 退出
///
/// - 配套实测脚本：`scripts/test-launchd.sh`（如果存在）会跑一遍 enable / disable / 状态读取
/// - Debug 看 job 是否在跑：`launchctl print gui/<uid>/com.OmixNet.dreamvault.dream`
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
            _ = runLaunchctl(["bootout",
                               "gui/\(getuid())/\(Self.jobLabel)"])
            let bootstrap = runLaunchctl(["bootstrap",
                                          "gui/\(getuid())",
                                          Self.plistPath])
            if bootstrap.exitCode != 0 {
                lastError = bootstrap.userMessage
            }
        } else {
            let bootout = runLaunchctl(["bootout",
                                        "gui/\(getuid())/\(Self.jobLabel)"])
            if bootout.exitCode != 0,
               !bootout.output.localizedCaseInsensitiveContains("No such process"),
               !bootout.output.localizedCaseInsensitiveContains("Could not find service") {
                lastError = bootout.userMessage
            }
            try? fm.removeItem(at: plistURL)
        }
        let status = currentStatus()
        return Status(enabled: status.enabled,
                      nextRunAt: status.nextRunAt,
                      lastRunAt: status.lastRunAt,
                      lastExitCode: status.lastExitCode,
                      lastError: lastError ?? status.lastError)
    }

    /// 读取 plist + launchctl print-cache 给完整状态
    public func currentStatus() -> Status {
        let fm = FileManager.default
        let plistExists = fm.fileExists(atPath: Self.plistPath)
        let launchd = runLaunchctl(["print", "gui/\(getuid())/\(Self.jobLabel)"])
        let launchdLoaded = launchd.exitCode == 0
        let enabled = plistExists && launchdLoaded

        // nextRunAt：从 plist 读 StartCalendarInterval
        var nextRunAt: Date? = nil
        if plistExists,
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

        let statusError: String? = plistExists && !launchdLoaded
            ? "LaunchAgent plist exists but launchd job is not loaded: \(launchd.userMessage)"
            : nil

        return Status(enabled: enabled, nextRunAt: nextRunAt,
                      lastRunAt: lastRunAt, lastExitCode: lastExitCode,
                      lastError: statusError)
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

    private struct LaunchctlResult {
        let exitCode: Int32
        let output: String

        var userMessage: String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "launchctl exited with code \(exitCode)"
            }
            return "launchctl exited with code \(exitCode): \(trimmed)"
        }
    }

    private func runLaunchctl(_ args: [String]) -> LaunchctlResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return LaunchctlResult(exitCode: -1, output: error.localizedDescription)
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return LaunchctlResult(exitCode: p.terminationStatus, output: output)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
