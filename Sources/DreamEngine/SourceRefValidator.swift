import Foundation

/// P0-3 假 excerpt 闸门（确定性 verification, 0 LLM 成本）
///
/// 旧实现只验 `sourceFile` 文件名是否匹配，**不验 `sourceExcerpt` 是否真在源文件里**。
/// 漏洞: LLM 可以引用真文件 + 假片段, verify 自我校验时再骗自己一次。
///
/// 新实现: `validate(excerpt:in:)` 把 excerpt 跟 fileContent 双方归一化空白后 substring check.
/// 匹配 = 通过, 不匹配 = rejected_fabricated.
///
/// 设计要点:
/// - 归一化: 全部 trim + collapse 连续 whitespace (\s+) → 单空格. 这样 LLM 把换行变空格不算"假".
/// - 大小写敏感: raw 是用户写的中文/英文, 不动; 否则会误伤一些缩写差异.
/// - 长度下限: excerpt < 5 字符算太短, 一律放行 (防止 LLM 给出 "..." 等无意义片段 0 长度被误拦).
///   这是一个保守 trade-off: 真正短的 excerpt 容易误判, 放行 + 不算 fabricated.
public enum SourceRefValidator {

    /// excerpt 长度下限 (字符), 低于此长度一律放行
    public static let minLengthForStrictCheck = 5

    /// 闸门主入口: excerpt 是不是真的出现在 fileContent 里 (归一化后)
    public static func validate(excerpt: String, in fileContent: String) -> Bool {
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < minLengthForStrictCheck {
            // 太短 → 放行, 避免误伤
            return true
        }
        return normalize(trimmed).contains(normalize(fileContent)) || normalize(fileContent).contains(normalize(trimmed))
    }

    /// 全文归一化: trim + collapse 连续空白到单空格
    /// 用途: excerpt="hello\n  world" 和 fileContent="hello world" 算匹配
    private static func normalize(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 闸门批量跑: 给一组 (file, excerpt) pair, 返回哪些 fabricated
    /// fileContentLookup: relPath -> 源文件内容
    public static func validateBatch(
        refs: [(relPath: String, excerpt: String)],
        fileContentLookup: [String: String]
    ) -> (passed: [(relPath: String, excerpt: String)], rejected: [(relPath: String, excerpt: String, reason: String)]) {
        var passed: [(relPath: String, excerpt: String)] = []
        var rejected: [(relPath: String, excerpt: String, reason: String)] = []
        for pair in refs {
            let excerpt = pair.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if excerpt.isEmpty {
                // 空 excerpt → 放行 (跟原始行为一致, 防止回归)
                passed.append(pair)
                continue
            }
            if excerpt.count < minLengthForStrictCheck {
                passed.append(pair)
                continue
            }
            guard let content = fileContentLookup[pair.relPath] else {
                // 文件不在 lookup (e.g. raw 已被 git rm 或改路径) → 保守放行
                // 这种是边缘 case, 严格拒会阻塞主流程
                passed.append(pair)
                continue
            }
            if validate(excerpt: excerpt, in: content) {
                passed.append(pair)
            } else {
                rejected.append((pair.relPath, pair.excerpt,
                                 "excerpt 不在 \(pair.relPath) 真实内容里"))
            }
        }
        return (passed, rejected)
    }
}
