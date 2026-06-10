# DreamVault 架构设计

一个 macOS 原生（Swift + SwiftUI）的轻量 Markdown 知识库，内置 LLM Wiki 编译与 dream 夜间记忆整理。本文件是工程蓝图，定义模块边界、数据流与两个最难的算法（衰减、整合防幻觉）。

## 0. 设计原则（必须守住）

1. **raw/ 永远只读、永不衰减。** wiki/ 和 MEMORY.md 可错、可重建；原始日志是唯一真相源。这是防止"衰减误删"造成不可逆损失的根本保险。
2. **存储即文件。** 纯 .md + YAML frontmatter，git 做版本与回滚。任何编辑器/终端都能改，app 不锁定数据。
3. **dream 是可审查的，不是黑盒。** 每次夜间任务产生一个 git commit + 一份 dream-report，衰减/降级/合并都能 diff、能 revert。
4. **功能克制。** GUI 只做三件事：扔文件进来、轻度编辑、浏览 wiki。智能全在后台 dream 引擎，前台不堆功能。

## 1. 文件布局（vault 即一个 git 仓库）

```
MyVault/
├─ .git/
├─ raw/                 # 只读层：原始日志，永不被 dream 修改
│  ├─ 2026-06-07-claude-session.md
│  ├─ 2026-06-07-codex-output.md
│  └─ ...
├─ wiki/                # LLM 编译层：实体页/概念页/综合页，带 [[wikilinks]]
│  ├─ entities/
│  ├─ concepts/
│  └─ syntheses/
├─ MEMORY.md            # 单一长期记忆：提炼出的规则与教训，常驻背景
├─ .dream/              # dream 引擎的元数据（不进 wiki，但进 git）
│  ├─ ledger.json       # 每条记忆的衰减状态：salience、最后访问、强化次数
│  ├─ reports/          # 每晚一份 dream-report.md，可读可审查
│  └─ config.json       # LLM 选择、衰减参数、调度
└─ .gitignore
```

要点：`raw/` 在文件系统层面挂为只读（app 启动时 chmod，dream 引擎对它只有读权限）。这把"原则 1"变成机制而非自觉。

## 2. 模块边界

```
┌─────────────────────────────────────────────┐
│  SwiftUI 前台 (DreamVaultApp)                  │
│  - VaultBrowser: 文件树 + wiki 浏览            │
│  - Editor: 轻度 markdown 编辑 (raw 模式锁定)   │
│  - DreamPanel: 看 dream-report、手动触发、回滚 │
└───────────────┬─────────────────────────────┘
                │ 调用
┌───────────────▼─────────────────────────────┐
│  DreamEngine (纯 Swift, 无 UI 依赖)            │
│  ┌─────────────┐ 你选的四块 dream:            │
│  │ Gatherer    │ 收集 raw/ 中未处理日志        │
│  │ Consolidator│ 提炼规则/教训 (整合防幻觉)     │
│  │ Decayer     │ 衰减打分 + 降级旧记忆          │
│  │ Persister   │ 写回 MEMORY.md + 维护 wiki链接 │
│  └─────────────┘                              │
│  - Ledger: 记忆衰减状态的读写                  │
│  - GitRunner: commit/revert 封装               │
│  - Scheduler: 夜间触发 (launchd)               │
└───────────────┬─────────────────────────────┘
                │ 抽象接口
┌───────────────▼─────────────────────────────┐
│  LLMProvider (protocol)  ← 可切换             │
│  - LocalProvider  (Ollama, 免费/私密)          │
│  - CloudProvider  (Anthropic/OpenAI, 高质量)   │
└─────────────────────────────────────────────┘
```

关键：DreamEngine 不 import SwiftUI。它能单独跑、单独测、单独被 cron/launchd 调起。GUI 只是它的一个调用者。这让你能先把内核跑通再长外壳。

## 3. dream 五步数据流（夜间一次）

```
1. Gather    raw/*.md 中 frontmatter 标 processed:false 的 → 候选集
2. Consolidate  候选集 → LLM 提炼 → 候选"教训"(带 source 引用)
3. Decay     ledger 中所有旧记忆 → 重算 salience → 标记待降级
4. Persist   高 salience 教训写入 MEMORY.md；低 salience 降级/归档；更新 wiki [[links]]
5. Commit    git commit + 写 dream-report；raw 候选标 processed:true
```

每步失败都不破坏 vault：要么整体 commit，要么整体不动（git 是事务边界）。

## 4. 衰减算法（最难点之一）

不照搬艾宾浩斯原始公式，因为知识不是记忆术卡片。用一个**显著度分数 salience ∈ [0,1]**，综合三个信号：

```
salience = w_r · recency + w_f · frequency + w_l · linkage

recency   = exp(-Δt / τ)        最后访问越久越低；τ 可调（默认 30 天）
frequency = 1 - exp(-n / k)     被强化/引用次数越多越高；k 默认 5
linkage   = min(1, links / L)   被 wiki 多少页引用；L 默认 8
```

降级规则（保守，宁可不删）：
- salience < 0.15 且 90 天未访问 → **降级**到 `wiki/archive/`，不删，仍可 grep、可 git 找回
- 永不在夜间自动 **物理删除** 任何内容
- 矛盾检测：新教训与旧教训冲突时，不删旧的，而是在两者间加 `contradicts::` 链接，交给你在 DreamPanel 里裁决

防误删的三道闸：raw 只读 + 降级而非删除 + 人工裁决矛盾。

## 5. 整合算法（最难点之二：防幻觉）

提炼"用户总倾向 SwiftUI 而非 AppKit"这类规则，最大风险是 LLM 编造一条 raw 里根本没有的"教训"。三条约束：

1. **强制引用。** 每条新教训必须附带 ≥1 个 raw/ 源文件的具体行引用。无引用的教训直接丢弃。
2. **证据阈值。** 一条规则要进 MEMORY.md，需在 ≥2 个独立 raw 源中出现支撑（单次观察只进 wiki 的"候选"区，不进常驻 MEMORY.md）。这对应你说的"从一次观察到这是规律"。
3. **回读校验。** 提炼后，把生成的教训 + 引用的 raw 片段一起回喂 LLM 问"这条结论是否被这些片段支撑?"，否决掉幻觉。

## 6. 你拿到后的下一步（用 Claude Code 在本机继续）

1. `swift build` 跑通 DreamEngine（本仓库已给可编译核心 + 测试）
2. 接一个真实 LLMProvider（先 Ollama 本地，零成本调参衰减）
3. 用你真实的 raw 日志跑 2 周 dream，盯 dream-report 看衰减是否误伤
4. 衰减参数稳定后，再用 Xcode 长 SwiftUI 外壳（VaultBrowser/Editor/DreamPanel）
5. launchd plist 挂夜间调度

外壳是体力活；内核（4、5 两节）是这份交付帮你啃掉的硬骨头。
