import Foundation

/// YAML frontmatter 解析器（arch doc 不强制 schema，但编辑器要能展示强类型字段）。
///
/// 支持的 YAML 子集（足够覆盖 Obsidian / Tolaria / Hexo / Jekyll 99% 用法）：
///   - `key: string`              → .string
///   - `key: 42` / `key: 3.14`    → .number
///   - `key: true` / `key: false` → .bool
///   - `key: null`                → .null
///   - `key: [a, b, c]`           → .list([String])
///   - `key: [1, 2, 3]`           → .list([Int])
///   - 嵌套 `key:\n  sub: v`      → .object([String: FrontmatterValue])  （一层）
///
/// 不支持：
///   - 引用 `&anchor` / `*alias`（YAML 复杂特性，Obsidian 不用）
///   - 多行字符串 `|` / `>`（不常见；遇到当 string 处理）
///   - tag `!!str` 强制类型（不常见；按值推断）
///
/// 解析失败时降级：
///   - 单行值解析失败 → .string 原文（不抛错）
///   - list 解析失败 → .string 原文
///   - 缺闭合 `---`  → 整体按"无 frontmatter"返回
public struct FrontmatterParser {

    public init() {}

    /// 强类型 frontmatter 值
    public enum Value: Equatable, Sendable, CustomStringConvertible {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case stringList([String])
        case intList([Int])
        case object([String: Value])

        public var description: String {
            switch self {
            case .string(let s): return s
            case .number(let n): return String(n)
            case .bool(let b): return b ? "true" : "false"
            case .null: return "null"
            case .stringList(let xs): return "[" + xs.joined(separator: ", ") + "]"
            case .intList(let xs): return "[" + xs.map(String.init).joined(separator: ", ") + "]"
            case .object(let d): return d.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            }
        }

        /// 兼容旧 API：统一成 String（供编辑器 inspector 等）
        public var asString: String {
            switch self {
            case .string(let s): return s
            case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
            case .bool(let b): return b ? "true" : "false"
            case .null: return ""
            case .stringList(let xs): return xs.joined(separator: ", ")
            case .intList(let xs): return xs.map(String.init).joined(separator: ", ")
            case .object: return "[object]"
            }
        }
    }

    /// 解析结果：frontmatter 字典 + 正文 + 正文起始行（1-based）
    public struct Document: Equatable, Sendable {
        public var fields: [String: Value]   // 保留输入顺序用 [(key, value)]
        public var orderedKeys: [String]      // 首次出现的 key 顺序（arch doc "不强制 schema" 但保留人类可读顺序）
        public var body: String
        public var bodyStartLine: Int        // 1-based，正文第一行在原文件中的行号

        public init(fields: [String: Value], orderedKeys: [String], body: String, bodyStartLine: Int) {
            self.fields = fields
            self.orderedKeys = orderedKeys
            self.body = body
            self.bodyStartLine = bodyStartLine
        }

        public var isEmpty: Bool { orderedKeys.isEmpty }

        /// 按插入顺序返回 (key, value) 对
        public var orderedFields: [(String, Value)] {
            orderedKeys.compactMap { k in fields[k].map { (k, $0) } }
        }
    }

    /// 主入口：解析整段文本，返回 Document。无 frontmatter 时 fields 空、body = 全文。
    public func parse(_ content: String) -> Document {
        let lines = content.components(separatedBy: "\n")
        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return Document(fields: [:], orderedKeys: [], body: content, bodyStartLine: 1)
        }

        var fields: [String: Value] = [:]
        var orderedKeys: [String] = []
        var i = 1
        // 第一阶段：扫平铺 key: value 直到遇到闭合 `---` 或文件结束
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                let body = lines[(i + 1)...].joined(separator: "\n")
                return Document(fields: fields, orderedKeys: orderedKeys,
                                body: body, bodyStartLine: i + 2)
            }
            // 跳过空行 / 注释
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            if let parsed = parseFlatLine(trimmed) {
                let (key, value) = parsed
                // 重复 key：第一次胜出（保留人类预期，避免编辑器意外覆盖）
                if fields[key] == nil {
                    orderedKeys.append(key)
                    fields[key] = value
                }
            } else if let (key, nestedObject) = parseNestedStart(trimmed, lines: lines, index: i) {
                if fields[key] == nil {
                    orderedKeys.append(key)
                    fields[key] = .object(nestedObject)
                }
                // 跳过嵌套的子行（缩进比 key 大的行）
                i += 1
                while i < lines.count {
                    let nextLine = lines[i]
                    if nextLine.isEmpty || nextLine.first == " " || nextLine.first == "\t" {
                        i += 1
                    } else {
                        break
                    }
                }
                continue
            } else {
                // 无法解析的 key 整行留为 .string（保留原文以防 Inspector 误删）
                if let colon = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty, fields[key] == nil {
                        orderedKeys.append(key)
                        fields[key] = .string(value)
                    }
                }
            }
            i += 1
        }
        // 没闭合 `---`：当作无 frontmatter（避免误把后面正文当 YAML 解析）
        return Document(fields: [:], orderedKeys: [], body: content, bodyStartLine: 1)
    }

    // MARK: - 单行 value 解析

    /// 解析 `key: value` 平铺行。返回 nil 表示这行不是平铺（可能嵌套或非 key-value）。
    private func parseFlatLine(_ line: String) -> (String, Value)? {
        // 跳过 list / 嵌套（这些以 `-` 或缩进开头，不在平铺 key 范畴）
        if line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("\t") {
            return nil
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        let rawValue = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        // 空 value → 留给 parseNestedStart 接手（识别 `key:` 起始的嵌套对象）
        if rawValue.isEmpty { return nil }
        let value = parseValue(rawValue)
        return (key, value)
    }

    /// 解析单值：string / number / bool / null / list
    func parseValue(_ raw: String) -> Value {
        if raw.isEmpty { return .string("") }
        // bool
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        // null
        if raw == "null" || raw == "~" { return .null }
        // list: [a, b, c]
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            return parseList(String(raw.dropFirst().dropLast()))
        }
        // number
        if let n = parseNumber(raw) { return .number(n) }
        // string（去掉首尾可选引号）
        return .string(unquote(raw))
    }

    /// 解析 `42` / `-1` / `3.14` / `-2.5` / `1e3`
    func parseNumber(_ s: String) -> Double? {
        if s.isEmpty { return nil }
        // 不接受像 "1.2.3" 或 "abc" 这种 → Double() 返 nil 自然降级
        if let d = Double(s) { return d }
        return nil
    }

    /// 解析 list 内部 "a, b, c" 或 "1, 2, 3" 或 "a, "b""
    /// 自动判断 stringList 还是 intList（每个元素都能 parse 为 Int 则用 intList）
    func parseList(_ inner: String) -> Value {
        let items = splitTopLevelCommas(inner)
        let values = items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }
        if values.isEmpty { return .stringList([]) }
        // 全部能转 Int？
        if let ints = values.map(Int.init) as? [Int] {
            return .intList(ints)
        }
        return .stringList(values)
    }

    /// 按顶层逗号 split（不在 [...] 或 "..." 内的逗号）
    private func splitTopLevelCommas(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inBracket = 0
        var inQuote: Character? = nil
        for c in s {
            if let q = inQuote {
                current.append(c)
                if c == q { inQuote = nil }
                continue
            }
            switch c {
            case "\"":
                inQuote = c
                current.append(c)
            case "'":
                inQuote = c
                current.append(c)
            case "[":
                inBracket += 1
                current.append(c)
            case "]":
                inBracket -= 1
                current.append(c)
            case "," where inBracket == 0:
                result.append(current)
                current = ""
            default:
                current.append(c)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 去掉首尾匹配的引号（"..." 或 '...'）
    private func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - 嵌套 object（最简一层）

    /// 检查 line 是不是 `key:`（无 value），且后续行是缩进子键 → 视为嵌套 object
    private func parseNestedStart(_ line: String, lines: [String], index: Int) -> (String, [String: Value])? {
        guard line.hasSuffix(":") else { return nil }
        let key = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        var nested: [String: Value] = [:]
        var j = index + 1
        while j < lines.count {
            let next = lines[j]
            if next.isEmpty { j += 1; continue }
            // 缩进 < 2 字符 = 不再属于这个 key
            if next.first != " " && next.first != "\t" { break }
            let stripped = next.drop(while: { $0 == " " || $0 == "\t" })
            if let parsed = parseFlatLine(String(stripped)) {
                nested[parsed.0] = parsed.1
            }
            j += 1
        }
        return nested.isEmpty ? nil : (key, nested)
    }
}

// MARK: - 序列化（编辑器写回需要）

extension FrontmatterParser {
    /// 把 Document 渲染回 YAML frontmatter 文本（不含 `---` 围栏）。
    /// 顺序用 orderedKeys 保留；列表用 `[a, b, c]` 形式。
    public static func render(_ doc: Document) -> String {
        var out: [String] = []
        for key in doc.orderedKeys {
            guard let v = doc.fields[key] else { continue }
            out.append("\(key): \(renderValue(v))")
        }
        return out.joined(separator: "\n")
    }

    private static func renderValue(_ v: Value) -> String {
        switch v {
        case .string(let s):
            // 含特殊字符的字符串用引号包起来
            if s.contains(":") || s.contains("#") || s.isEmpty ||
               s.first == " " || s.last == " " {
                return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return s
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .stringList(let xs): return "[" + xs.map(quotedInList).joined(separator: ", ") + "]"
        case .intList(let xs): return "[" + xs.map(String.init).joined(separator: ", ") + "]"
        case .object(let d):
            // 单层 object 序列化成 `key: v\n  sub: w` 形式
            return "\n" + d.map { "  \($0.key): \(renderValue($0.value))" }.joined(separator: "\n")
        }
    }

    private static func quotedInList(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.isEmpty { return "\"\(s)\"" }
        return s
    }
}
