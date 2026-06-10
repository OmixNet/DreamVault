# DreamVault

macOS 原生 Markdown 知识库 + dream 夜间记忆整理。本仓库是**内核**（DreamEngine 库 + 端到端测试 + 文档），不包含 GUI 外壳。

## 跑起来

```bash
swift test
```

跑全套单元测试 + 集成测试：**25/25 通过**（Decayer 6 / Consolidator 4 / ContradictionDetector 3 / Redactor 5 / DreamCycle 7）。

> **环境提示**：本机若 `swift` driver spawn 子命令失败（找不到 `swift-test` 等），需把 Xcode toolchain 加进 PATH：
> `export PATH="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"`
>
> 这是因为 `/usr/bin/swift`（Apple CLT）只是个 multi-call driver，真正的 `swift-test` / `swift-build` 在 Xcode toolchain 里。

## 已实现（DreamEngine 库 — 9 个源文件）

### 核心模型
- `Models.swift` — `Memory` / `SourceRef` / `Ledger` / `MemoryStatus` / `DecayClass` 数据模型，附自定义解码兼容旧 ledger

### 衰减（架构文档第 4 节，硬骨头之一）
- `Decayer.swift` — salience = w_r·recency + w_f·frequency + w_l·linkage
  - recency 用 `exp(-Δt/τ)`，τ = baseTau × decayClass 系数（slow ×3.0 / normal ×1.0 / fast ×0.3）
  - 保守降级：salience < 0.15 且 90 天未访问 → `archive` 而**非**物理删除
  - 矛盾永远走 `needsReview` 人工裁决
  - archived 状态不会再次降级

### 整合防幻觉（架构文档第 5 节，硬骨头之二）
- `Consolidator.swift` — 四道闸：① 脱敏 ② 强制引用 ③ LLM 回读校验（必须 YES）④ 独立源数 ≥2 才升 durable
- `ContradictionDetector.swift` — 写时矛盾检测 + 双向建链，**不删任何一方**，交人工裁决
- `Redactor.swift` — 写入前隐私脱敏，中英文全覆盖（API key / Bearer / AWS / GitHub token / private key block / 邮箱 / **CN 手机号** / **CN 身份证** / US 电话 / 信用卡 / IPv4）

### 五步 dream 编排（内核总入口 — 补上了最大缺口）
- `DreamCycle.swift` — `runOnce()` 串起 `Gather → Consolidate → Decay → Persist → Commit`，失败分阶段回滚（git 事务边界 + 清理 .dream/ 写了一半的文件）
- `Gatherer.swift` — 扫 raw/ 中 `processed:false` 的文件，脱敏后产出 candidate；processed 状态走 `.dream/processed.json` 不写回原文件（**raw 永远只读**）
- `Persister.swift` — 写 MEMORY.md 增量合并（`<!-- dream:begin/end -->` 标记区按 id 锚点更新）、维护 wiki/ 概念页 + 归档页、记 dream-report、落 ledger.json；注入 GitRunner 自动 commit
- `GitRunner.swift` — git 子命令封装，统一署名 `DreamEngine <dream@dreamvault.local>`（不依赖宿主机 git config），失败回滚用 `discardTrackedChanges()`

### 图谱 + LLM
- `KnowledgeGraph.swift` — 原生无向图 + **Adamic-Adar** 打分（`Σ 1/log(degree(w))`），来源重叠建边，`topRelated(to:limit:)` 返回前 N 个相关节点
- `LLMProvider.swift` — `LLMProvider` 协议 + 两个实现 + 工厂
  - `MockLLMProvider` — 零依赖 mock，按 prompt 关键字返回 YES/NO/CONFLICT，供测试与本地离线跑通
  - `OllamaProvider` — 真本地 Ollama（`http://127.0.0.1:11434/v1/chat/completions` OpenAI 兼容），纯 URLSession 无 SDK 依赖
  - `LLMFactory.fromEnvironment()` — 读 `DREAMVAULT_LLM={mock|ollama}` + 可选 `OLLAMA_BASE_URL` / `OLLAMA_MODEL` 覆盖

## 文档

- `docs/ARCHITECTURE.md` — 架构蓝图（原则 / 模块边界 / 五步数据流 / 衰减 / 防幻觉）
- `docs/REFERENCE_SPEC.md` — "先学后写"的学习产物（4 个参考项目的许可证红线 + 思想摘要）
- `docs/LEARNED_ALGORITHMS.md` — **强烈推荐**第 1 棒 Claude 先读这个：三个真正值得学的项目（Karpathy LLM Wiki gist / nashsu/llm_wiki / rohitg00/agentmemory）的思想提取 + 与 DreamVault 内核的对照表 + 待补清单

## 下一步（体力活，外壳方向）

1. **SwiftUI 外壳** — VaultBrowser（文件树 + wiki 浏览） / Editor（raw 模式锁定） / DreamPanel（看 dream-report、手动触发、回滚）
2. **launchd plist 夜间调度** — 调起 `DreamCycle.runOnce()`
3. **CLI 入口** — 一个 `dream` 命令行二进制（不在 Package.swift products 里，单独 target；用 `LLMFactory.fromEnvironment()` 选 provider；带 `--dry-run` 标志）
4. **生产调参** — 用真实 raw 日志跑 2 周，盯 dream-report 调 `DecayConfig`（默认权重 0.5/0.3/0.2、τ 30 天、阈值 0.15、staleDays 90 都是起点）

## 仓库

- GitHub: <https://github.com/OmixNet/DreamVault>
- 协议：MIT（待定，可改）

## 致谢

思想来源（不照抄源码）：
- [Karpathy 的 LLM Wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) — 整个范式的源头
- [nashsu/llm_wiki](https://github.com/nashsu/llm_wiki)（GPL v3）— 桌面实装参考
- [rohitg00/agentmemory](https://github.com/rohitg00/agentmemory)（Apache-2.0）— Agent 记忆层生产级参考
