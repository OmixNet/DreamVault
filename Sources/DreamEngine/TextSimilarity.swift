// P3-1: 字符 trigram Jaccard 相似度 — 用于 durable 同质合并 (§1.1 评审修复)
// 不用 embedding, 0 依赖, 中文/英文/混合都 OK
import Foundation

/// P3-1: 字符 trigram (3 字符 sliding window) Jaccard 相似度
///
/// 为什么 trigram + Jaccard:
/// - 中文友好: 不分词, 字符粒度就够
/// - O(n) 计算, 大文件秒返
/// - 鲁棒: 标点/空白不敏感 (normalize 后算)
/// - 阈值 0.5 平衡 (防漏检 / 防误合)
///
/// 替代方案 (评审 §4.1 提的 NLEmbedding) — P3-6 才会做, P3-1 先用简单字符版 ship
public enum TextSimilarity {
    /// 归一化 (lowercase + collapse whitespace + 去标点)
    public static func normalize(_ s: String) -> String {
        var out = s.lowercased()
        // collapse whitespace
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // 保留: 字母数字 + 空格 + CJK (U+4E00 - U+9FFF)
        var kept = ""
        kept.reserveCapacity(out.utf8.count)
        for scalar in out.unicodeScalars {
            // ASCII letters/digits
            if (0x30...0x39).contains(scalar.value) ||  // 0-9
               (0x41...0x5a).contains(scalar.value) ||  // A-Z (lowercased 已是小写)
               (0x61...0x7a).contains(scalar.value) {  // a-z
                kept.unicodeScalars.append(scalar)
            } else if scalar.value == 0x20 {  // space
                kept.unicodeScalars.append(scalar)
            } else if (0x4E00...0x9FFF).contains(scalar.value) {  // CJK
                kept.unicodeScalars.append(scalar)
            }
            // 其他 (标点 / emoji / CJK extension) 一律去掉
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }

    /// 算 trigram set
    public static func trigrams(_ s: String) -> Set<String> {
        let norm = normalize(s)
        guard norm.count >= 3 else { return [norm] }  // 短字符串兜底
        var out: Set<String> = []
        let chars = Array(norm)
        for i in 0...(chars.count - 3) {
            let tri = String(chars[i..<(i + 3)])
            out.insert(tri)
        }
        return out
    }

    /// Jaccard 相似度 = |A ∩ B| / |A ∪ B|
    /// 返 0.0 (完全无重合) ~ 1.0 (完全相同)
    public static func jaccard(_ a: String, _ b: String) -> Double {
        let setA = trigrams(a)
        let setB = trigrams(b)
        if setA.isEmpty && setB.isEmpty { return 1.0 }  // 都空 → 视为相同
        if setA.isEmpty || setB.isEmpty { return 0.0 }
        let inter = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(inter) / Double(union)
    }

    /// 阈值: Jaccard >= 0.6 视为同质 (经验值, 防"SwiftUI vs AppKit" 这种部分重叠被误合)
    /// 0.5 太松 — "swiftui 用于 macos 桌面 ui" vs "appkit 用于 macos 桌面 ui" 共享
    /// "用于 macos 桌面 ui" 算 0.5, 应区分 (不同 UI 框架). 0.6 是经验上更稳的点.
    public static let mergeThreshold: Double = 0.6
}
