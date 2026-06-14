import Foundation

/// P9 P0-4: 把 Finder 拖来的文件 / 菜单 Import 选的文件落到 vault 的 raw/。
///
/// 设计要点：
/// 1. 接受 .md / .txt 后缀；其他后缀直接拒绝并报告 unsupported
/// 2. 重名文件加日期后缀（例：note.md → note-2026-06-12.md）绝不覆盖
/// 3. 自动加 frontmatter `processed: false`（架构 doc 0.1: raw 文件必须有这个 flag）
/// 4. 同一导入批次的多个文件加唯一 batch id（写入 frontmatter，方便 dream 之后合并）
/// 5. 已有 frontmatter 的 .md 不会覆盖，保留用户写的 metadata
public enum RawImporter {

    public struct ImportResult: Equatable {
        public let succeeded: [URL]     // 实际写入的路径
        public let editableCopies: [URL] // .md 导入后生成的 notes/ 可编辑副本
        public let skipped: [String]    // 跳过的源（不支持 / 重名加后缀）
        public let failed: [String]     // 出错的源（权限 / IO 错）
    }

    public enum ImportError: Error, LocalizedError {
        case unsupportedExtension(String)
        case noFrontmatterNeeded

        public var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let ext):
                return "不支持的后缀: .\(ext)。只接受 .md / .txt"
            case .noFrontmatterNeeded:
                return "no frontmatter needed"
            }
        }
    }

    /// 默认接受的后缀
    public static let acceptedExtensions: Set<String> = ["md", "txt"]

    /// 把一批文件路径导入到 vault 的 raw/。
    /// - Parameter sourceURLs: Finder 拖来的 / NSOpenPanel 选的 URL
    /// - Parameter vaultRoot: vault 根路径
    /// - Parameter addBatchID: 是否在 frontmatter 写 batch_id（同一批导入打同一 id）
    /// - Returns: 导入结果（成功 / 跳过 / 失败）
    @discardableResult
    public static func importToRaw(sourceURLs: [URL],
                                   vaultRoot: URL,
                                   addBatchID: Bool = true) -> ImportResult {
        let rawDir = vaultRoot.appendingPathComponent("raw", isDirectory: true)
        let notesDir = vaultRoot.appendingPathComponent("notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        ensureRawDirectoryAcceptsImports(rawDir)
        let batchID = "import-\(timestamp())-\(UUID().uuidString.prefix(6))"
        var succeeded: [URL] = []
        var editableCopies: [URL] = []
        var skipped: [String] = []
        var failed: [String] = []

        for src in sourceURLs {
            let ext = src.pathExtension.lowercased()
            guard Self.acceptedExtensions.contains(ext) else {
                skipped.append("\(src.lastPathComponent) (unsupported .\(ext))")
                continue
            }
            do {
                let dest = try uniqueDestination(in: rawDir, original: src.lastPathComponent)
                let content = try String(contentsOf: src, encoding: .utf8)
                let withFrontmatter = addFrontmatterIfNeeded(
                    content: content,
                    originalName: src.lastPathComponent,
                    sourcePath: src.path,
                    batchID: addBatchID ? batchID : nil
                )
                try withFrontmatter.write(to: dest, atomically: true, encoding: .utf8)
                RawReadonlyGuard.makeFileReadonly(dest)
                succeeded.append(dest)
                if ext == "md" {
                    do {
                        let editableDest = try uniqueDestination(in: notesDir, original: src.lastPathComponent)
                        try content.write(to: editableDest, atomically: true, encoding: .utf8)
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: NSNumber(value: 0o644)],
                            ofItemAtPath: editableDest.path
                        )
                        editableCopies.append(editableDest)
                    } catch {
                        failed.append("\(src.lastPathComponent) editable copy failed (\(error.localizedDescription))")
                    }
                }
            } catch {
                failed.append("\(src.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        return ImportResult(succeeded: succeeded, editableCopies: editableCopies, skipped: skipped, failed: failed)
    }

    private static func ensureRawDirectoryAcceptsImports(_ rawDir: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: RawReadonlyGuard.readonlyDirMode)],
                ofItemAtPath: rawDir.path
            )
        } catch {
            FileHandle.standardError.write(Data(
                "[RawImporter] raw/ 目录无法恢复为可导入状态: \(rawDir.path) — \(error.localizedDescription)\n".utf8
            ))
        }
    }

    /// 算 unique 目标路径：同名加日期后缀（绝不覆盖）
    static func uniqueDestination(in dir: URL, original: String) throws -> URL {
        let candidate = dir.appendingPathComponent(original)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // 拆 base / ext
        let url = URL(fileURLWithPath: original)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dateStr = todayString()
        // 第一次冲突：note.md → note-2026-06-12.md
        var attempt = 1
        while true {
            let suffix = ext.isEmpty ? "-\(dateStr)-\(attempt)" : "-\(dateStr)-\(attempt).\(ext)"
            let candidateName = base + suffix
            let candidateURL = dir.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            attempt += 1
            if attempt > 100 {
                throw NSError(domain: "RawImporter", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "重名超过 100 次, 放弃: \(original)"])
            }
        }
    }

    /// 如果 content 还没有 frontmatter（不以下面 `---\n` 开头），加一个 minimal 的
    /// 如果有 frontmatter，按需补 batch_id / source_path 字段
    ///
    /// P1-4 修复 (GUI audit 2026-06-14): 已有 frontmatter 时如果不显式补
    /// `processed: false`, 缺该字段的文件会进 candidate 集, 走老代码 (8h 改动
    /// 之前) 时不能被 FrontmatterScanner 正确分流. 修法: 已有 frontmatter 时
    /// 解析 frontmatter 块, 缺 processed 字段就显式补 `processed: false`.
    /// 不动用户已有的其他字段 (title / tags / source 等), 仅追加.
    static func addFrontmatterIfNeeded(content: String,
                                       originalName: String,
                                       sourcePath: String,
                                       batchID: String?) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("---") {
            // 已有 frontmatter → 解析, 缺 processed 字段就显式补 `processed: false`
            return ensureProcessedFlag(content: content)
        }
        var frontmatter = "---\n"
        frontmatter += "imported_at: \(isoNow())\n"
        frontmatter += "imported_from: \(originalName)\n"
        if let bid = batchID {
            frontmatter += "batch_id: \(bid)\n"
        }
        frontmatter += "processed: false\n"
        frontmatter += "---\n\n"
        return frontmatter + content
    }

    /// P1-4 修复: 已有 frontmatter 时确保有 `processed: false` 字段.
    /// 老实现直接 return content → 缺该字段的文件进 candidate 集时
    /// FrontmatterScanner 不能正确分流.
    /// 解析 frontmatter 块 ([0, closeRange]), 缺 processed 就显式补在
    /// `---` 闭合前的最后一行. 已有 processed: true 保留, 不动.
    private static func ensureProcessedFlag(content: String) -> String {
        // 找 frontmatter 块: ---\n...\n---
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            // 实际上 hasPrefix("---") 保证了第一行是 ---, 但防 double-check
            return content
        }
        // 找闭合 ---
        var closeIdx: Int? = nil
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIdx = i
                break
            }
        }
        guard let closeIdx else { return content }

        let fmLines = Array(lines[1..<closeIdx])
        let hasProcessed = fmLines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("processed:")
        }
        if hasProcessed { return content }  // 用户/前序已加, 保留

        // 缺 processed → 补一行在闭合前
        var newFmLines = fmLines
        newFmLines.append("processed: false")
        var newLines = Array(lines[0..<1])  // ---
        newLines.append(contentsOf: newFmLines)
        newLines.append(contentsOf: Array(lines[closeIdx...]))
        return newLines.joined(separator: "\n")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
