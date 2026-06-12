// P2-6: ripgrep 桥接 — Process 启动 rg, parse 输出 [file:line:text] 三段
import Foundation

/// P2-6: ripgrep 桥接
///
/// ripgrep 比 mdfind / Foundation 全文搜都快 + 准 (用 Rust 写的 PCRE2 / regex).
/// 默认路径:
///   - /opt/homebrew/bin/rg (Apple Silicon)
///   - /usr/local/bin/rg     (Intel Mac)
///   - $PATH 里 `which rg` (env PATH 兜底)
///
/// 输出格式: `path:line:content` (默认 ripgrep --no-heading)
public enum RipgrepBridge {
    /// 候选 rg 路径 (按优先顺序)
    public static let candidatePaths = [
        "/opt/homebrew/bin/rg",
        "/usr/local/bin/rg",
        "/opt/local/bin/rg"
    ]

    /// 找可用的 rg 路径, 找不到返 nil
    public static func locateRipgrep() -> String? {
        for p in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        // 兜底: 走 which
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["rg"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8) ?? ""
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public struct Hit: Equatable, Sendable {
        public let file: String
        public let line: Int
        public let text: String
        public init(file: String, line: Int, text: String) {
            self.file = file
            self.line = line
            self.text = text
        }
    }

    /// 跑 ripgrep
    /// - Parameters:
    ///   - query: 搜索关键字 (literal, 不走 regex)
    ///   - root: vault 根 (递归搜)
    ///   - maxResults: 上限, 默认 200
    ///   - rgPath: rg 路径 (默认自动定位)
    /// - Returns: hits 数组, 失败返 nil (调用方回退 Foundation 路径)
    public static func search(query: String,
                             root: URL,
                             maxResults: Int = 200,
                             rgPath: String? = nil) -> [Hit]? {
        guard !query.isEmpty else { return [] }
        let path = rgPath ?? locateRipgrep()
        guard let rg = path else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rg)
        // -F: 固定字符串 (literal, 不当 regex)
        // -n: 显示行号
        // --no-heading: 单行输出, 易解析
        // --max-count=1: 每文件最多 1 hit (snippet 够)
        // -g '*.md': 只搜 md
        // -g '!wiki/concepts/': 排除 dream 生成的 wiki 页 (避免查 memory hit)
        p.arguments = [
            "-F",
            "-n",
            "--no-heading",
            "--max-count", "1",
            "-g", "*.md",
            "-g", "!wiki/concepts/",
            "-g", "!wiki/entities/",
            "-g", "!wiki/syntheses/",
            "-g", "!wiki/archive/",
            "-g", "!.dream/**",
            query,
            root.path
        ]
        let out = Pipe()
        p.standardOutput = out
        // rg 在没 hit 时 exit code 1, 走正常
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8) ?? ""
        return parseOutput(s, root: root, maxResults: maxResults)
    }

    /// 解析 ripgrep 输出
    /// 每行: `<relpath>:<line>:<text>`
    /// text 内可能含 `:` (e.g. "08:30 起床"), 所以 split 限 2 次
    public static func parseOutput(_ output: String, root: URL, maxResults: Int = 200) -> [Hit] {
        var hits: [Hit] = []
        let rootPath = root.standardizedFileURL.path
        let lines = output.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            // 限 2 次 split
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 3 else { continue }
            let fileRaw = parts[0]
            guard let lineNum = Int(parts[1]) else { continue }
            let text = parts[2...].joined(separator: ":")
            // fileRaw 是绝对路径 → 切到相对 vault 的 rel
            let rel: String
            if fileRaw.hasPrefix(rootPath + "/") {
                rel = String(fileRaw.dropFirst(rootPath.count + 1))
            } else {
                rel = fileRaw
            }
            hits.append(Hit(file: rel, line: lineNum, text: text))
            if hits.count >= maxResults { break }
        }
        return hits
    }
}
