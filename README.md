# DreamVault（内核交付）

macOS 原生 Markdown 知识库 + dream 夜间记忆整理。本仓库是**内核交付**：架构 + 最难的两个算法（衰减、整合防幻觉）的可编译 Swift 代码与测试。GUI 外壳由你用 Claude Code 在本机接着长。

## 现在能跑什么

```bash
swift test     # 运行 Decayer / Consolidator 的单元测试
```

`DreamEngine` 库不依赖 SwiftUI，可独立编译、独立测试、被 launchd 调起。

## 已实现（硬骨头）

- `Decayer.swift` — salience 三信号打分 + 保守降级（archive 而非删除，矛盾交人工）
- `Consolidator.swift` — 整合四道闸（脱敏 / 强制引用 / 回读校验 / 多源分级）
- `Redactor.swift` — 写入前隐私脱敏，覆盖中英文（API key/token/邮箱/中国手机号/身份证/信用卡等）
- `ContradictionDetector.swift` — 新教训与现有 durable 记忆比对，矛盾双向建链交人工裁决（不自动删）
- `Models.swift` — 纯 .md frontmatter + ledger.json 的数据模型
- 完整单元测试覆盖以上边界

## 还没做（你的下一步，体力活）

1. `LLMProvider` 的真实实现：先写 `LocalProvider`（Ollama，零成本调参），再加 `CloudProvider`（Anthropic/OpenAI），运行时切换
2. `Gatherer`（扫 raw/、调 Redactor 脱敏）/ `Persister`（写 MEMORY.md、维护 wiki [[links]]、git commit）
3. 知识图谱：原生轻量图结构 + Adamic-Adar 打分（见 REFERENCE_SPEC.md）
4. 按类型衰减：给 Memory 加 decayClass，不同类用不同 τ
5. SwiftUI 外壳：VaultBrowser / Editor（raw 模式锁定）/ DreamPanel
6. launchd plist 挂夜间调度
7. 用真实 raw 日志跑 2 周，盯 dream-report 调衰减参数

详见 `docs/ARCHITECTURE.md` 与 `docs/REFERENCE_SPEC.md`。
