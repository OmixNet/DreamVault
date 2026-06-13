# DreamVault 算法评审（算法工程师视角）

> 范围：DreamEngine 全部算法路径（衰减 / 图谱 / 整合 / 矛盾检测 / 脱敏 / 收集）。
> 基线：含 SourceRefValidator、Reinforcer 的当前 main。
> 结论先行：**算法骨架能支撑研发目的，但存在 1 个结构性缺口使核心承诺（MEMORY.md）在生产管线下不可达成，必须先修；其余是参数与信号层面的优化空间。**

---

## 1. 结构性缺口（不修则研发目的无法达成）

### 1.1 durable 升级路径不可达 ⛔

证据链：

- `Gatherer.gather()` 每个 raw 文件产出 1 条 candidate，**恒定 1 个 source**（Gatherer.swift:120-123）
- 三段 CoT 的每个 `MemoryDraft` 恒定 1 个 source（Consolidator.swift:391-395）
- `classify()` 要求 `distinctSourceCount >= 2` 才升 durable（Consolidator.swift:99-101）
- `DreamCycle` 合并 ledger 仅按 id 去重，id 是 UUID——**跨晚相同教训生成不同 id，既不合并 source 也不识别重复**（DreamCycle.swift:188-192）
- 全仓 grep 无任何文本相似度/去重逻辑

推论：生产管线下没有任何记忆能积累到 2 个独立源 → **永远没有 durable** → `Persister` 只为 durable 写 MEMORY.md 和 wiki 页 → 用户拿到的常驻记忆永远为空，所有教训只躺在 `ledger.json` 里不可见。现有测试全部用手工构造的多源 Memory，掩盖了这条断路。

**修复方案（也是本报告最重要的一条）**：dream 第 2.5 步加「同质合并」——新教训与 ledger 现有记忆做相似度匹配（见 §4.1），命中则不新建条目，而是把新 source 追加进现有记忆的 `sources` 并触发 `dreamReference` 强化；`distinctSourceCount` 随之自然增长，durable 门槛恢复可达。验收：同一教训出现在 2 个 raw 文件、分两晚处理后，ledger 中是 1 条 durable 而非 2 条 candidate。

### 1.2 两步路径产出的不是「教训」

`consolidate()`（2 步）从不调 LLM 做提炼，只做过滤分级——进去的 candidate.text 是**整个 raw 文件正文**，出来还是它。而 `ConsolidationConfig.useThreeStepCoT` 默认 `false`，即**默认生产管线把整篇原文当一条"教训"写进 ledger**。三段失败时的 fallback 也回到这条路径，意味着 LLM 偶发抽风的那晚会混入整篇原文条目。

**修复**：2 步路径明确降级为 mock/测试专用；真实 provider 强制三段；fallback 改为「该 candidate 跳过、明晚重试」而非降级到非提炼路径。

---

## 2. 逐算法评估

### 2.1 衰减（Decayer）— 设计合理，两个参数行为需知情决策

线性三信号混合（0.5/0.3/0.2，权重和=1）数学上干净，decayClass 扩展向后兼容。两个隐含行为：

- **4 次强化 = 永生**。`w_f·(1-e^(-n/5)) ≥ 0.15` 在 n≥4 时恒成立，此后无论闲置多久都不会跌破归档阈值。对个人知识库可能正是想要的（高频确认的知识不该消失），但这是 frequency 地板决定的涌现行为而非显式设计，建议写进文档或给 frequency 也加新近度衰减（指数滑动的强化计数）。
- **fast 类的 9 天 τ 被 90 天 stale 门槛架空**。归档需同时满足 salience<0.15 **且** 90 天未访问，`staleDays` 对三类统一。fast 类记忆在第 10 天 salience 已≈0，却仍要等满 90 天。建议 `staleDays` 也乘 `tauMultiplier`（fast≈27 天），否则 decayClass 只影响分数不影响命运。

linkage 信号与图谱共源建边存在弱共线性（源多→边多→inboundLinks 高），个人规模无碍，不必处理。

### 2.2 知识图谱（KnowledgeGraph）— 实现正确，信号太薄

Adamic-Adar 实现正确（共同邻居 degree≥2，无除零；hub 文件形成的 clique 会被 1/log(deg) 自动抑制，对热门源文件有天然抗性——这点做得比看起来好）。`topRelated` 全局 O(N²·d̄)，N≤5000 无压力。

问题是**只有 1/4 信号**（共源连边）：单源新记忆只与同源记忆连通，跨文件的同主题记忆永远无边。优化顺序：① 接入 WikilinkIndex 的显式 `[[链接]]` 边（解析器已有，纯接线）；② kind 亲和度加权；③ 语义边（见 §4.1）。Louvain 聚类在个人规模下收益低，不建议做。

### 2.3 整合三段 CoT（Consolidator）— 防幻觉设计扎实，裁判有自偏

四道闸（脱敏→有源→excerpt 子串校验→回读 verify→分级）层层确定性递减，结构正确。SourceRefValidator 的归一化子串校验是零成本确定性闸，好设计。遗留问题：

- **verify 是同模型自我裁判**：生成与校验用同一 LLM，错误相关性高，幻觉教训有相当概率自我放行。优化：verify 三次采样多数投票（成本×3，可配置），或换更小的独立模型当裁判（qwen2.5:3b 之类，裁判任务不需要大模型）。
- **关键词解析脆弱**：`verify` 用 `contains("YES")`——模型输出「证据不足，不能说 YES」会被判通过。改结构化输出（见 §4.2）。

### 2.4 矛盾检测（ContradictionDetector）— 有一个会反向误判的解析 bug

`answer.uppercased().contains("CONFLICT")`：模型若回答 **"NO CONFLICT"（最自然的否定表述）会被判为矛盾**。本地小模型几乎必然触发。这是确定性 bug 不是调参问题：改为 JSON 输出 `{"conflict": bool}` 或严格首词匹配。O(N×M) 成本问题与预筛方案见整改方案 P0-1，不重复。

### 2.5 脱敏（Redactor）— 合格，误伤治理按整改方案 P1-3 执行

规则排序正确（具体→宽泛），中文场景覆盖是参考项目没有的。Luhn/身份证校验位/IP 白名单照 P1-3 做即可。补充一点：脱敏发生在 LLM 调用前，意味着 LLM 永远看不到密钥原文——这个顺序是对的，别改。

### 2.6 收集（Gatherer）— 缺分块，长文件会静默劣化

整个 raw 正文塞进一条 candidate.text 直送 LLM。Ollama 默认 num_ctx 常为 2048-8192，一篇 50KB 的 Claude session 日志会被**静默截断**——analyze 只看到开头，后半段的教训无声丢失，且无任何告警。修复：按标题/固定字数分块（带行号偏移，顺带让 sourceLine 真实化——现在 excerpt 恒为开头 200 字符、line 恒为正文首行，引用粒度名不副实）；report 记录每文件分块数与截断告警。

---

## 3. 测试方法论的盲区

MockLLM 默认 handler 对 verify 恒答 YES、对矛盾仅凭关键词触发——**所有闸门测试测的是管道连通性，不是判别力**。建议建一个 30 条的金标评测集（10 条有据教训 / 10 条幻觉 / 10 对矛盾），用真实 Ollama 跑 verify 与 conflicts 的精确率/召回率，写进 CI 之外的 `make eval`。没有这个数字，三道闸的"防幻觉"只是结构上的承诺。

---

## 4. 横切优化：一次投资服务三处

### 4.1 本地 embedding（NaturalLanguage 框架，零依赖零成本）

`NLEmbedding`/`NLContextualEmbedding` 是 macOS 系统自带、离线、免费。一份记忆文本向量可同时解决三个独立提出的需求：

1. **同质合并**（§1.1 的修复核心）：新教训 vs ledger 余弦相似 > 阈值 → 合并 source 而非新建
2. **矛盾预筛**：只对相似度中高（同主题）的记忆对调 LLM 判矛盾，O(N×M) 降到 O(top-k)
3. **图谱语义边**：补上跨文件同主题连边，解决 2.2 的信号稀薄

注意中文支持需实测 `NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)` 可用性，不可用则回退词向量平均或字符 n-gram Jaccard（去重场景 Jaccard 已够用）。

### 4.2 全部 LLM 判别输出结构化

verify / conflicts / analyze / generate 统一走 Ollama 的 `format: json_schema` 约束输出，消灭 `contains("YES")`/`contains("CONFLICT")` 这类解析雷。一次改造，2.3 与 2.4 的解析问题同时消失。

---

## 5. 优先级汇总

| 序 | 项 | 性质 | 不做的后果 |
|---|---|---|---|
| 1 | §1.1 同质合并 + durable 可达 | 结构缺口 | MEMORY.md 永远为空，产品核心承诺落空 |
| 2 | §2.4 CONFLICT 解析 bug | 确定性 bug | 真实模型下大量假矛盾，淹没人工裁决 |
| 3 | §1.2 两步路径降级为测试专用 | 设计修正 | 默认配置把原文当教训，ledger 被污染 |
| 4 | §2.6 Gatherer 分块 | 静默劣化 | 长日志后半段教训无声丢失 |
| 5 | §4.2 结构化输出 | 鲁棒性 | 解析失败率与误判率不可控 |
| 6 | §4.1 embedding 三用 | 优化 | 成本与召回都停留在 demo 规模 |
| 7 | §2.1 两个衰减参数决策 | 知情决策 | 行为与直觉不符但不致命 |
| 8 | §3 金标评测集 | 方法论 | 防幻觉效果永远只是声称 |

一句话总结：这套算法的**防御性设计（只读层、确定性闸门、事务边界）超出业余项目水准**，但**记忆生命周期的"晋升"半条链路断着**——它现在是一台能安全地遗忘、却还不能有效地记住的机器。先修 1-3，这个项目的研发目的就从"理论可达"变成"实际可达"。
