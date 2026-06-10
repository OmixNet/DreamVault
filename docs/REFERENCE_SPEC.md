# DreamVault 借鉴规格（给第 1 棒 Claude）

本文件是"先学后写"的学习产物。它提炼四个参考项目的**算法思想**（非源码），标清许可证边界，并对照 DreamVault 内核已有与待补部分。第 1 棒 Claude 据此写 Swift 接口，**不得逐行翻译任何项目源码**。

---

## 0. 许可证红线（动手前必读）

| 项目 | 许可证 | 能不能碰源码 | 能不能学思想 |
|------|--------|-------------|-------------|
| nashsu/llm_wiki | **GPL-3.0** | ❌ 绝不照抄（会传染你的项目） | ✅ 读 README/架构 |
| rohitg00/agentmemory | **Apache-2.0** | ⚠️ 只读思想，**不直接搬代码** | ✅ 强烈推荐 |
| ~~JordanMcCann/agentmemory~~ | — | ❌ 仓库已不存在 | — |
| ~~archon-memory-core~~ | — | ❌ 实际是 archon（AI 编码工作流引擎），不是记忆库 | — |

**2026-06 修正**：本节原列的 "JordanMcCann/agentmemory" 和 "archon-memory-core" 是误记或仓库已转手 / 删库。
真正值得学的三个项目是：

- **[Karpathy/llm-wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)** — 思想源头（不是 GitHub repo，是个 gist 文档）
- **nashsu/llm_wiki** — GPL v3 桌面实装（看 README / 架构）
- **rohitg00/agentmemory** — Apache-2.0 Agent 记忆层生产级实装（看 `README.md` / `DESIGN.md`）

详见 `docs/LEARNED_ALGORITHMS.md` 的完整对照表。

**警告：同名 `agentmemory` 至少 4 个（rohitg00 / conversence / elizaOS / langchain-ai/memory-agent），认准 URL。**
方针：一律只借鉴算法思想，用 Swift 原生重写。即便 MIT/Apache 项目也只学思想，保持代码干净、零传染、纯原生。

---

## 1. 从 nashsu/llm_wiki 学到的（仅思想，GPL 源码勿碰）

技术栈完全不可迁移（React/TypeScript/Tauri/sigma.js/LanceDB），但有 3 个**概念**值得 Swift 原生重写：

**① 两步链式思维 Ingest（Two-Step CoT Ingest）**
不要让 LLM 一步把原始文档变 wiki 页。分两步：先让 LLM **分析**（这文档讲什么、涉及哪些实体、和已有 wiki 哪里冲突），再让它**生成**带来源可追溯性的 wiki 页。好处：分析步可被审查，生成步有据可依，减少幻觉。
→ DreamVault 对应：这正是内核 `Consolidator` 该扩展的——目前是"提炼+校验"两段，可升级为"分析→生成→回读校验"三段。

**② 增量编译而非每次检索（Compile-once, keep-current）**
关键心智模型：不是传统 RAG（每次查询从头检索原文），而是**一次编译成结构化 wiki，后续持续保鲜**。新源进来时更新实体页、修订摘要、标注与旧论断的矛盾。
→ DreamVault 对应：`Persister` 的职责。写回不是追加，是"合并进已有 wiki 页"。

**③ 4 信号知识图谱**
页面间关联度用四个信号加权：直接链接、来源重叠、Adamic-Adar（共同邻居加权）、类型亲和度。再用 Louvain 社区检测自动聚类。
→ DreamVault 对应：你要的"wiki 交叉链接/知识图谱"那一块。Swift 里没有 graphology，需原生实现一个轻量图结构 + Adamic-Adar 打分（公式简单，下文给）。

---

## 2. 从 agentmemory 系列学到的（衰减与整合的精华）

**① 艾宾浩斯保留曲线 + 强化重置**
核心洞察：retention 随时间指数衰减，但每次"强化"（被访问、被新源确认）重置曲线。且**不同类型衰减速度不同**——架构决策衰减慢，临时 bug 衰减快。
→ DreamVault 对应：内核 `Decayer` 已实现 salience 三信号，但**缺"按类型设不同 τ"**。待补：给 Memory 加 `decayClass`（slow/normal/fast），不同类用不同 tauDays。

**② 四层整合管线（sleep consolidation 类比）**
working（原始观察，未处理）→ episodic（会话摘要）→ semantic（跨会话事实）→ procedural（重复语义中提取的工作流）。每层更压缩、更可信、更长寿。
→ DreamVault 对应：内核现在只有 candidate/durable/archived 三态，偏简。可对齐成四层，但**建议保持克制**——你要"单一"，四层可能过度。折中：working→durable 两层 + archived，够用再加。

**③ 写时矛盾检测与消解**
新记忆写入时即检测与旧记忆的矛盾，当场解决（而非堆积）。
→ DreamVault 对应：内核 `Decayer` 已有 `contradicts` 字段 + needsReview 动作，但**检测逻辑还没写**（目前靠外部填 contradicts）。待补：在 Consolidator 里加一步"新教训 vs 现有 durable 教训"的 LLM 比对。

**④ 隐私过滤（写入前脱敏）**
存原始观察前先 strip secrets、API key、邮箱。
→ DreamVault 对应：**内核目前没有！这是个缺口。** 待补：Gatherer 读 raw 后、进 ledger 前加一道脱敏正则。考虑到你跨中英文，注意中文里的敏感信息（手机号、身份证）也要覆盖。

**⑤ archive 层的"偶然唤回"**
有项目让 archive 层的旧记忆偶尔被随机唤回，连接到当前任务——"有时是噪音，有时是你忘了的好点子"。
→ DreamVault 对应：可选的趣味功能。与你的"串联笔记"诉求契合，但属锦上添花，第一版可不做。

---

## 3. 从 archon-memory-core 学到的

最贴合你需求的一句话定位：本地优先 + 夜间整合 + 主动遗忘 + 显著度评分。这四点 = 你的 dream 系统四步。
→ DreamVault 对应：架构方向已对齐，无需改设计。主要借鉴它**把这四步编排成一个夜间任务**的调度思路（对应你的 launchd 那一棒）。

---

## 4. 对照表：内核已有 vs 待补（第 1 棒 Claude 的活）

| 能力 | 来源思想 | 内核现状 | 第 1 棒要做 |
|------|---------|---------|------------|
| salience 三信号打分 | agentmemory | ✅ 已实现 | 加 decayClass 按类型变 τ |
| 保守降级（archive 不删） | archon | ✅ 已实现 | — |
| 整合三道防幻觉闸 | llm_wiki CoT | ✅ 已实现 | 升级为"分析→生成→回读"三段 |
| 矛盾检测 | agentmemory | ⚠️ 字段在，逻辑缺 | 加 LLM 比对新旧教训 |
| 隐私脱敏 | agentmemory | ❌ 缺口 | Gatherer 加脱敏（含中文敏感信息） |
| wiki 图谱 + Adamic-Adar | llm_wiki 4信号 | ❌ 未做 | 原生轻量图结构 + 打分 |
| 两步 ingest → wiki 页 | llm_wiki | ❌ 未做 | Persister 实现增量合并 |
| 夜间编排 | archon | ❌ 未做 | DreamCycle 串起五步 |

## 附：需要原生实现的两个公式（不涉版权）

**Adamic-Adar（图谱关联度，标准公式）**
两节点 u,v 的关联分 = Σ over 共同邻居 w of 1/log(degree(w))。共同邻居越多、越"专属"（度数越低），关联越强。Swift 实现就是遍历邻接表。

**按类型的衰减（扩展现有 salience）**
内核 recency = exp(-Δt/τ)。改为 τ = baseTau × classMultiplier，其中 slow=3.0、normal=1.0、fast=0.3。架构决策 τ≈90 天，临时 bug τ≈9 天。

---

## 学习结论（一句话给小队）

这四个项目**没有一行代码能直接搬进 SwiftUI**（技术栈全不对应 + GPL 风险），但它们贡献了 8 个可原生重写的算法思想。其中**衰减、保守降级、防幻觉三闸**内核已实现；**矛盾检测、隐私脱敏、知识图谱、增量 wiki 合并、夜间编排**是第 1 棒 Claude 的明确待办。先补这些进 DreamEngine，再开第 2 棒。
