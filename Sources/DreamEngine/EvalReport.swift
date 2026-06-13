import Foundation

/// P3-8 评测报告 markdown 渲染器.
/// 输出格式: 头 + 总 P/R/F1 + 按 phase 拆 + 每条 case verdict + groundTruthNote.
public enum EvalReportMarkdown {
    public static func render(_ report: EvalReport) -> String {
        var md = "# DreamVault P3-8 金标评测报告\n\n"
        md += "评测时间: \(timestamp())\n"
        md += "评测 case 数: \(report.caseResults.count)\n\n"

        // 总计
        let total = report.aggregate()
        md += "## 总计\n\n"
        md += "- Accuracy: **\(total.accuracyPct)** (\(total.correct)/\(total.correct + (total.total - total.correct)))\n"
        md += "- P = R = F1 = **\(total.precisionPct)** (binary 评测, 见下 TODO)\n"
        md += "- Ambiguous 预测数: \(total.ambiguousCount) (LLM 返模糊响应, 当错算)\n\n"

        // 按 phase 拆
        md += "## 按 phase 拆\n\n"
        for phase in EvalPhase.allCases {
            let agg = report.aggregate(phase: phase)
            md += "### \(phase.rawValue) 闸\n\n"
            md += "- 样本数: \(agg.total)\n"
            md += "- Accuracy: **\(agg.accuracyPct)**\n"
            md += "- Ambiguous: \(agg.ambiguousCount)\n\n"
        }

        // 按 category 拆
        md += "## 按 category 拆\n\n"
        for cat in EvalCategory.allCases {
            let agg = report.aggregate(category: cat)
            md += "### \(cat.rawValue) (\(agg.total) case)\n\n"
            md += "- Accuracy: **\(agg.accuracyPct)**\n"
            md += "- Ambiguous: \(agg.ambiguousCount)\n\n"
        }

        // 错 case 详情
        let wrong = report.caseResults.filter { !$0.isCorrect }
        if !wrong.isEmpty {
            md += "## 错 case 详情 (\(wrong.count))\n\n"
            md += "| ID | Category | Expected | Predicted | 错因 |\n"
            md += "|----|----------|----------|-----------|------|\n"
            for r in wrong {
                md += "| \(r.caseID) | \(r.category.rawValue) | \(r.expected.displayName) | \(r.predicted.displayName) | \(escape(r.groundTruthNote)) |\n"
            }
            md += "\n"
        }

        // 全 case 列表
        md += "## 全 case 结果\n\n"
        md += "| ID | Phase | Category | Expected | Predicted | ✓ |\n"
        md += "|----|-------|----------|----------|-----------|---|\n"
        for r in report.caseResults {
            let mark = r.isCorrect ? "✅" : "❌"
            md += "| \(r.caseID) | \(r.phase.rawValue) | \(r.category.rawValue) | \(r.expected.displayName) | \(r.predicted.displayName) | \(mark) |\n"
        }

        return md
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: " ")
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
