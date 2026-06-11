import Foundation

/// 极简 unified diff 生成器（不调外部 diff 工具，纯 Swift LCS）。
///
/// 适用场景：editor 右侧面板显示当前文件 vs HEAD 的差异。文件 < 几千行性能够。
/// 不适用：超大文件（> 50k 行）—— 需要更复杂的 Myers/Hirschberg 算法。
public struct DiffGenerator {

    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case context      // 不变
            case added        // 新增
            case removed     // 删除
        }
        public let kind: Kind
        public let text: String
    }

    public struct Result: Equatable, Sendable {
        public let lines: [Line]
        public let addedCount: Int
        public let removedCount: Int

        /// 没有改动（无 added / removed 行）。lines 仍可能非空（context 行）。
        public var isEmpty: Bool { addedCount == 0 && removedCount == 0 }
    }

    public init() {}

    /// 算两条字符串的 unified diff（逐行）。
    /// 忽略尾部换行差异（"a\n" 和 "a" 视为一致），避免空字符串边界。
    public func diff(old: String, new: String) -> Result {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        let ops = lcs(oldLines, newLines)
        var lines: [Line] = []
        var added = 0
        var removed = 0

        for op in ops {
            switch op {
            case .equal(let s):
                lines.append(Line(kind: .context, text: s))
            case .insert(let s):
                lines.append(Line(kind: .added, text: s))
                added += 1
            case .delete(let s):
                lines.append(Line(kind: .removed, text: s))
                removed += 1
            }
        }
        return Result(lines: lines, addedCount: added, removedCount: removed)
    }

    // MARK: - LCS（标准动态规划 O(m*n)）

    enum Op {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    /// 按行拆分，剥离空字符串的尾部边界，让 "a" 和 "a\n" 等价。
    private func splitLines(_ s: String) -> [String] {
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Longest Common Subsequence + 回溯生成 diff 操作序列
    private func lcs(_ a: [String], _ b: [String]) -> [Op] {
        let m = a.count
        let n = b.count
        if m == 0 { return b.map { .insert($0) } }
        if n == 0 { return a.map { .delete($0) } }

        // dp[i][j] = LCS length of a[0..<i] and b[0..<j]
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if a[i] == b[j] {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i][j + 1], dp[i + 1][j])
                }
            }
        }
        // 回溯
        var ops: [Op] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1] == b[j - 1] {
                ops.append(.equal(a[i - 1]))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                ops.append(.insert(b[j - 1]))
                j -= 1
            } else {
                ops.append(.delete(a[i - 1]))
                i -= 1
            }
        }
        return ops.reversed()
    }
}
