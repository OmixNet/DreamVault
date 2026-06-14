# DreamVault .harness/

> 项目级 agent team 元数据. 给 mavis reins 提供 project-specific context.

## 结构

```
.harness/
├── AGENTS.md                # 项目速览 (build/test/commit/tag/CI 约定)
├── reins/
│   ├── coder.md             # Swift/SwiftPM 实现
│   ├── verifier.md          # 评测 / 测试 / 量化
│   └── release.md           # tag / push / changelog
├── workflows/
│   └── ci.md                # GitHub Actions ci-smoke + nightly-eval
└── skills/
    └── dream-cycle.md       # dream run / 调试 / 部署 skill
```

## 怎么用

任何接手 DreamVault 的 mavis agent (coder / verifier / release / dream skill) 第一件事读:
1. `.harness/AGENTS.md` — 项目速览, build/test 约定, tag 模式
2. `.harness/reins/<role>.md` — 角色对应 scope / 流程 / 跟其他 rein 协调
3. `.harness/skills/dream-cycle.md` (如跑 dream) — 端到端命令

## 跟 .harness 关系

- `~/.mavis/agents/<name>/` 是**全局 agent** (coder / verifier / mavis / main)
- `<repo>/.harness/reins/<name>.md` 是**项目级 rein** (本地化角色)
- mavis 调度时, 全局 agent 走项目级 rein 拿到 project-specific 上下文

## DreamVault reins 总结

- **coder** (coder role) — Swift/SwiftPM 实现, 走 worktree, 不破坏 623 test baseline
- **verifier** (verifier role) — 跑测试 + 真量化, 对比 v0.7.6 baseline (88% / 92%)
- **release** (release manager) — tag / push / changelog, 跟 verifier 协调
- **dream-cycle** (skill) — dream run / 调试 / 部署 (5 层 config / 真 LLM / 真量化 / launchd)

## 添加新 rein

1. 写 `.harness/reins/<new-name>.md` (跟 coder.md 同结构: scope / 工作流 / gotchas / invariant / 协调)
2. 更新 `.harness/AGENTS.md` 加 rein 索引
3. commit + push
