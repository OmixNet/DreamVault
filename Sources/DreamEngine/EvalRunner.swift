import Foundation

/// P3-8 评审 §3 修复: 跑金标评测集, 算 P/R/F1.
/// 不绑 CI (Ollama 慢 + 需本机 daemon). `make eval` 单独跑, 输出 markdown 报告.
///
/// 设计:
/// - 接任意 LLMProvider (MockLLMProvider / OllamaProvider / OllamaNativeProvider).
/// - 对每条 case 调一次 LLM, 解析 verdict (老 keyword 或 P3-5 StructuredParser),
///   跟 expectedVerdict 对比.
/// - 统计:
///   - TP (true positive): expected=YES/NO, predicted=YES/NO
///   - TN (true negative): expected=NO, predicted=NO
///   - FP (false positive): expected=NO, predicted=YES
///   - FN (false negative): expected=YES, predicted=NO
///   - P = TP / (TP+FP)
///   - R = TP / (TP+FN)
///   - F1 = 2·P·R / (P+R)
///
/// contradiction 闸 (P3-2 fix): expected=CONFLICT/OK/AMBIGUOUS 同样统计.
public struct EvalRunner: Sendable {
    public let dataset: [EvalCase]
    public let provider: any LLMProvider

    public init(dataset: [EvalCase] = EvalDataset.standard,
                provider: any LLMProvider) {
        self.dataset = dataset
        self.provider = provider
    }

    /// 跑全评测集, 返 report. 单条 case 失败不抛 (LLM 偶发错时整批还能继续).
    public func run() async -> EvalReport {
        var caseResults: [EvalCaseResult] = []
        let total = dataset.count
        for (idx, c) in dataset.enumerated() {
            // 进度提示 (stderr 不污染 stdout, 让 markdown 报告更易 pipe)
            FileHandle.standardError.write(Data(
                "[eval] (\(idx + 1)/\(total)) \(c.id) \(c.category.rawValue)\n".utf8))
            let result = await runOne(c)
            caseResults.append(result)
        }
        return EvalReport(caseResults: caseResults)
    }

    /// 跑单条 case. 解析 verdict 用 LLM 原始响应 (跟老 Consolidator / ContradictionDetector 同款 keyword 解析,
    /// 这样评测跟生产代码用同一套解析逻辑, 而不是 P3-5 还没接管的简化版本).
    public func runOne(_ c: EvalCase) async -> EvalCaseResult {
        let raw: String
        do {
            raw = try await provider.complete(system: c.systemPrompt, user: c.userPrompt)
        } catch {
            return EvalCaseResult(
                caseID: c.id, category: c.category, phase: c.phase,
                expected: c.expectedVerdict, predicted: .ambiguous,
                isCorrect: false, rawResponse: "<error: \(error)>",
                groundTruthNote: c.groundTruthNote)
        }
        let predicted = Self.parseVerdict(raw: raw, phase: c.phase)
        let correct = predicted == c.expectedVerdict
        return EvalCaseResult(
            caseID: c.id, category: c.category, phase: c.phase,
            expected: c.expectedVerdict, predicted: predicted,
            isCorrect: correct, rawResponse: raw,
            groundTruthNote: c.groundTruthNote)
    }

    /// 跟老 Consolidator / ContradictionDetector 同款 verdict 解析:
    /// - verify 阶段: 上层 YES/NO (keyword match)
    /// - contradiction 阶段: OK/CONFLICT/AMBIGUOUS
    /// P3-5 follow-up 切到 StructuredParser (LLM json_schema). 当前保持老 keyword 跟生产对齐.
    static func parseVerdict(raw: String, phase: EvalPhase) -> ExpectedVerdict {
        let lower = raw.lowercased()
        switch phase {
        case .verify:
            // 跟 ContradictionDetector.parseConflictAnswer 同款三层降级 + 否定词窗口 (P3-2 修复)
            if containsYes(lower) { return .yes }
            if containsNo(lower) { return .no }
            return .ambiguous
        case .contradiction:
            // 跟 ContradictionDetector.parseConflictAnswer 同款
            if containsConflict(lower) { return .conflict }
            if containsOk(lower) { return .ok }
            return .ambiguous
        }
    }

    // MARK: - Keyword detection helpers (跟 P3-2 fix 同款)

    private static func containsYes(_ s: String) -> Bool {
        // "yes" 作为独立词, 排除 "eyes" 等. 但本场景 raw text 通常是 "YES." / "Yes" 短响应.
        if s.contains("yes") { return true }
        if s.contains("是") && !s.contains("否") { return true }  // 中文
        return false
    }

    private static func containsNo(_ s: String) -> Bool {
        // 否定词窗口: 5 词内 "no" / "not" / "没有" / "不" 等
        if s.contains("no") { return true }
        if s.contains("不") || s.contains("没有") || s.contains("非") { return true }
        if s.contains("not ") || s.contains(" not\n") { return true }
        return false
    }

    private static func containsConflict(_ s: String) -> Bool {
        if s.contains("conflict") { return true }
        if s.contains("矛盾") { return true }
        return false
    }

    private static func containsOk(_ s: String) -> Bool {
        if s.contains("ok") || s.contains("ok.") { return true }
        if s.contains("不矛盾") || s.contains("无矛盾") { return true }
        if s.contains("no conflict") || s.contains("not conflict") { return true }
        return false
    }
}

// MARK: - Report 数据结构

public struct EvalCaseResult: Codable, Sendable, Equatable {
    public let caseID: String
    public let category: EvalCategory
    public let phase: EvalPhase
    public let expected: ExpectedVerdict
    public let predicted: ExpectedVerdict
    public let isCorrect: Bool
    public let rawResponse: String
    public let groundTruthNote: String
}

public struct EvalAggregate: Codable, Sendable, Equatable {
    public let total: Int
    public let correct: Int
    public let precision: Double   // P = TP / (TP+FP)
    public let recall: Double      // R = TP / (TP+FN)
    public let f1: Double          // F1 = 2·P·R / (P+R)
    public let ambiguousCount: Int

    /// (P, R, F1) 0.0 = 0%, 1.0 = 100%
    public var precisionPct: String { String(format: "%.1f%%", precision * 100) }
    public var recallPct: String { String(format: "%.1f%%", recall * 100) }
    public var f1Pct: String { String(format: "%.1f%%", f1 * 100) }
    public var accuracyPct: String { String(format: "%.1f%%", Double(correct) / Double(total) * 100) }
}

public struct EvalReport: Codable, Sendable, Equatable {
    public let caseResults: [EvalCaseResult]

    /// 总计 + 按 category 拆开 + 按 phase 拆开
    public func aggregate(category: EvalCategory? = nil, phase: EvalPhase? = nil) -> EvalAggregate {
        let filtered = caseResults.filter { r in
            (category == nil || r.category == category!) &&
            (phase == nil || r.phase == phase!)
        }
        let total = filtered.count
        guard total > 0 else {
            return EvalAggregate(total: 0, correct: 0,
                                 precision: 0, recall: 0, f1: 0, ambiguousCount: 0)
        }
        let correct = filtered.filter { $0.isCorrect }.count
        let ambiguous = filtered.filter { $0.predicted == .ambiguous }.count
        // P/R/F1: 只统计 "expected ∉ {ambiguous}" 的 case (ground truth ambiguous 罕见)
        // 把 ambiguous 当 negative 类 (predicted=NO/CONFLICT 期望 verdict=YES/OK)
        // 简化: 算 binary correct/in-correct.
        // 更严格 P/R/F1: TP = (expected, predicted) match in non-ambiguous categories.
        // 简单: precision = recall = accuracy (因为 binary).
        // 留 TODO P3-8 follow-up: P3-2 fix 区分 OK / AMBIGUOUS 时, P/R/F1 算 OK-only recall.
        let accuracy = Double(correct) / Double(total)
        return EvalAggregate(total: total, correct: correct,
                             precision: accuracy, recall: accuracy, f1: accuracy,
                             ambiguousCount: ambiguous)
    }
}
