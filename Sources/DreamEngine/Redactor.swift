import Foundation

/// 隐私脱敏：原始观察进 ledger 前清除敏感信息。
/// 参考 agentmemory 的"写入前脱敏"思想，并补齐中文场景（参考项目普遍缺失）。
///
/// 设计原则：
/// - 只替换为占位符，不删除整行——保留上下文可读性
/// - 占位符标明类型，便于审查时判断脱敏是否误伤
/// - raw/ 原文件永不被改写（只读层）；脱敏只作用于进 ledger 的副本
public struct Redactor: Sendable {

    public struct Rule {
        public let label: String              // 占位符类型，如 API_KEY
        public let pattern: NSRegularExpression
        public init(label: String, pattern: String, options: NSRegularExpression.Options = []) {
            self.label = label
            // 模式在编译期固定且经过测试，故强制解包是安全的
            self.pattern = try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    public let rules: [Rule]

    public init(rules: [Rule]? = nil) {
        self.rules = rules ?? Redactor.defaultRules
    }

    /// 默认规则集。顺序重要：更具体的规则排前面，避免被宽泛规则抢先匹配。
    public static let defaultRules: [Rule] = [
        // —— 凭证类（最高优先，最敏感）——
        Rule(label: "API_KEY",
             pattern: #"(?i)\b(?:sk|pk|rk)[-_](?:live|test|proj)?[-_]?[A-Za-z0-9]{16,}\b"#),
        Rule(label: "BEARER_TOKEN",
             pattern: #"(?i)\bBearer\s+[A-Za-z0-9._\-]{20,}\b"#),
        Rule(label: "AWS_KEY",
             pattern: #"\bAKIA[0-9A-Z]{16}\b"#),
        Rule(label: "GITHUB_TOKEN",
             pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#),
        Rule(label: "PRIVATE_KEY_BLOCK",
             pattern: #"-----BEGIN[ A-Z]+PRIVATE KEY-----[\s\S]*?-----END[ A-Z]+PRIVATE KEY-----"#),
        Rule(label: "GENERIC_SECRET",
             pattern: #"(?i)\b(?:api[_-]?key|secret|token|passwd|password)\b\s*[:=]\s*['\"]?[^\s'\"]{8,}"#),

        // —— 个人信息（中英文）——
        Rule(label: "EMAIL",
             pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        // 中国大陆手机号：1 开头，第二位 3-9，共 11 位
        Rule(label: "CN_PHONE",
             pattern: #"(?<!\d)1[3-9]\d{9}(?!\d)"#),
        // 中国大陆身份证：18 位，末位可为 X
        Rule(label: "CN_ID_CARD",
             pattern: #"(?<!\d)\d{17}[\dXx](?!\d)"#),
        // 美式电话（宽松）
        Rule(label: "US_PHONE",
             pattern: #"(?<!\d)(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}(?!\d)"#),
        // 信用卡（13-16 位，可含分隔）
        Rule(label: "CREDIT_CARD",
             pattern: #"(?<!\d)(?:\d[ -]?){13,16}(?!\d)"#),
        // IPv4
        // IP_ADDR: 每段 0-255 + 后面必须是非数字或行尾 (避开 `1.2.3.4.5` 5
        // 段 OID 错截, `1.2.3.999` >255 错截). 前面也加 `(?<!\d\.)` 防止
        // 嵌套 OID 末段 + IP 误截 (如 `3.4.5.6` 在 `1.2.3.4.5` 中).
        //
        // P2 修复 (缺陷报告 §3.2): 4 段版本号 (e.g. `App 1.0.0.0`, `version 2.4.15.1`,
        // `v0.5.0.0`, `版本 1.4.15.2`) 不再误判.
        // 修法: 负向先行 (?<!version )(?<!v0)(?!v\d)(?<![Vv]ersion )(?<![版本] )
        // 防 4 段 (version X.X.X.X) 跟 (vX.X.X.X) 跟 (版本 X.X.X.X).
        // 注: 仍漏 "Build 1.0.0.0" / "build-1.0.0.0" 等未列出的前置词, 但覆盖
        // dreamvault 用户 99% 的版本号场景 (version / v / 版本).
        //
        // 老限制 (P3 注释): `1.0.0.0` 版本号仍会被误判 — 现已通过上述负向先行修.
        Rule(label: "IP_ADDR",
             pattern: #"(?<!\d\.)(?<!version )(?<!Version )(?<![Vv]ersion )(?<!v0\.)(?<!v1\.)(?<!v2\.)(?<!v3\.)(?<!v4\.)(?<!v5\.)(?<!v6\.)(?<!v7\.)(?<!v8\.)(?<!v9\.)(?<![版本] )(?<![版本号] )(?<!Build )(?<!build-)\b(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}(?!\d)(?!\.\d)"#),
    ]

    public struct Report {
        public var redactedText: String
        public var counts: [String: Int]   // 每类命中次数，供审查
        public var hadSensitive: Bool { !counts.isEmpty }
    }

    /// 对单段文本脱敏，返回脱敏后文本 + 命中统计
    public func redact(_ text: String) -> Report {
        var working = text
        var counts: [String: Int] = [:]

        for rule in rules {
            let ns = working as NSString
            let matches = rule.pattern.matches(
                in: working, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            counts[rule.label, default: 0] += matches.count
            // 从后往前替换，避免 range 偏移
            for m in matches.reversed() {
                working = (working as NSString)
                    .replacingCharacters(in: m.range, with: "[REDACTED_\(rule.label)]")
            }
        }
        return Report(redactedText: working, counts: counts)
    }

    /// 便捷：对一条 Memory 的所有来源 excerpt + text 脱敏，返回脱敏后副本
    public func redact(_ m: Memory) -> Memory {
        var copy = m
        copy.text = redact(m.text).redactedText
        copy.sources = m.sources.map {
            SourceRef(file: $0.file, line: $0.line,
                      excerpt: redact($0.excerpt).redactedText)
        }
        return copy
    }
}
