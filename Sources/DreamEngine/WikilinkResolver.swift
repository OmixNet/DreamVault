import Foundation

/// dreamvault://wikilink/<id> URL → vault 内 .md 文件的解析器。
///
/// 搜索顺序（按 Persister 写盘顺序）：
///   1. wiki/entities/<id>.md
///   2. wiki/concepts/<id>.md
///   3. wiki/syntheses/<id>.md
///   4. wiki/archive/<id>.md
///
/// - id 走 percent-decoding（"some%20id" → "some id"）
/// - 文件不存在 → 返回 nil（不抛错）
/// - scheme / host 不对 → 返回 nil
public enum WikilinkResolver {

    /// dreamvault:// 的 4 个搜索子目录
    public static let subdirs: [String] = [
        "wiki/entities", "wiki/concepts", "wiki/syntheses", "wiki/archive",
    ]

    /// 解析 dreamvault://wikilink/<id> → vault 内的 .md URL；命中失败返回 nil。
    public static func resolve(url: URL, vaultRoot: URL) -> URL? {
        guard url.scheme == "dreamvault", url.host == "wikilink" else { return nil }
        let rawPath = url.path
        let encoded = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        guard !encoded.isEmpty else { return nil }
        // 兼容 percent-encoded（"some%20id"）和 raw 形式
        let id = encoded.removingPercentEncoding ?? encoded
        let fm = FileManager.default
        for sub in subdirs {
            let candidate = vaultRoot.appendingPathComponent(sub).appendingPathComponent(id + ".md")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
