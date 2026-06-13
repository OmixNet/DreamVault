import Foundation

/// P3-8 评审 §3 修复: 金标评测集.
/// 30 cases: 10 verified-true / 10 hallucinated / 10 contradiction pairs.
/// 跑真实 Ollama 验证 verify / conflicts 闸的精确率/召回率.
/// 写进 CI 之外的 `make eval` (Ollama 慢 + 需本机 Ollama daemon 跑).
///
/// 设计原则:
/// - 中文 + 英文混合 (覆盖 NLEmbedding zh-Hans 实测, 跟 dream 真实场景一致)
/// - 真实 LLM 风格的输入 (e.g. "应保持 / 应避免 / 教程提到" — 不留可猜的 keyword)
/// - expected verdict 跟 verify / contradiction 真实 verdict 对齐 (YES/NO, OK/CONFLICT)
/// - 注释解释每条 case 为什么是 true / false / conflict, 防止 ground truth 漂移
///
/// 后续 follow-up:
/// - 加 use case 数量 (50 / 100) → CI smoke + nightly eval
/// - 评测 Ollama llama3.1 7B / qwen2.5 3B (裁判任务不需要大模型, 评审 §2.3 推荐)

public enum EvalCategory: String, Codable, Sendable, CaseIterable {
    case verifiedTrue       // verify 应返 YES
    case hallucinated        // verify 应返 NO
    case contradictionPair   // 矛盾检测应返 CONFLICT
}

public enum ExpectedVerdict: String, Codable, Sendable, Equatable {
    case yes
    case no
    case ok
    case conflict
    case ambiguous

    public var displayName: String {
        switch self {
        case .yes: return "YES"
        case .no: return "NO"
        case .ok: return "OK"
        case .conflict: return "CONFLICT"
        case .ambiguous: return "AMBIGUOUS"
        }
    }
}

public enum EvalPhase: String, Codable, Sendable, CaseIterable {
    case verify          // 调 verify 闸 (LLM judge)
    case contradiction   // 调 contradiction 闸 (LLM judge)
}

/// P3-8: 一条评测 case.
/// - `id`: 人类可读 id (e.g. "V-01" verify, "C-01" contradiction)
/// - `category`: 3 类别 (verifiedTrue / hallucinated / contradictionPair)
/// - `phase`: 调哪个闸 (verify / contradiction)
/// - `systemPrompt`: 模拟 Consolidator 真实 system prompt (verify 闸 / 矛盾 闸)
/// - `userPrompt`: 模拟 user prompt (含 evidence 引用 + 候选 / 候选对)
/// - `expectedVerdict`: ground truth
/// - `groundTruthNote`: 人类可读说明, 防止 ground truth 漂移
public struct EvalCase: Codable, Sendable, Equatable {
    public let id: String
    public let category: EvalCategory
    public let phase: EvalPhase
    public let systemPrompt: String
    public let userPrompt: String
    public let expectedVerdict: ExpectedVerdict
    public let groundTruthNote: String

    public init(id: String,
                category: EvalCategory,
                phase: EvalPhase,
                systemPrompt: String,
                userPrompt: String,
                expectedVerdict: ExpectedVerdict,
                groundTruthNote: String) {
        self.id = id
        self.category = category
        self.phase = phase
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.expectedVerdict = expectedVerdict
        self.groundTruthNote = groundTruthNote
    }
}

// MARK: - 30 cases 金标评测集

public enum EvalDataset {
    /// 10 verified-true: 真实教训有充分证据, verify 应返 YES
    private static let verifiedTrue: [EvalCase] = [
        // V-01: 通用 UI 框架
        EvalCase(
            id: "V-01",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：SwiftUI 适合 macOS 13+ 桌面 UI 开发。
            证据片段：
            [raw/2024-01-15-claude-session.md:42] SwiftUI on macOS 13+ 提供稳定的桌面 UI 抽象, 跟 UIKit / AppKit 保持一致的渲染管线.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据片段明确说 SwiftUI 适合 macOS 13+ 桌面 UI. 应 verify YES."),

        EvalCase(
            id: "V-02",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：Ollama 默认 num_ctx 是 2048 token。
            证据片段：
            [raw/2024-02-03-ollama-config.md:18] ollama run 命令默认值: num_ctx=2048 (上下文窗口 2048 token).
            [raw/2024-02-03-ollama-config.md:19] 修改 num_ctx: ollama run --num-ctx 8192 model-name.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "Ollama 默认 num_ctx=2048 是社区文档常识 + 证据明确说. 应 verify YES."),

        EvalCase(
            id: "V-03",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：git 推送失败时可等 30 秒再试, 网络 NAT 偶尔短暂阻塞。
            证据片段：
            [raw/2024-03-10-git-push-notes.md:7] git push to GitHub 在 198.18.0.x NAT 后偶尔 timeout, 但 20-30 秒后重试通常成功.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据明确说 NAT timeout 30 秒后重试. 应 verify YES."),

        EvalCase(
            id: "V-04",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：NLEmbedding 在 macOS 12+ 系统自带, 离线可用。
            证据片段：
            [raw/2024-04-22-natural-language.md:5] NLEmbedding / NLContextualEmbedding 是 macOS 12+ 系统框架 NaturalLanguage 自带, 无需安装第三方, 完全离线运行.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "NLEmbedding macOS 12+ 自带离线是 Apple 文档 + 证据明确. 应 verify YES."),

        EvalCase(
            id: "V-05",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：P3-1 同质合并修复用字符 trigram Jaccard 阈值 0.6, 0.5 太松。
            证据片段：
            [raw/2024-05-15-p3-1-merge.md:23] 阈值 0.5 太松, swiftui vs appkit 共享"用于 macos 桌面 ui"会算 0.5 误合. 0.6 是经验上更稳的点.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "P3-1 changelog 明确说 0.5 太松 0.6 平衡. 应 verify YES."),

        EvalCase(
            id: "V-06",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：raw/ 目录在文件系统层挂只读, 防止 processed 状态被写回。
            证据片段：
            [raw/2024-06-01-architecture.md:3] 架构原则 1: raw/ 永远只读. .dream/processed.json 替代写回. RawReadonlyGuard 在文件系统层强制.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "raw/ 只读是架构原则 1, RawReadonlyGuard 实现. 应 verify YES."),

        EvalCase(
            id: "V-07",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：Gatherer 在 macOS 14 arm64 上 NLEmbedding 中文支持, dim=640。
            证据片段：
            [raw/2024-07-08-nl-embed-probe.md:11] NLEmbedding 探测: en dim=512, zh-Hans dim=640, zh-Hant / ja / ko 不支持.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "实测 zh-Hans dim=640 是事实. 应 verify YES."),

        EvalCase(
            id: "V-08",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：dream-engine 自动跳过的不是矛盾, 而是矛盾被 detect 后交 needsReview 人工裁决。
            证据片段：
            [raw/2024-08-12-decision-flow.md:55] 矛盾永远 needsReview (Decayer line 56), 不自动 archive / 不自动 keep.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "Decayer.evaluate line 56-58 明确: 矛盾 needsReview. 应 verify YES."),

        EvalCase(
            id: "V-09",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：fast 类记忆在 P3-7 修复后 27 天后会被 archive, 不再等满 90 天。
            证据片段：
            [raw/2024-09-03-p3-7-decay.md:18] P3-7: effectiveStaleDays = staleDays × tauMultiplier, fast × 0.3 = 27 天. 评审核心修复: fast 不再被 90 天门槛架空.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "P3-7 changelog 明确. 应 verify YES."),

        EvalCase(
            id: "V-10",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：DreamVault 是 macOS 13+ 原生 app, 不用 Electron / Web 框架。
            证据片段：
            [raw/2024-10-15-tech-stack.md:7] DreamVault 是 macOS 13+ 原生 SwiftUI app, 0 Web 框架, 0 Electron. 单一二进制 ~5MB.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "SwiftUI 原生是 README + 证据明确. 应 verify YES."),
    ]

    /// 10 hallucinated: 凭空捏造 / 证据不足, verify 应返 NO
    private static let hallucinated: [EvalCase] = [
        // H-01: 凭空捏造事实 (证据片段不含)
        EvalCase(
            id: "H-01",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：NLEmbedding 在 Linux 上也能用, 跟 macOS 同 API。
            证据片段：
            [raw/2024-04-22-natural-language.md:5] NLEmbedding / NLContextualEmbedding 是 macOS 12+ 系统框架 NaturalLanguage 自带.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据只说 macOS 12+, 没提 Linux. 'Linux 也能用' 是凭空捏造. 应 verify NO."),

        EvalCase(
            id: "H-02",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：字符 trigram Jaccard 阈值 0.5 平衡, 0.6 太严。
            证据片段：
            [raw/2024-05-15-p3-1-merge.md:23] 阈值 0.5 太松, swiftui vs appkit 共享"用于 macos 桌面 ui"会算 0.5 误合. 0.6 是经验上更稳的点.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 0.5 太松 0.6 平衡, 结论反过来说 0.5 平衡 0.6 太严. 应 verify NO (矛盾)."),

        EvalCase(
            id: "H-03",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：DreamCycle 在 verify 阶段用不同 LLM 当裁判, 防止同模型自偏。
            证据片段：
            [raw/2024-08-12-decision-flow.md:30] Consolidator.verify 仍用主 LLM (Ollama llama3.1). P3-5 评审建议 verify 三次采样多数投票, follow-up.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 verify 仍用主 LLM, 没\"用不同 LLM 当裁判\". 应 verify NO (凭空捏造)."),

        EvalCase(
            id: "H-04",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：dream-engine 自动跳过的不是矛盾, 而是矛盾被 detect 后直接 archive。
            证据片段：
            [raw/2024-08-12-decision-flow.md:55] 矛盾永远 needsReview (Decayer line 56), 不自动 archive / 不自动 keep.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 needsReview, 结论说直接 archive. 应 verify NO (矛盾)."),

        EvalCase(
            id: "H-05",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：NLEmbedding 维度 EN=512, ZH=512, 完全一样。
            证据片段：
            [raw/2024-07-08-nl-embed-probe.md:11] NLEmbedding 探测: en dim=512, zh-Hans dim=640.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 zh-Hans dim=640, 结论说 ZH=512. 应 verify NO (维度错)."),

        EvalCase(
            id: "H-06",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：P3-7 修复后 fast 类记忆 90 天后才会 archive。
            证据片段：
            [raw/2024-09-03-p3-7-decay.md:18] P3-7: effectiveStaleDays = staleDays × tauMultiplier, fast × 0.3 = 27 天.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 fast 27 天, 结论说 90 天. 应 verify NO (核心修复点被反过来说)."),

        EvalCase(
            id: "H-07",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：DreamVault 走 Electron + Web 前端, 跟 VS Code 一样的架构。
            证据片段：
            [raw/2024-10-15-tech-stack.md:7] DreamVault 是 macOS 13+ 原生 SwiftUI app, 0 Web 框架, 0 Electron.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 0 Electron, 结论说走 Electron. 应 verify NO (反着说)."),

        EvalCase(
            id: "H-08",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：dream-engine 自动跑测试用 Jest (JavaScript 测试框架)。
            证据片段：
            [raw/2024-11-01-test-stack.md:1] DreamVault 测试用 Swift Testing / XCTest (Apple 原生). 0 Jest / 0 跨语言测试.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 0 Jest, 结论说用 Jest. 应 verify NO (凭空捏造)."),

        EvalCase(
            id: "H-09",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：SourceRefValidator 用 NLP 余弦相似度, 不只用字符串 contains。
            证据片段：
            [raw/2024-12-10-source-ref.md:8] SourceRefValidator: normalize(_:) + substring contains. 全文归一化 (lowercase + collapse whitespace), 然后 excerpt 与 fileContent 互为 substring 才通过.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说用 normalize + substring contains (字符串), 结论说用 NLP 余弦. 应 verify NO (凭空捏造)."),

        EvalCase(
            id: "H-10",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: """
            你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
            证据未明确支撑就回答 NO。只输出 YES 或 NO。
            """,
            userPrompt: """
            结论：DreamVault 项目用 Python 重写了核心 Consolidator。
            证据片段：
            [raw/2024-10-15-tech-stack.md:1] DreamVault 是 Swift 项目, 核心 Consolidator 走 Swift. Python 0% 业务代码 (仅 tools / 评测脚本).
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 Swift 0% Python, 结论说 Python 重写. 应 verify NO (凭空捏造)."),
    ]

    /// 10 contradiction pairs: 2 条不能同时为真的教训, 矛盾应返 CONFLICT
    private static let contradictionPairs: [EvalCase] = [
        // C-01: UI 框架二选一
        EvalCase(
            id: "C-01",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            主题不同、或只是侧重不同、或可同时成立，都不算矛盾。
            """,
            userPrompt: """
            候选 A: 用 SwiftUI 构建 macOS 应用, 状态管理 Observable 模式 + 视图声明式更新.
            候选 B: 用 AppKit 构建 macOS 应用, 走传统 NSResponder / MVC 模式, 不用 SwiftUI 声明式.

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (macOS UI 框架), 不可调和结论 (SwiftUI 声明式 vs AppKit MVC). 应 conflict."),

        EvalCase(
            id: "C-02",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: P3-1 同质合并用字符 trigram Jaccard 阈值 0.6.
            候选 B: P3-6 升级用 NLEmbedding cosine 阈值 0.85, 字符 Jaccard 仅作兜底.

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (同质合并阈值), 不可调和 (0.6 vs 0.85 不同方法). 应 conflict (评审: 评审发现阈值不同时也矛盾)."),

        EvalCase(
            id: "C-03",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: Ollama 默认 num_ctx=2048, 长文件 50KB 会被静默截断, 需 P3-4 分块处理.
            候选 B: Ollama 不会截断输入, 长文件 50KB 完整传给 LLM 处理, 无需分块.

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (Ollama 是否截断), 不可调和 (会 vs 不会). 应 conflict."),

        EvalCase(
            id: "C-04",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: dream 引擎每晚跑一次, 收集 raw 候选 + 调 LLM 提炼教训.
            候选 B: dream 引擎在用户每次编辑 vault 时实时跑, 不等每晚.

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (dream 调度频率), 不可调和 (每晚 vs 实时). 应 conflict."),

        EvalCase(
            id: "C-05",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: fast 类记忆在 P3-7 修复后 27 天后 archive.
            候选 B: fast 类记忆 (如 debug 笔记) 90 天后才 archive, 跟 normal 一样.

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (fast 类 archive 时间), 不可调和 (27 vs 90). 应 conflict (P3-7 核心修复)."),

        EvalCase(
            id: "C-06",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: 4 次强化的教训永不消失 (frequency 地板恒成立).
            候选 B: 4 次强化的教训, 长期不访问仍会被 archive (P3-7 frequency 新近度衰减).

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (强化衰减), 不可调和 (永不消失 vs 长期不访问会 archive). 应 conflict (P3-7 修复点)."),

        EvalCase(
            id: "C-07",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: NLEmbedding 在 macOS 12+ 系统自带, 离线可用.
            候选 B: NLEmbedding 是第三方包, 需 pip install sentence-transformers 才能用.

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (NLEmbedding 来源), 不可调和 (系统自带 vs 第三方). 应 conflict."),

        EvalCase(
            id: "C-08",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: 矛盾检测对所有记忆对都跑 LLM (O(N×M) 全连).
            候选 B: 矛盾检测用 embedding 预筛, 只对 cosine >= 0.6 的对调 LLM (O(top-k)).

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (矛盾检测复杂度), 不可调和 (O(N×M) vs O(top-k)). 应 conflict."),

        EvalCase(
            id: "C-09",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: SourceRefValidator 用 NLP 余弦相似度判 excerpt 真假.
            候选 B: SourceRefValidator 用 normalize 字符串 substring contains 判 excerpt 真假.

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (P0-3 闸实现), 不可调和 (NLP 余弦 vs substring). 应 conflict."),

        EvalCase(
            id: "C-10",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: """
            你判断两条知识是否互相矛盾（不能同时为真）。
            仅当它们就同一主题给出不可调和的结论时才算矛盾。
            """,
            userPrompt: """
            候选 A: dream-engine 用 Swift 5 + SwiftUI 5 + macOS 13+ 原生 API 编写.
            候选 B: dream-engine 用 React 18 + TypeScript 5 + Electron 21 编写, 跨平台 (macOS / Windows / Linux).

            这两条互相矛盾吗？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同一主题 (dream-engine 技术栈), 不可调和 (Swift 原生 vs React 跨平台). 应 conflict."),
    ]

    /// 30 case 标准评测集
    public static let standard: [EvalCase] = verifiedTrue + hallucinated + contradictionPairs

    /// 按 phase 拆开 (verify / contradiction)
    public static func cases(for phase: EvalPhase) -> [EvalCase] {
        standard.filter { $0.phase == phase }
    }
}
