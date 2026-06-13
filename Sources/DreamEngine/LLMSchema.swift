import Foundation

/// P3-5 评审 §4.2 修复: 4 个 LLM 调用统一走结构化输出 (Ollama `format: json_schema`
/// 或 OpenAI `response_format: {type: "json_object"}`). 消灭 `contains("YES")` /
/// `contains("CONFLICT")` 这类解析雷.
///
/// 4 个 schema:
/// - `verify_schema`     → VerifyResponse (YES/NO 二元判定)
/// - `conflict_schema`   → ConflictResponse (OK/CONFLICT/AMBIGUOUS 三元)
/// - `analyze_schema`    → AnalysisResponse (keyEntities + keyConcepts + ...)
/// - `generate_schema`   → DraftListResponse (drafts 数组)
///
/// 设计取舍:
/// - 4 schema 都是 Swift struct (Codable) + JSON Schema dict. Swift 端用 Codable 解析,
///   Ollama/OpenAI 端用 JSON Schema dict 约束生成. 两端共用一份 schema 定义.
/// - 老 mock handler (`MockLLMProvider.defaultHandler`) 仍返 raw text, 由
///   `parseStructured(_:as:)` 容错解析 (跟 `parseDrafts` / `parseConflictAnswer` 同款).
/// - 真实 LLM provider 接 `OllamaNativeProvider` 走 Ollama `/api/chat` 端点 + `format: json_schema`,
///   接 `OllamaProvider` (现版 OpenAI-compat) 用 `response_format: {type: "json_object"}` (无 schema 约束).

// MARK: - 4 schema structs (Codable, 端到端)

// P3-5 schema 1: verify 阶段 (3 步 CoT 闸门 / 2 步 verify)
public struct VerifyResponse: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case yes = "YES"
        case no = "NO"
    }
    public let verdict: Verdict
    public let reasoning: String?

    public init(verdict: Verdict, reasoning: String? = nil) {
        self.verdict = verdict
        self.reasoning = reasoning
    }
}

// P3-5 schema 2: 矛盾检测
public struct ConflictResponse: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case ok = "OK"
        case conflict = "CONFLICT"
        case ambiguous = "AMBIGUOUS"
    }
    public let verdict: Verdict
    public let reasoning: String?

    public init(verdict: Verdict, reasoning: String? = nil) {
        self.verdict = verdict
        self.reasoning = reasoning
    }
}

// P3-5 schema 3: 3 步 CoT analyze 阶段
public struct AnalysisResponse: Codable, Equatable, Sendable {
    public let keyEntities: [String]?
    public let keyConcepts: [String]?
    public let tensionsWithExisting: [String]?
    public let recommendedLessonTexts: [String]?
    public let reasoning: String?
    public let recommendedKind: String?

    public init(keyEntities: [String]? = nil,
                keyConcepts: [String]? = nil,
                tensionsWithExisting: [String]? = nil,
                recommendedLessonTexts: [String]? = nil,
                reasoning: String? = nil,
                recommendedKind: String? = nil) {
        self.keyEntities = keyEntities
        self.keyConcepts = keyConcepts
        self.tensionsWithExisting = tensionsWithExisting
        self.recommendedLessonTexts = recommendedLessonTexts
        self.reasoning = reasoning
        self.recommendedKind = recommendedKind
    }
}

// P3-5 schema 4: 3 步 CoT generate 阶段 (drafts 数组)
public struct DraftListResponse: Codable, Equatable, Sendable {
    public struct DraftItem: Codable, Equatable, Sendable {
        public let text: String?
        public let sourceFile: String?
        public let sourceLine: Int?
        public let sourceExcerpt: String?
        public let decayClassRaw: String?
        public let kind: String?
    }
    public let drafts: [DraftItem]?

    public init(drafts: [DraftItem]? = nil) {
        self.drafts = drafts
    }
}

// MARK: - 4 schema 的 JSON Schema dict (给 Ollama `format: json_schema` 参数)

public enum LLMSchema {
    /// P3-5: 4 个 schema 的名字 (供测试 + 调试用)
    public enum Name: String, Sendable, CaseIterable {
        case verify
        case conflict
        case analyze
        case generate

        public var displayName: String {
            switch self {
            case .verify: return "verify"
            case .conflict: return "conflict"
            case .analyze: return "analyze"
            case .generate: return "generate"
            }
        }
    }

    /// 自动从 system prompt 关键词判 schema.
    /// 跟老 mock defaultHandler 走同款关键词 — 改动一致性.
    public static func detect(fromSystemPrompt system: String) -> Name? {
        if system.contains("事实校验器") || system.contains("verifier") { return .verify }
        if system.contains("互相矛盾") || system.contains("contradict") { return .conflict }
        if system.contains("分析师") || system.contains("analyze") { return .analyze }
        if system.contains("提炼员") || system.contains("draftsjson") { return .generate }
        return nil
    }

    /// Ollama `format: json_schema` 字段需要的 JSON Schema dict.
    /// 返回 [String: Any] 因为 Ollama API 用 dynamic JSON (没 Swift type).
    public static func jsonSchema(for name: Name) -> [String: Any] {
        switch name {
        case .verify:
            return [
                "type": "object",
                "properties": [
                    "verdict": ["type": "string", "enum": ["YES", "NO"]],
                    "reasoning": ["type": "string"],
                ],
                "required": ["verdict"],
            ]
        case .conflict:
            return [
                "type": "object",
                "properties": [
                    "verdict": ["type": "string", "enum": ["OK", "CONFLICT", "AMBIGUOUS"]],
                    "reasoning": ["type": "string"],
                ],
                "required": ["verdict"],
            ]
        case .analyze:
            return [
                "type": "object",
                "properties": [
                    "keyEntities": ["type": "array", "items": ["type": "string"]],
                    "keyConcepts": ["type": "array", "items": ["type": "string"]],
                    "tensionsWithExisting": ["type": "array", "items": ["type": "string"]],
                    "recommendedLessonTexts": ["type": "array", "items": ["type": "string"]],
                    "reasoning": ["type": "string"],
                    "recommendedKind": ["type": "string", "enum": ["entity", "concept", "synthesis"]],
                ],
                "required": ["keyEntities", "keyConcepts", "recommendedKind"],
            ]
        case .generate:
            return [
                "type": "object",
                "properties": [
                    "drafts": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"],
                                "sourceFile": ["type": "string"],
                                "sourceLine": ["type": "integer"],
                                "sourceExcerpt": ["type": "string"],
                                "decayClassRaw": ["type": "string", "enum": ["slow", "normal", "fast"]],
                                "kind": ["type": "string", "enum": ["entity", "concept", "synthesis"]],
                            ],
                            "required": ["text", "sourceFile", "sourceExcerpt"],
                        ],
                    ],
                ],
                "required": ["drafts"],
            ]
        }
    }
}

// MARK: - 容错 parser (跟老 parseAnalysis/parseDrafts/parseConflictAnswer 同款)

public enum StructuredParseError: Error, CustomStringConvertible {
    case decodeFailed(schema: LLMSchema.Name, raw: String, underlying: Error)
    case schemaNotDetected(systemPrompt: String)
    case verdictMissing(schema: LLMSchema.Name, raw: String)

    public var description: String {
        switch self {
        case .decodeFailed(let s, let raw, let err):
            return "[\(s.displayName)] JSON 解析失败: \(err) raw=\(raw.prefix(200))"
        case .schemaNotDetected(let s):
            return "无法从 system prompt 判 schema: \(s.prefix(80))"
        case .verdictMissing(let s, let raw):
            return "[\(s.displayName)] verdict 字段缺失: \(raw.prefix(200))"
        }
    }
}

/// P3-5: 容错解析 LLM 响应 (跟老 stripMarkdownFence + try? decode 同样思路)
/// - 自动剥 ```json 围栏
/// - 自动 trim whitespace
/// - 抛错时带 schema 名 + raw 前 200 字符 (调试用)
public enum StructuredParser {
    public static func parse<T: Decodable>(_ raw: String, as type: T.Type, schema: LLMSchema.Name) throws -> T {
        let cleaned = stripMarkdownFence(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw StructuredParseError.decodeFailed(schema: schema, raw: raw, underlying: NSError(
                domain: "encoding", code: 1, userInfo: [NSLocalizedDescriptionKey: "utf-8 encode failed"]))
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw StructuredParseError.decodeFailed(schema: schema, raw: raw, underlying: error)
        }
    }

    /// 跟 `Consolidator.stripMarkdownFence` 同款
    static func stripMarkdownFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: nl)...])
            } else {
                t = String(t.dropFirst(3))
            }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}
