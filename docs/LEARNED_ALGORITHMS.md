# 学习笔记：四个参考项目的核心算法思想

> 给 DreamVault后续接棒的 Claude /任何想继续内核的人的"思想速查表"。
>严格遵守 `REFERENCE_SPEC.md`里的许可证红线：**只学思想，不抄源码**。
>
> 这份笔记基于2026-06 的事实核查，**修正**了 `REFERENCE_SPEC.md` 里两个项目名错记：
> - "JordanMcCann/agentmemory" → **搜不到这个仓库**，SPEC当时笔误或已转手
> - "archon-memory-core" →实际是 **archon**（AI编码工作流引擎），不是记忆库
>
>真正值得学的三个项目是：**Karpathy 的 llm-wiki gist（思想源头）**、**nashsu/llm_wiki（GPL v3 实装）**、**rohitg00/agentmemory（Apache-2.0，22k stars 实装）**。

---

##0. 项目速查（许可证 +源码策略）

| 项目 |角色 |许可证 |思想可学？ |源码可抄？ |备注 |
|------|------|--------|----------|----------|------|
| Karpathy/llm-wiki (gist) |思想源头 | — (文章) | ✅ | n/a |整个 LLM Wiki范式的作者 |
| nashsu/llm_wiki |桌面实装 | **GPL-3.0** | ✅ | ❌ **绝不照抄**（会传染 DreamVault） | Tauri + React + TS + LanceDB |
| rohitg00/agentmemory | Agent记忆层 | **Apache-2.0** | ✅ | ⚠️谨慎 | TypeScript，跑在 iii-engine运行时上 |

> **底线**：只看 README + 设计文档（如 rohitg00/agentmemory 的 `DESIGN.md`、`README.md`里的"Pipeline /4 层记忆 /检索"章节）+ 标准算法公式。所有代码用 Swift 原生重写。

---

##1. Karpathy 的 LLM Wiki（思想源头，2026-04）

gist原文：[https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)

### 三层架构（最关键的心智模型）

```
raw/ →不可变；只有 LLM读，永远不写
wiki/ → LLM拥有；entity/concept/comparison/overview 页 + [[wikilinks]]
schema/purpose → 你和 LLM协作维护的"宪法"（CLAUDE.md / AGENTS.md）
```

**核心定义**：
> "Knowledge is compiled once and then kept current, not re-derived on every query."
> ——知识**编译一次**，之后**持续保鲜**。不是 RAG那种"每次查询重新拼碎片"。

###三个核心操作

- **Ingest**：丢新源进来 → LLM读 →写摘要页 → 更新 entity/concept 页 → 更新 index.md →追加 log.md。**一个源可能触动10–15 个 wiki 页**。
- **Query**：基于 wiki回答，可把好答案再沉淀回 wiki（"exploration也要 compound"）。
- **Lint**：定期体检：找矛盾、找过期主张、找孤儿页、找缺失交叉引用、找数据缺口（可以触发 web search补）。

###索引 / 日志双轨

- `index.md`：**内容导向**，按 category 列所有页面（带一行摘要）。LLM 先读它定位，再下钻。
- `log.md`：**时序日志**，每行有可解析前缀（如 `## [2026-04-02] ingest | Article Title`），可用 `grep "^## \[" log.md | tail -5`拉最近5 条。

> 💡 **DreamVault 已对齐**：raw/ 只读、wiki/ 由引擎写、`index.md` 类似我们的 ledger + dream-report、log.md 类似 dream-report 时间线。**多了一维：衰减 +矛盾双向建链**，这是 Karpathy 没明确写但 lint隐含的东西。

###何时用 LLM Wiki vs RAG（Karpathy gist 评论里 Shilren总结的量级判据）

- **<5万–10万 token**（约150–200 页）：纯 LLM Wiki完胜，RAG 是过度设计。
- **>几百万 token**：只能用 RAG。
- **中间 / 生产**：混合（核心进上下文，长尾走 RAG）。

> 💡 个人 DreamVault走 LLM Wiki路线正是这条判据的"上下文完胜"区间 — **完全对齐，不需要向量化**。

---

##2. nashsu/llm_wiki（GPL v3，只学思想）

仓库：[https://github.com/nashsu/llm_wiki](https://github.com/nashsu/llm_wiki)（11.1k stars，40+ releases）
**红线：GPL v3 —任何照搬源码会传染 DreamVault。**

### Three things worth stealing（不要翻译代码，要翻译思想）

####① Two-Step Chain-of-Thought Ingest

原始 Karpathy 是单步"读+写同时做"。nashsu拆成两步，显著减少"边读边写的信息漏项"：

```
Step1 (Analysis): LLM读源 → 结构化分析
 -关键实体、概念、论据
 - 与现有 wiki 的连接点
 - 与现有知识的矛盾与张力
 -推荐的 wiki 结构

Step2 (Generation): LLM 据分析 → 生成 wiki 文件
 -源摘要页（含 frontmatter sources[]）
 - entity/concept 页 +交叉引用
 - 更新 index.md / log.md / overview.md
 - 待人工裁决的 review 项
 - Deep Research 的搜索查询
```

> 💡 **对应 DreamVault `Consolidator`**：
> 当前是"提炼+回读校验"两步。可升级为"分析→生成→回读校验"三段。
> - 分析步 = 让 LLM读候选 + 输出结构化建议（涉及哪些 entity、与谁矛盾）
> - 生成步 = 输出带 source 引用的"教训"（Memory）
> - 回读校验 =现有的 `Consolidator.verify()`，已经是第三道闸
>升级路径：`Consolidator` 增加 `analyze(_:)` 方法，LLM 输出"教训草稿 +矛盾候选"，再走现有 `consolidate()`流水线。

####② Compile-once, keep-current（增量编译）

> "新源进来时不是追加，而是更新现有 wiki 页、修订摘要、记录矛盾。"
> —— Persister 的本质是**合并**（merge），不是**追加**（append）。

> 💡 **DreamVault 已实现**（在 `Persister.swift`）：
> - `mergeMemoryMd()` 用 `<!-- dream:begin/end -->`标记圈出托管区，区内按 id锚点更新/新增/移除，**区外用户手写内容原样保留**。
> -归档记忆**移入 archive 页 +删 concepts 页**，不简单 append。
> 这是 DreamVault 比绝大多数 wiki 实现更稳的关键设计。

####③4-Signal Knowledge Graph（核心公式，不涉版权）

页面间关联度 =4 个信号加权：

| 信号 |权重 |含义 |
|------|------|------|
| Direct link | ×3.0 | `[[wikilink]]`互链 |
| **Source overlap** | ×4.0 |共享同一 raw源文件（最重要） |
| Adamic-Adar | ×1.5 |共同邻居加权 `Σ1/log(degree(w))` |
| Type affinity | ×1.0 | 同类型 bonus（entity↔entity 等） |

**Adamic-Adar 标准公式**：
```
score(u,v) = Σ over共同邻居 w of1/log(degree(w))
```
共同邻居越多、越"专属"（度数低），关联越强。degree(w) ≥2 ⇒ log恒正，无除零风险。

> 💡 **DreamVault 已实现基础**（在 `KnowledgeGraph.swift`）：
> - 无向图 + Adamic-Adar 已写（`adamicAdar(_:_:)` 和 `topRelated(to:limit:)`）
> - **只实现了 source overlap + Adamic-Adar 两个信号**（少了 direct link 和 type affinity）。下一步可在 `KnowledgeGraph` 里加这两个信号并按4-signal权重融合。

### Louvain社区检测（可选，难度大）

自动发现知识聚类 + 内聚度打分（实际边数 / 可能边数），内聚度 <0.15标记为稀疏社区。

> 💡 DreamVault 第一版**不需要**。如果以后有 Swift实现的 graphology- communities-louvain移植或等价算法再考虑。

### Async Review System（异步人工 in-the-loop）

LLM 在 ingest 时把"需要人判断"的项扔进 review队列，**不阻塞 ingest**。每个 review 项预生成搜索查询（Deep Research优化）。**动作类型预定义**（Create Page / Deep Research / Skip），防止 LLM 自己乱发明动作。

> 💡 **对应 DreamVault `ContradictionDetector` 的双向建链**：
> 检测到矛盾**不自动删**，而是双向 `contradicts`链接 + `Decayer`标 `needsReview`。这就是 review队列的 DreamVault 版本，已经在 `Persister` 的 `needsReviewIDs` 里登记 + dream-report 输出。
> **待补**：review队列的 Swift持久化 + DreamPanel UI（README 里标的"还没做"第5 项）。

### SHA256增量缓存

源文件先 hash，内容未变就跳过 ingest，**省 token 省时间**。

> 💡 DreamVault `Gatherer` 是按 `processed:false` frontmatter + `.dream/processed.json` 白名单判定要不要重收 — 这是更粗粒度但更"用户友好"的等价机制。**如果要精确到 byte-level增量**，可在 `Gatherer.gather()` 里加 SHA256 计算 +缓存。

---

##3. rohitg00/agentmemory（Apache-2.0，可借鉴更多细节）

仓库：[https://github.com/rohitg00/agentmemory](https://github.com/rohitg00/agentmemory)（22.2k stars，460 commits）
作者还另有一份独立的设计文档 gist：karpathy模式 +置信度评分 +生命周期 +知识图谱 +混合搜索。

> 这是 Karpathy LLM Wiki模式的**最完整工程实现**。TypeScript，写在 iii-engine运行时上（Mavis 不依赖这个，**只看思想**）。

### 五条值得学

####①4 层记忆（按用途分层，越往后越精炼）

| 层 |存什么 | 类比 |
|----|-------|------|
| **Working** |原始 tool-use观察 |短期记忆 |
| **Episodic** |压缩后的会话摘要 | "发生了什么" |
| **Semantic** |提炼出的事实和模式 | "我知道什么" |
| **Procedural** | 工作流和决策模式 | "该怎么做" |

类型分类：`pattern / preference / architecture / bug / workflow / fact`。

> 💡 **对应 DreamVault**：
> 当前 `MemoryStatus` 是 `candidate / durable / archived` 三态 —偏简。
> SPEC建议的折中是"两层（candidate → durable）+ archived"，够用。**第一版不做四层**，等量级上去再说。
> 但 `Memory.type`字段可以提前加（pattern / preference / architecture / bug / workflow / fact），便于将来自动选 `decayClass`。

####②艾宾浩斯衰减 +强化重置

**核心洞察**：retention随时间指数衰减，但每次"强化"（被访问、被新源确认）**重置曲线**。**不同类型衰减速度不同** —架构决策衰减慢（τ 长），临时 bug衰减快（τ短）。

```ts
//频率信号
frequency =1 - exp(-n / k)
//强化重置 = 每访问一次，lastAccess = now，相当于 Δt归零
```

> 💡 **DreamVault 已实现**（在 `Decayer.swift` + `Models.swift`）：
> - 三信号 salience：`recency * w_r + frequency * w_f + linkage * w_l`
> - `decayClass` 已实现：slow ×3.0 / normal ×1.0 / fast ×0.3
> - **强化重置** 通过 Persister写回 ledger 时更新 `lastAccess` 完成（每次被新 wiki 页引用就 +1 reinforceCount）
> - 已对齐，**无需改动**。

####③写时矛盾检测 +消解

新记忆写入前就与旧记忆比对矛盾，当场解决，**不堆积**。

> 💡 **DreamVault 已实现**（在 `ContradictionDetector.swift`）：
> - 用窄问题 +强制单词输出（"CONFLICT" / "OK"）降低误判
> - **只与 durable 比对**（candidate 之间不比对，避免放大成本）
> -双向建链 `contradicts: [String]`，**两边都不删**，交人工裁决
> - 已对齐。

####④隐私过滤（写入前脱敏）

源进 ledger之前先 strip secrets、API key、邮箱、token 等敏感模式。**这个脱敏发生在落库之前**，是负责任的默认。

> 💡 **DreamVault 已实现**（在 `Redactor.swift`）：
> - 正则覆盖：API_KEY、Bearer、AWS、GitHub token、private key block、generic secret、邮箱、CN 手机号、CN身份证、US 电话、信用卡、IPv4
> - 占位符标明类型（`[REDACTED_LABEL]`），不删整行
> -已在 `Gatherer` 进 ledger 前自动调用，已对齐
> - **一点小差距**：rohitg00还在 `<private>...</private>`块上做了边界处理（用户主动包起来的内容整段剥除）。可在 `Redactor` 里加一条规则 `(?s)<private>.*?</private>` 作为可选。

####⑤混合检索（BM25 + Vector + Graph）RRF融合

```
Score(d) = Σ over signal s ∈ {bm25, vector, graph} of w_s ·1 / (k + rank_s(d))
```

- BM25：精确关键词匹配（中文要 jieba/tiny-segmenter）
- Vector：语义相似度（可选，本地 MiniLM 免费）
- Graph：从 query抽实体当种子做 BFS
- **RRF (Reciprocal Rank Fusion)**融合三路结果，**不归一化分数**，只靠排名

**默认权重**：`bm25:0.4, vector:0.6, graph:0.3`（weight 不是必须相加 =1）

> 💡 **对应 DreamVault**：
> 当前 `KnowledgeGraph.adamicAdar` 是 Graph 信号的实现。**没实现 BM25也没实现 Vector**。
> DreamVault **不需要** RAG检索 — Karpathy 的量级判据告诉我们个人 vault 在 LLM Wiki路线下纯上下文就够了。
> **真正值得借鉴的不是检索**，而是这种"多信号融合"的思维方式应用到：
> - **salience 计算**：recency + frequency + linkage，已经是三信号融合，**RRF 可以试**（但要确认 `Decayer`现有加权平均 vs RRF哪个更适合 DreamVault 的语义）
> - **矛盾检测**：可以加一个"语义相似度"信号辅助，避免漏判（同义词不同写法）。但 LLM 调用已经够贵了，**先不加**，等数据。

###12 个 auto-capture hooks（不学实现，学理念）

```
SessionStart → UserPromptSubmit → PreToolUse → PostToolUse
→ PostToolUseFailure → PreCompact → SubagentStart → SubagentStop
→ TaskCompleted → Stop → SessionEnd → Notification
```

**关键约束**（写在 rohitg00 的 AGENTS.md 里）：
>遥测型 hook **必须 fire-and-forget**，绝不能阻塞 Agent。

> 💡 对应 DreamVault：dream引擎的夜间调度对标 `PostToolUse` / `Stop` — Agent干活后自动整理记忆。但 DreamVault 是 **launchd触发** 不是 hook，**哲学一样，工程实现不同**（我们用 cron/launchd，他们用 hook）。

---

##4. "archon-memory-core" — SPEC 里写的，但其实是 **archon**

> 🚨 **SPEC错误修正**：`REFERENCE_SPEC.md`提到的 `archon-memory-core`实际上是 [archon](https://github.com/SufficientDaikon/archon)（[GitHub trending镜像](https://gitcode.com/GitHub_Trending/archon)）。这是一个 **AI编码工作流引擎**（YAML 工作流 + git worktree隔离 + Web UI），**不是记忆库项目**。
>
> 我搜到的 archon文档里**没有任何"本地优先 +夜间整合 +主动遗忘 +显著度评分"的痕迹**。
>
>推测 SPEC当时指的项目**已经改名 /删库 / 转私有**，或者一开始就是另一种东西。
>
> **建议**：如果团队确实想参考"本地优先 +夜间整合 +主动遗忘 +显著度评分"这个**定位描述**，可以参考 `rohitg00/agentmemory` 的 README 第一段，它就是这四个点的生产级实现。

---

##5. "JordanMcCann/agentmemory" — SPEC 里写的，搜不到

> 🚨 **SPEC错误修正**：`REFERENCE_SPEC.md`提到的 `JordanMcCann/agentmemory` **GitHub 上搜不到**（截至2026-06）。
>
> 同名 `agentmemory` 在 GitHub 上至少有4 个：
> - **`rohitg00/agentmemory`** ←真正值得关注的那个（Apache-2.0，22k stars）
> - **`conversence/agentmemory`**（chromadb + Python，4 commits）
> - **`elizaOS/agentmemory`**（前身 JoinTheAlliance，ChromaDB + Postgres，面向 Eliza角色机器人）
> - **`langchain-ai/memory-agent`**（LangGraph示范，跟 agentmemory 不是一回事）
>
> SPEC写"JordanMcCann/agentmemory"标了 MIT许可证，但**找不到任何匹配**。可能是仓库被删 / 转手 / 从一开始就是误记。
>
> **建议**：把这一行改成 **`rohitg00/agentmemory`（Apache-2.0）**，理由：质量、活跃度、文档密度都是这个项目的实际档次最高。

---

##6. 对照表（汇总：DreamVault 内核 vs 参考实现）

| 算法能力 | 参考来源 | DreamVault状态 |备注 |
|---------|---------|----------------|------|
| 三层架构（raw/wiki/schema） | Karpathy | ✅ | 加了第4 层 `.dream/` 元数据 |
| 单层整合（提炼） | Karpathy | ✅ |候选/持久/归档三态 |
| **Two-Step CoT ingest** | nashsu | ⚠️ | 现在是"提炼+校验"两步；可升"分析→生成→校验"三段 |
| Compile-once增量合并 | nashsu | ✅ | `Persister.mergeMemoryMd`标记区增量合并 |
|艾宾浩斯衰减 +强化重置 | agentmemory | ✅ | `Decayer.salience` |
| 按类型设不同 τ | agentmemory | ✅ | `DecayClass` slow/normal/fast |
|矛盾双向建链（不删） | agentmemory | ✅ | `ContradictionDetector.link` |
|写时矛盾检测 | agentmemory | ✅ | 同上 |
|隐私脱敏（含中文） | agentmemory | ✅ | `Redactor`，CN 手机/身份证/邮箱/API key 全覆盖 |
|4 信号知识图谱 | nashsu | ⚠️ | 只有 source overlap + Adamic-Adar；缺 direct link + type affinity |
|异步 review队列 | nashsu | ⚠️ |矛盾走 `needsReview` + dream-report；缺持久化队列 + UI |
|4 层记忆分层 | agentmemory | ❌ 不做 | 第一版保持三层（候选/持久/归档）足够 |
| BM25/Vector检索 | agentmemory | ❌ 不做 | 个人 vault走纯 LLM Wiki路线，不需要 |
| Auto hooks 自动捕获 | agentmemory | ❌ 不同路径 | DreamVault 用 launchd夜间触发 |
|增量 SHA256缓存 | nashsu | ⚠️ |当前的 `processed.json`粒度较粗；可加 |
| Deep Research / 反向补缺 | nashsu | ❌ 不做 | 个人 vault 不需要 |
|标签式动作（防 LLM乱发） | nashsu | ✅ | `DecayAction` 三选一（keep/archive/needsReview） |
| Git 作为事务边界 | Karpathy | ✅ | `GitRunner` + Persister末尾 commit；失败 discardTrackedChanges |
| DreamCycle 五步编排 | archon | ❌ **这是 DreamVault 目前最大缺口** | 没有总入口串起 Gather→Consolidate→Decay→Persist |

---

##7. DreamVault 第一棒 Claude 的明确清单（参考本笔记排序）

按"性价比 × 当前缺口"排：

1. **`DreamCycle` 五步编排器**（最大缺口，目前引擎没有总入口）
 -串起 Gather → Consolidate → Decay → Persist → Commit
 -失败回滚：外层包 `do/catch`，catch 里调 `GitRunner.discardTrackedChanges()` + 删除 DreamCycle 自己新建的未跟踪文件
2. **`Consolidator`升 Three-Step CoT**（加 `analyze()` 方法）
 - 分析步：LLM 输出"教训草稿 +矛盾候选"（结构化 JSON）
 - 生成步：从草稿生成 Memory（带 source引用）
 -校验步：现有的 `verify()`
3. **`KnowledgeGraph` 加4-signal**（加 direct link + type affinity，按 nashsu权重3.0/4.0/1.5/1.0融合）
4. **`Redactor` 加 `<private>...</private>`块脱敏**
5. **`Gatherer` 加 SHA256增量缓存**
6. **矛盾 review队列持久化**（`.dream/needsReview.json`）+ DreamPanel UI
7. **`Memory.type`字段**（pattern/preference/architecture/bug/workflow/fact）提前加上，方便将来自动选 decayClass

> ⚠️ **不建议做的**：BM25/Vector检索、4 层记忆、Deep Research、Auto hooks — 个人 vault走 LLM Wiki路线，这些是过度设计。

---

##8. 一句话给团队

**真正值得学的三个项目 + 它们给 DreamVault留下的最大礼物：**

- **Karpathy**：让我们从第一天起就走"编译一次、持续保鲜"而不是 RAG
- **nashsu**：让我们有了 Two-Step CoT、4 信号图谱、异步 review 的设计模式（**只学思想，原生重写**）
- **rohitg00/agentmemory**：让我们有了4 层记忆 +艾宾浩斯衰减 +写时矛盾检测 +隐私脱敏的**完整工程参照**

**DreamVault已经有 ~70%思想落地了**，剩下的30% 是：
- **编排器**（最关键）+矛盾持久化队列 + UI
- **Three-Step CoT升级**（最有想象力）+4-signal 图谱

没有一行代码需要从外部搬进来 —全部 Swift 原生写。
