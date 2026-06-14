import Foundation

/// P0 致命修复 (缺陷报告 §1.3): FrontmatterScanner 流式按行扫 frontmatter,
/// 避免 String(contentsOf:) 全文读到内存 (5MB 笔记 UI 假死).
///
/// 老实现 (Sources/dream/CLI.swift:160-161, Views.swift, GitStatusBanner, SearchSheet):
///   let content = try? String(contentsOf: f, encoding: .utf8)
///   return content.contains("processed: false")
/// 全文读 + .contains 全文扫, O(file size). 5MB 文件 50-200ms 假死.
///
/// 新实现: InputStream 按 buffer 读, 仅解析 frontmatter 块 (---\n...\n---),
/// 找到 'processed: false' 立即返 true. O(frontmatter size) ≈ O(几十行).
///
/// 设计:
/// - InputStream 流式读 4KB buffer, 不全量加载到内存.
/// - 仅在 frontmatter 块 (---\n 开始, --- 闭合) 内搜索 'processed: false'.
/// - frontmatter 块不可能 > 64KB (实际 < 4KB), 超过返 false (防恶意超大 frontmatter).
/// - 多平台 (macOS/iOS/Linux), 走 Foundation API, 无外部依赖.
public enum FrontmatterScanner {

    /// 流式扫 .md 文件 frontmatter, 找 'processed: false' 立即返 (不读 body).
    /// - Returns: true = frontmatter 里有 'processed: false'
    /// - Returns: false = frontmatter 里没 'processed: false' OR 无 frontmatter OR 文件无法读
    /// - 复杂度: O(frontmatter 行数), 跟文件 body 大小无关.
    public static func hasProcessedFalse(_ url: URL) -> Bool {
        guard let stream = InputStream(url: url) else { return false }
        stream.open()
        defer { stream.close() }

        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        var accumulated = Data()
        let fmStart = Data("---\n".utf8)
        let fmEnd = Data("---".utf8)
        let processedFalseNeedle = Data("processed: false".utf8)
        let maxFrontmatterBytes = 64 * 1024  // 64KB 上限, 防恶意超大 frontmatter

        var sawOpening = false
        var fmStartIdx = 0  // "---\n" 在 accumulated 里的位置

        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: bufSize)
            if n <= 0 { break }
            accumulated.append(buf, count: n)

            // 找 "---\n" 开始
            if !sawOpening, let openRange = accumulated.range(of: fmStart) {
                sawOpening = true
                fmStartIdx = openRange.upperBound
            }

            if sawOpening {
                // 找 "---" 闭合 (从 fmStartIdx 开始, 避开开头)
                if accumulated.count > fmStartIdx + 3,
                   let closeRange = accumulated.range(of: fmEnd, in: fmStartIdx + 3..<accumulated.count) {
                    // 在 [fmStartIdx, closeRange.lowerBound] 范围内找 'processed: false'
                    let fmSlice = accumulated.subdata(in: fmStartIdx..<closeRange.lowerBound)
                    if fmSlice.range(of: processedFalseNeedle) != nil {
                        return true
                    }
                    // 闭合了, 返 false (不管 body)
                    return false
                }
            }

            // 防 OOB
            if accumulated.count > maxFrontmatterBytes {
                return false  // frontmatter 超 64KB, 视为无
            }
        }

        // EOF: 没找到闭合 (无 frontmatter 或闭合缺失), 返 false
        return false
    }

    /// 流式读 frontmatter 整块 (含 --- 头尾) 成 String.
    /// - Returns: frontmatter 内容 (含 --- 头尾) 或 nil (无 frontmatter / 无法读)
    /// - 复杂度: O(frontmatter 行数), 跟文件 body 大小无关.
    public static func readFrontmatter(_ url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        var accumulated = Data()
        let fmStart = Data("---\n".utf8)
        let fmEnd = Data("---".utf8)
        let maxFrontmatterBytes = 64 * 1024

        var sawOpening = false

        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: bufSize)
            if n <= 0 { break }
            accumulated.append(buf, count: n)

            if !sawOpening, let openRange = accumulated.range(of: fmStart) {
                sawOpening = true
                // 找 "---" 闭合 (从 openRange.upperBound 开始)
                if accumulated.count > openRange.upperBound + 3,
                   let closeRange = accumulated.range(of: fmEnd, in: openRange.upperBound + 3..<accumulated.count) {
                    let frontmatterData = accumulated.subdata(in: 0..<closeRange.upperBound)
                    return String(data: frontmatterData, encoding: .utf8)
                }
            }

            if accumulated.count > maxFrontmatterBytes {
                return nil
            }
        }
        return nil
    }
}
