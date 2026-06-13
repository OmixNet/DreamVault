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

    // MARK: - v0.7.3 扩 100 case: V-11..V-45 verified-true (35 case)

    private static let verifiedTrueExtended: [EvalCase] = [
        // V-11..V-20: 通用软件 / 工具 (UI / 编程语言 / 数据库)
        EvalCase(
            id: "V-11",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：PostgreSQL 14 引入 JSON_TABLE 函数。
            证据片段：
            [raw/2024-03-12-postgres-release-notes.md:88] PostgreSQL 14 release notes: SQL/JSON path functions (JSON_TABLE, JSON_VALUE, JSON_QUERY) added.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据明确说 PG 14 加 JSON_TABLE. 应 YES."
        ),
        EvalCase(
            id: "V-12",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Rust 默认禁用 unsafe 块。
            证据片段：
            [raw/2024-04-08-rust-book.md:203] Rust 的内存安全保证建立在所有权系统上, unsafe 块需显式标注, 编译器默认不信任任何 unsafe 操作.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 unsafe 需显式标注, 即默认禁用. 应 YES."
        ),
        EvalCase(
            id: "V-13",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：NixOS 用 /nix/store 不可变包管理。
            证据片段：
            [raw/2024-05-22-nixos-arch.md:67] NixOS 包存储于只读 /nix/store 目录, 每个包有唯一哈希前缀, 升级/回滚原子化.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 /nix/store 只读 + 唯一哈希. 应 YES."
        ),
        EvalCase(
            id: "V-14",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Kubernetes 1.27 默认启用 sidecar 容器。
            证据片段：
            [raw/2024-06-15-k8s-changelog.md:421] K8s 1.27 release notes: sidecar containers graduated to beta, enabled by default.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 1.27 sidecar 默认启用. 应 YES."
        ),
        EvalCase(
            id: "V-15",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：gRPC 用 HTTP/2 + Protocol Buffers。
            证据片段：
            [raw/2024-07-03-grpc-intro.md:15] gRPC 默认基于 HTTP/2 传输, 用 Protocol Buffers (proto3) 作接口定义语言.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 HTTP/2 + protobuf. 应 YES."
        ),
        EvalCase(
            id: "V-16",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Redis 7 引入 Redis Functions 替代 Lua eval。
            证据片段：
            [raw/2024-08-19-redis-7-release.md:127] Redis 7.0 release notes: Redis Functions (server-side scripting 替代 EVAL) added as stable feature.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 7.0 加 Redis Functions 替代 EVAL. 应 YES."
        ),
        EvalCase(
            id: "V-17",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：SQLite 是无服务器 (serverless) 嵌入式数据库。
            证据片段：
            [raw/2024-09-04-sqlite-arch.md:33] SQLite 是进程内库, 无独立 server 进程, 单文件存储, 整个引擎嵌入调用方.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 SQLite 进程内库 + 无 server. 应 YES."
        ),
        EvalCase(
            id: "V-18",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：WebAssembly 1.0 在 2019 年定稿。
            证据片段：
            [raw/2024-10-11-wasm-history.md:54] W3C 推荐标准: WebAssembly Core Specification 1.0 (2019-12-05) 成为 W3C Recommendation.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 2019-12 W3C Recommendation. 应 YES."
        ),
        EvalCase(
            id: "V-19",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Tailwind CSS 用 utility-first 范式。
            证据片段：
            [raw/2024-11-28-tailwind-philosophy.md:88] Tailwind 文档开篇: utility-first CSS framework, 通过组合原子类 (flex, pt-4, text-center) 构建设计.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 utility-first 原子类. 应 YES."
        ),
        EvalCase(
            id: "V-20",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：OpenTelemetry 合并了 OpenCensus 和 OpenTracing。
            证据片段：
            [raw/2024-12-15-otel-history.md:142] OpenTelemetry 是 CNCF 项目, 2019 年由 OpenTracing 和 OpenCensus 合并而成, 统一了 tracing/metrics/logs 三大信号.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 2019 合并 OpenTracing + OpenCensus. 应 YES."
        ),

        // V-21..V-30: dream-engine 自身 / AI / 机器学习
        EvalCase(
            id: "V-21",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：NLEmbeddingProvider 在 zh-Hans 下输出 640 维向量。
            证据片段：
            [raw/2026-05-12-nlembedding-test.md:35] 实测 macOS 14 (arm64): NLEmbedding.sentenceEmbedding(for: .simplifiedChinese).dimension = 640, en 模式下 dim=512.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 zh-Hans dim=640 (P3-6 实测). 应 YES."
        ),
        EvalCase(
            id: "V-22",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：SourceRefValidator 拒绝 excerpt 不在源文件连续 substring 的引用。
            证据片段：
            [raw/2026-04-08-sourceref-impl.md:118] 闸门设计: excerpt 必须是源文件 body 连续 substring, 否则 rejectedFabricated+=1. 长度 < 5 字符放行 (噪声容差).
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 substring 严格匹配 (P0-3 修复). 应 YES."
        ),
        EvalCase(
            id: "V-23",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Adamic-Adar 关联分公式 = Σ 1/log(degree(w))。
            证据片段：
            [raw/2026-03-19-knowledge-graph.md:42] Adamic-Adar(u,v) = Σ over 共同邻居 w of 1/log(degree(w)). 共同邻居多且度数低 → 关联强.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 Adamic-Adar 公式 (KnowledgeGraph 注释). 应 YES."
        ),
        EvalCase(
            id: "V-24",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：CounterBox.addError() 累加 3 段 CoT 失败计数。
            证据片段：
            [raw/2026-02-25-threestep-cot.md:88] P3-3 §1.2: analyze/generate/verify 任一步失败 → CounterBox.addError(), 用于日志跟夜报诊断.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 CounterBox.addError 计数 (P3-3 修复). 应 YES."
        ),
        EvalCase(
            id: "V-25",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Decayer 对 decayClass=fast 应用的 staleDays 是 normal 的 1/3。
            证据片段：
            [raw/2026-01-30-decay-impl.md:67] P3-7 §2.1 修复: effectiveStaleDays = staleDays × tauMultiplier. fast=0.3 (即 1/3), normal=1.0, slow=3.0.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 fast tauMultiplier=0.3 (P3-7 修复). 应 YES."
        ),
        EvalCase(
            id: "V-26",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：LLMSchema.jsonSchema 走 Ollama 原生 /api/chat + format: json_schema。
            证据片段：
            [raw/2026-01-15-llm-schema.md:103] P3-5 §4.2: OllamaNativeProvider 用 /api/chat 端点, format 字段塞 json_schema 字典 (含 enum 约束), 强制 LLM 返结构化 JSON.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 OllamaNativeProvider + format: json_schema (P3-5). 应 YES."
        ),
        EvalCase(
            id: "V-27",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：EvalRunner 跟生产代码用同一套 keyword 解析逻辑。
            证据片段：
            [raw/2026-01-10-eval-design.md:55] P3-8 §3 设计: EvalRunner 复用 P3-2 ContradictionDetector 否定词窗口 5 词, 评测跟生产代码用同一套解析, 避免两套 parser 漂移.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 EvalRunner 复用生产解析 (P3-8). 应 YES."
        ),
        EvalCase(
            id: "V-28",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：EmbeddingMerge cosine 阈值 0.85 替代 P3-1 字符 Jaccard 0.6 兜底。
            证据片段：
            [raw/2025-12-22-embedding-merge.md:74] P3-6 §1.1 升级: 同质合并判定 embedding cosine ≥ 0.85 OR jaccard ≥ 0.6 双信号 OR. NLEmbedding 整体偏高 (机器学习 vs 苹果水果 0.81), 阈值 0.85 平衡.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 cosine 0.85 OR jaccard 0.6 (P3-6). 应 YES."
        ),
        EvalCase(
            id: "V-29",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Gatherer chunkBody 按 markdown H2 (##) 切分长 raw。
            证据片段：
            [raw/2025-12-08-gatherer-chunking.md:91] P3-4 §2.6 修复: chunkBody 短 raw (≤ maxChunkChars=4000) 不切, 长 raw 按 H2 split 保留结构语义, sourceLine 真实化.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 H2 split + maxChunkChars 4000 (P3-4). 应 YES."
        ),
        EvalCase(
            id: "V-30",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：DreamCycle.mergeSimilar 接受 EmbeddingProvider? 参数。
            证据片段：
            [raw/2025-11-15-dreamcycle-merge.md:128] P3-6 §1.1: mergeSimilar(newAccepted:existing:now:threshold:embeddingProvider:) — embedding 可用时走 cosine, 不可用时 fallback P3-1 Jaccard.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 mergeSimilar 接受 embeddingProvider (P3-6). 应 YES."
        ),

        // V-31..V-45: 网络协议 / 操作系统 / 安全
        EvalCase(
            id: "V-31",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：TLS 1.3 移除 CBC 模式密码套件。
            证据片段：
            [raw/2024-08-20-tls13-rfc.md:8] RFC 8446: TLS 1.3 removes static RSA, CBC mode cipher suites, and MD5/SHA-1 hash. 仅保留 (EC)DHE 密钥交换 + AEAD.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 TLS 1.3 移除 CBC (RFC 8446). 应 YES."
        ),
        EvalCase(
            id: "V-32",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：eBPF 程序运行在内核沙箱中。
            证据片段：
            [raw/2024-09-10-ebpf-arch.md:45] eBPF programs execute in an in-kernel sandbox (verifier), 防止任意内核读/写/系统调用, 仅允许受限 helper 调用.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 eBPF 内核沙箱 + verifier. 应 YES."
        ),
        EvalCase(
            id: "V-33",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：HTTP/3 底层用 QUIC 协议（基于 UDP）。
            证据片段：
            [raw/2024-10-05-http3-rfc.md:30] RFC 9114: HTTP/3 用 QUIC (RFC 9000) 作传输层, QUIC 本身基于 UDP, 集成 TLS 1.3.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 HTTP/3 走 QUIC/UDP. 应 YES."
        ),
        EvalCase(
            id: "V-34",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Linux cgroups v2 用统一层级 (unified hierarchy)。
            证据片段：
            [raw/2024-11-02-cgroups-v2.md:78] cgroups v2 (Linux 5.x+) 默认 unified hierarchy, 单根 cgroup 树, controller 选择性启用. v1 是多树混乱.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 cgroups v2 unified hierarchy. 应 YES."
        ),
        EvalCase(
            id: "V-35",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Zig 语言手动内存管理，无 runtime GC。
            证据片段：
            [raw/2024-12-19-zig-overview.md:55] Zig 文档: No hidden control flow, no hidden memory allocations. Memory management is explicit, 无内置 GC.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 Zig 无 GC. 应 YES."
        ),
        EvalCase(
            id: "V-36",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：WireGuard 用 Curve25519 密钥交换。
            证据片段：
            [raw/2025-01-22-wireguard-crypto.md:112] WireGuard 协议: Noise_IKpsk2 handshake, Curve25519 for ECDH, ChaCha20-Poly1305 for symmetric crypto.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 WireGuard Curve25519 + ChaCha20. 应 YES."
        ),
        EvalCase(
            id: "V-37",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：LLVM 项目用 Apache 2.0 + LLVM Exceptions 双许可。
            证据片段：
            [raw/2025-02-14-llvm-license.md:33] LLVM 仓库 LICENSE.txt: Apache 2.0 with LLVM Exceptions. Exceptions 让用户静态/动态链接 LLVM 不强制开源自家代码.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 LLVM Apache 2.0 + LLVM Exceptions. 应 YES."
        ),
        EvalCase(
            id: "V-38",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Bun 是用 Zig 编写的 JavaScript 运行时。
            证据片段：
            [raw/2025-03-08-bun-arch.md:67] Bun 用 Zig 编写, 内置 JavaScriptCore 引擎 (来自 WebKit), 替代/补充 Node.js, 速度比 Node 快数倍.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 Bun 用 Zig + JavaScriptCore. 应 YES."
        ),
        EvalCase(
            id: "V-39",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Swift 5.5 引入 async/await + structured concurrency。
            证据片段：
            [raw/2025-04-12-swift-55.md:88] Swift 5.5 release notes: async/await syntax, structured concurrency (Task, TaskGroup, AsyncStream). Actor model 加并发隔离.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 Swift 5.5 async/await + actors. 应 YES."
        ),
        EvalCase(
            id: "V-40",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：GitHub Actions 用 YAML workflow 文件定义 CI。
            证据片段：
            [raw/2025-05-05-gh-actions.md:144] GitHub Actions 文档: .github/workflows/*.yml 定义 workflow, jobs 串/并行执行 steps on runner.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 GitHub Actions 用 YAML. 应 YES."
        ),
        EvalCase(
            id: "V-41",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：OAuth 2.0 不定义签名算法，仅依赖底层 TLS。
            证据片段：
            [raw/2025-06-20-oauth2-rfc.md:18] RFC 6749: OAuth 2.0 本身不签 access token (signed tokens 是 JWT 扩展), 传输层依赖 TLS 保证机密性.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 OAuth 2.0 不签 token, 靠 TLS. 应 YES."
        ),
        EvalCase(
            id: "V-42",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：BSD 3-Clause 比 MIT 多一条"非 endorsement"条款。
            证据片段：
            [raw/2025-07-15-bsd-license.md:97] BSD 3-Clause 第三条: The name of the author may not be used to endorse products derived from this software without prior written permission. 阻止用作者背书.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 BSD-3 第三条 non-endorsement. 应 YES."
        ),
        EvalCase(
            id: "V-43",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Raft 共识算法用 leader election + log replication。
            证据片段：
            [raw/2025-08-10-raft-paper.md:50] Raft 论文: 拆成 leader election, log replication, safety 三子问题, 比 Paxos 易于理解和实现.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 Raft 拆 3 子问题. 应 YES."
        ),
        EvalCase(
            id: "V-44",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Apple Silicon 用统一内存架构 (UMA) 共享 CPU/GPU 内存。
            证据片段：
            [raw/2025-09-03-m1-uma.md:78] Apple M1 tech overview: Unified Memory Architecture, CPU/GPU/Neural Engine 共享同一物理内存, 减少数据拷贝.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 Apple Silicon UMA. 应 YES."
        ),
        EvalCase(
            id: "V-45",
            category: .verifiedTrue,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Cloudflare Workers 用 isolates 隔离请求而非进程。
            证据片段：
            [raw/2025-10-15-workers-arch.md:34] Cloudflare Workers 文档: V8 isolates 隔离每个请求, 启动 <5ms, 共享 OS 进程, 无冷启动.
            """,
            expectedVerdict: .yes,
            groundTruthNote: "证据说 Workers V8 isolates. 应 YES."
        ),
    ]

    // MARK: - v0.7.3 扩 H-11..H-30 hallucinated (20 case)

    private static let hallucinatedExtended: [EvalCase] = [
        // H-11..H-20: 通用软件 / 框架
        EvalCase(
            id: "H-11",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：PostgreSQL 17 完全移除 WAL 机制改用 in-memory replication。
            证据片段：
            [raw/2024-03-12-postgres-release-notes.md:88] PostgreSQL 14 release notes: SQL/JSON path functions (JSON_TABLE, JSON_VALUE, JSON_QUERY) added.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 PG 14 加 JSON_TABLE, 没说 PG 17 移除 WAL. PG 17 没移除 WAL. 应 NO."
        ),
        EvalCase(
            id: "H-12",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Rust 编译器 2025 改用 C++ 重写。
            证据片段：
            [raw/2024-04-08-rust-book.md:203] Rust 的内存安全保证建立在所有权系统上, unsafe 块需显式标注, 编译器默认不信任任何 unsafe 操作.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据没说 Rust 改 C++. 凭空捏造. 应 NO."
        ),
        EvalCase(
            id: "H-13",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：NixOS 在 Windows 上原生运行无需 WSL。
            证据片段：
            [raw/2024-05-22-nixos-arch.md:67] NixOS 包存储于只读 /nix/store 目录, 每个包有唯一哈希前缀, 升级/回滚原子化.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 NixOS 存储机制, 没说 Windows 兼容. 凭空捏造. 应 NO."
        ),
        EvalCase(
            id: "H-14",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Kubernetes 1.27 弃用所有 CRD。
            证据片段：
            [raw/2024-06-15-k8s-changelog.md:421] K8s 1.27 release notes: sidecar containers graduated to beta, enabled by default.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 sidecar 默认启用, 没说弃用 CRD. 应 NO."
        ),
        EvalCase(
            id: "H-15",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：gRPC 4.0 改用 JSON-RPC 协议。
            证据片段：
            [raw/2024-07-03-grpc-intro.md:15] gRPC 默认基于 HTTP/2 传输, 用 Protocol Buffers (proto3) 作接口定义语言.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 gRPC 走 protobuf, 没说改 JSON-RPC. 应 NO."
        ),
        EvalCase(
            id: "H-16",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Redis 7 完全删除 stream 数据类型。
            证据片段：
            [raw/2024-08-19-redis-7-release.md:127] Redis 7.0 release notes: Redis Functions (server-side scripting 替代 EVAL) added as stable feature.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 7.0 加 Functions, 没说删除 stream. 应 NO."
        ),
        EvalCase(
            id: "H-17",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：SQLite 4 改用 client-server 架构。
            证据片段：
            [raw/2024-09-04-sqlite-arch.md:33] SQLite 是进程内库, 无独立 server 进程, 单文件存储, 整个引擎嵌入调用方.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 SQLite 进程内无 server, 没说改 client-server. 应 NO."
        ),
        EvalCase(
            id: "H-18",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：WebAssembly 在 iOS 上被 Apple 永久禁用。
            证据片段：
            [raw/2024-10-11-wasm-history.md:54] W3C 推荐标准: WebAssembly Core Specification 1.0 (2019-12-05) 成为 W3C Recommendation.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 2019 W3C 标准, 没说 iOS 禁用. 应 NO."
        ),
        EvalCase(
            id: "H-19",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Tailwind CSS 4 改用 CSS-in-JS 运行时编译。
            证据片段：
            [raw/2024-11-28-tailwind-philosophy.md:88] Tailwind 文档开篇: utility-first CSS framework, 通过组合原子类 (flex, pt-4, text-center) 构建设计.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 utility-first, 没说改 CSS-in-JS. 应 NO."
        ),
        EvalCase(
            id: "H-20",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：OpenTelemetry 5 弃用 metrics 只保留 tracing。
            证据片段：
            [raw/2024-12-15-otel-history.md:142] OpenTelemetry 是 CNCF 项目, 2019 年由 OpenTracing 和 OpenCensus 合并而成, 统一了 tracing/metrics/logs 三大信号.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说统一三大信号, 没说弃用 metrics. 应 NO."
        ),

        // H-21..H-30: dream-engine 自身 / AI
        EvalCase(
            id: "H-21",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：NLEmbeddingProvider 在 zh-Hans 下输出 1024 维向量。
            证据片段：
            [raw/2026-05-12-nlembedding-test.md:35] 实测 macOS 14 (arm64): NLEmbedding.sentenceEmbedding(for: .simplifiedChinese).dimension = 640, en 模式下 dim=512.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 dim=640 不是 1024. 凭空捏造. 应 NO."
        ),
        EvalCase(
            id: "H-22",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：SourceRefValidator 使用 subsequence 模糊匹配 excerpt。
            证据片段：
            [raw/2026-04-08-sourceref-impl.md:118] 闸门设计: excerpt 必须是源文件 body 连续 substring, 否则 rejectedFabricated+=1. 长度 < 5 字符放行 (噪声容差).
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 substring (连续), 结论说 subsequence (模糊). 反. 应 NO."
        ),
        EvalCase(
            id: "H-23",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Adamic-Adar 关联分公式基于 PageRank 迭代。
            证据片段：
            [raw/2026-03-19-knowledge-graph.md:42] Adamic-Adar(u,v) = Σ over 共同邻居 w of 1/log(degree(w)). 共同邻居多且度数低 → 关联强.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 1/log(degree) 求和, 没说 PageRank. 应 NO."
        ),
        EvalCase(
            id: "H-24",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Consolidator 在 verify 阶段使用 contains("YES") 严格匹配。
            证据片段：
            [raw/2026-02-25-threestep-cot.md:88] P3-3 §1.2: analyze/generate/verify 任一步失败 → CounterBox.addError(), 用于日志跟夜报诊断.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 CounterBox 计数, 没说 verify 走 contains(\"YES\"). P3-5 改造后 verify 走 StructuredParser 主路径, 老 keyword 是 fallback. 应 NO (主要错误: 证据无关)."
        ),
        EvalCase(
            id: "H-25",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Decayer 对 decayClass=fast 的 effectiveStaleDays 是 1.5x normal。
            证据片段：
            [raw/2026-01-30-decay-impl.md:67] P3-7 §2.1 修复: effectiveStaleDays = staleDays × tauMultiplier. fast=0.3 (即 1/3), normal=1.0, slow=3.0.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 fast=0.3 (1/3), 结论说 1.5x. 反. 应 NO."
        ),
        EvalCase(
            id: "H-26",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：OllamaNativeProvider 走 OpenAI 兼容的 /v1/chat/completions 端点。
            证据片段：
            [raw/2026-01-15-llm-schema.md:103] P3-5 §4.2: OllamaNativeProvider 用 /api/chat 端点, format 字段塞 json_schema 字典 (含 enum 约束), 强制 LLM 返结构化 JSON.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 /api/chat, 结论说 /v1/chat/completions (那是老 OllamaProvider OpenAI 兼容). 应 NO."
        ),
        EvalCase(
            id: "H-27",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：EvalRunner 跑全 30 case 返 P/R/F1 = 100% 准确。
            证据片段：
            [raw/2026-01-10-eval-design.md:55] P3-8 §3 设计: EvalRunner 复用 P3-2 ContradictionDetector 否定词窗口 5 词, 评测跟生产代码用同一套解析, 避免两套 parser 漂移.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 EvalRunner 跟生产同款解析, 没说 100% 准确. mock provider 实测 30% 准确. 应 NO."
        ),
        EvalCase(
            id: "H-28",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：EmbeddingMerge cosine 阈值 0.7 替代 P3-1 字符 Jaccard 0.6。
            证据片段：
            [raw/2025-12-22-embedding-merge.md:74] P3-6 §1.1 升级: 同质合并判定 embedding cosine ≥ 0.85 OR jaccard ≥ 0.6 双信号 OR. NLEmbedding 整体偏高 (机器学习 vs 苹果水果 0.81), 阈值 0.85 平衡.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 0.85 (因 0.81 误合), 结论说 0.7. 反. 应 NO."
        ),
        EvalCase(
            id: "H-29",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：Gatherer chunkBody 按 H1 (#) 切分长 raw。
            证据片段：
            [raw/2025-12-08-gatherer-chunking.md:91] P3-4 §2.6 修复: chunkBody 短 raw (≤ maxChunkChars=4000) 不切, 长 raw 按 H2 split 保留结构语义, sourceLine 真实化.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 H2 (##), 结论说 H1 (#). 反. 应 NO."
        ),
        EvalCase(
            id: "H-30",
            category: .hallucinated,
            phase: .verify,
            systemPrompt: "你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。证据未明确支撑就回答 NO。只输出 YES 或 NO。",
            userPrompt: """
            结论：DreamCycle.mergeSimilar 在 embedding 不可用时直接抛错。
            证据片段：
            [raw/2025-11-15-dreamcycle-merge.md:128] P3-6 §1.1: mergeSimilar(newAccepted:existing:now:threshold:embeddingProvider:) — embedding 可用时走 cosine, 不可用时 fallback P3-1 Jaccard.
            """,
            expectedVerdict: .no,
            groundTruthNote: "证据说 fallback Jaccard, 结论说抛错. 反. 应 NO."
        ),
    ]

    // MARK: - v0.7.3 扩 C-11..C-25 contradiction (15 case)

    private static let contradictionPairsExtended: [EvalCase] = [
        EvalCase(
            id: "C-11",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: Rust 编译器用 Rust 编写 (rustc 自举).
            知识 B: Rust 编译器用 C++ 编写.

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (rustc 实现语言), 不可调和 (Rust vs C++). 应 conflict."
        ),
        EvalCase(
            id: "C-12",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: PostgreSQL 默认端口 5432.
            知识 B: PostgreSQL 默认端口 3306.

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (PG 端口), 数字不同. 应 conflict."
        ),
        EvalCase(
            id: "C-13",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: K8s 1.27 启用 sidecar 容器 (默认).
            知识 B: K8s 1.27 禁用 sidecar 容器 (opt-in).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (K8s 1.27 sidecar), 默认行为相反. 应 conflict."
        ),
        EvalCase(
            id: "C-14",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: gRPC 用 HTTP/2 + Protocol Buffers.
            知识 B: gRPC 用 HTTP/1.1 + JSON.

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (gRPC 协议栈), 不可调和. 应 conflict."
        ),
        EvalCase(
            id: "C-15",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: SQLite 是无 server 进程内嵌入式数据库.
            知识 B: SQLite 是 client-server 架构独立守护进程.

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (SQLite 架构), 嵌入式 vs client-server 互斥. 应 conflict."
        ),
        EvalCase(
            id: "C-16",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: dream-engine 用 Swift 6.3 + SwiftUI 编写, 专攻 macOS.
            知识 B: dream-engine 用 Rust 编写, 跨平台 (macOS / Windows / Linux).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (dream-engine 实现语言 + 平台), 不可调和. 应 conflict."
        ),
        EvalCase(
            id: "C-17",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: Swift 5.5 引入 async/await + actors (structured concurrency).
            知识 B: Swift 5.5 移除 async/await, 仅保留 GCD.

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (Swift 5.5 并发), 不可调和. 应 conflict."
        ),
        EvalCase(
            id: "C-18",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: NLEmbeddingProvider zh-Hans 模式输出 640 维向量.
            知识 B: NLEmbeddingProvider zh-Hans 模式输出 1024 维向量.

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (NLEmbeddingProvider zh-Hans dim), 数字不同. 应 conflict."
        ),
        EvalCase(
            id: "C-19",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: Decayer 对 fast decayClass 应用 effectiveStaleDays = 27 天.
            知识 B: Decayer 对 fast decayClass 应用 effectiveStaleDays = 90 天 (跟 normal 一样).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (fast effectiveStaleDays), 27 vs 90 不可调和. P3-7 修复后 fast=27, 老代码=90. 应 conflict."
        ),
        EvalCase(
            id: "C-20",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: Gatherer chunkBody 按 H2 (##) 切分长 raw.
            知识 B: Gatherer chunkBody 按 H1 (#) 切分长 raw.

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (Gatherer 切分级别), H2 vs H1 互斥. 应 conflict."
        ),
        EvalCase(
            id: "C-21",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: SourceRefValidator 要求 excerpt 是源文件 body 连续 substring.
            知识 B: SourceRefValidator 接受 excerpt 是 subsequence 模糊匹配 (非连续).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (SourceRefValidator excerpt 匹配), substring vs subsequence 不可调和. 应 conflict."
        ),
        EvalCase(
            id: "C-22",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: OllamaNativeProvider 走 /api/chat 端点 + format: json_schema.
            知识 B: OllamaNativeProvider 走 /v1/chat/completions 端点 (OpenAI 兼容).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (OllamaNativeProvider 端点), 不可调和. 应 conflict."
        ),
        EvalCase(
            id: "C-23",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: EmbeddingMerge 阈值 cosine ≥ 0.85 OR jaccard ≥ 0.6 双信号 OR.
            知识 B: EmbeddingMerge 阈值 cosine ≥ 0.7 (单信号, 无 jaccard 兜底).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (EmbeddingMerge 阈值), 双信号 OR vs 单信号. 应 conflict."
        ),
        EvalCase(
            id: "C-24",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: DreamConfig.productionDefault 默认开启 NLEmbeddingProvider (macOS 12+).
            知识 B: DreamConfig.productionDefault 默认不启用 embedding provider (用户须显式配).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .conflict,
            groundTruthNote: "同主题 (productionDefault embedding 策略), 默认开 vs 默认关不可调和. P3-6 follow-up v0.7.2 选 A. 应 conflict."
        ),
        EvalCase(
            id: "C-25",
            category: .contradictionPair,
            phase: .contradiction,
            systemPrompt: "你判断两条知识是否互相矛盾（不能同时为真）。仅当它们就同一主题给出不可调和的结论时才算矛盾。主题不同、或只是侧重不同、或可同时成立，都不算矛盾。只输出 CONFLICT 或 OK。",
            userPrompt: """
            知识 A: 同一主题社区 (e.g. SwiftUI 群) 在 KnowledgeGraph 共享 1 个 source file → 共享 1 个入边 (Adamic-Adar).
            知识 B: 同一主题社区跨多个 source file 也能通过 embedding cosine 跨文件连边 (KnowledgeGraph.semanticEdges).

            A 与 B 是否矛盾？
            """,
            expectedVerdict: .ok,
            groundTruthNote: "主题相关但不矛盾 — A 说同 source file 内 Adamic-Adar, B 说跨 source file embedding. 两个独立信号互补. 应 OK."
        ),
    ]

    /// 100 case 标准评测集 (30 + 70 extended, v0.7.3)
    public static let standard: [EvalCase] =
        verifiedTrue + verifiedTrueExtended +
        hallucinated + hallucinatedExtended +
        contradictionPairs + contradictionPairsExtended

    /// 按 phase 拆开 (verify / contradiction)
    public static func cases(for phase: EvalPhase) -> [EvalCase] {
        standard.filter { $0.phase == phase }
    }
}
