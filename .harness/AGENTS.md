# DreamVault — Project Memory (AGENTS.md)

> 启动项目工作的"30 秒速览". 任何接手 DreamVault 的 agent 第一件事读这个文件.

## 项目一句话

**DreamVault** = 个人/小圈子 Mac 原生工具. macOS SwiftPM 项目, 引擎 + CLI + GUI 三层架构.
- 引擎: `Sources/DreamEngine/` (跨文件 dedup, 矛盾检测, 衰减, 图谱, 评测, embedding)
- CLI: `Sources/dream/` (dream run / dream eval / dream search / dream status)
- GUI: 同上目录 SwiftUI (`Entry / EditorPane / SettingsView / MenuBarController`)
- 测试: `Tests/DreamEngineTests/` + `Tests/DreamTests/`
- 文档: `docs/IMPROVEMENT_PLAN.md` (产品) + `docs/ALGORITHM_REVIEW.md` (算法) + `docs/changelog/`

## Build / Test

⚠️ **mavis bash shim corrupts `swift <cmd>`** — 必须用 wrappers, 不然命令被加 "2":
- `/tmp/dv_main_build` (or `/tmp/dv_p<N>_build` for worktree)
- `/tmp/dv_main_test` (or `/tmp/dv_p<N>_test`)
- hardcode `swift build` / `swift test` + Xcode 26 toolchain PATH
- 触发条件: `swift test`, 单字符 args, paths like `DreamVault` or `/usr/lib`

**worktree 编辑必须用 worktree 绝对路径** (`/tmp/dv-p<N>/...`), 不复用 main 路径.
Edit 工具不感知 worktree, 写错路径直接污染 main (P3-5 follow-up 踩过).

**P3-5 + 后续 P3 件** 走 worktree pattern:
1. `git worktree add /private/tmp/dv-p<N> -b feat/p<N>-<topic> main`
2. 创建 wrappers (`/tmp/dv_p<N>_build` + `/tmp/dv_p<N>_test`)
3. 编辑 + 测试全在 worktree
4. `git add` + `git commit` + `git merge` to main
5. `git tag -a v<N>.<X>.<Y>` + `git push` (sleep 20-30 if 198.18.0.x NAT hang)
6. `git worktree prune` 清理

## Commit 约定

- 评审修复 / P3 件: `feat(P3-N): <一句话>` 走 `Mavis <AI@minimax.io>`
- 8h 用户 review 改动 / frontend 整理: `<type>(<scope>): <一句话>` 走 `biomatrix <biomatrix@dreamvault.local>`
- `<type>`: feat / fix / refactor / test / docs / ci
- 标题 ≤ 72 字符, body 用 `-m "<summary>" -m "<body>"` 多段写
- changelog 在 `docs/changelog/v<X>.<Y>.<Z>-<topic>.md` (P3-X 评审, release, fix)
- 评审引用: §1.1 / §2.3 / §2.4 / §3 / §4.1 / §4.2 (P3 评审文档)

## Tag 模式

- v0.2.0 → v0.8.1 = **34 tags** 总 (v0.8.0 是 v0.7 系列收口)
- P3 评审全 13 件 ship: P3-1/2/3/4/5/6/7/8 + 5 个 follow-up
- 8h 用户 review: 4 commit (refactor + fix + test + frontend+docs)
- 数字: 623 tests pass, 真 Ollama 量化 88% (verify) + 92% (contradiction)
- 下个版本号: 跟用户确认, 默认 v0.8.x for CI/真量化, v0.9.0 整 v0.8 收口

## 真实 bug 修复 (8h review 发现)

- **ForceLayout 边去重笔误** (P2-2 图谱): 老 `"\(e.u)|\(e.u)"` 两侧都用 e.u, 修用 min/max
- **NightlyDreamScheduler launchctl silent fail**: 加 LaunchctlResult + Status.lastError
- **RawReadonlyGuard 真实 bug** (P0-3 后续): 0o555 把 GUI Import 锁死, 改 0o755 目录 + 0o555 文件

## CI

- `.github/workflows/ci-smoke.yml` — push/PR/manual, ~30s (build + test + mock 100 case)
- `.github/workflows/nightly-eval.yml` — cron 03:00 UTC + manual, 5-10min (真 Ollama gemma2:2b)
- `scripts/ci-smoke.sh` / `scripts/nightly-eval.sh` — 本地同款
- `make ci-smoke` / `make nightly-eval` — Makefile 入口

## 项目特定的踩坑

详见 `docs/changelog/*.md` 各 commit. 高频踩坑:
- **Swift Set 迭代顺序非确定** — 测试断言必须 a/b 顺序无关 (`(a=="x" && b=="y") || (a=="y" && b=="x")`)
- **Edit 工具不感知 worktree** — 写错路径污染 main
- **mavis bash shim appends "2"** — 走 wrappers
- **mavis-trash 一次一文件** + 绝对路径 (多文件会把 cwd 一起 trash)
- **GitHub 198.18.0.x NAT hangs** — `sleep 20-30` 重试, HTTPS URL 更稳
- **Makefile `?=` 语法 zsh 报错** — 走 `${VAR:-default}` shell 默认值
- **NLEmbedding CJK 仅 zh-Hans 支持** — zh-Hant / ja / ko 不支持, auto 模式按 CJK 字符自动选
- **EmbeddingProvider 阈值 0.85 而非 0.7** — NLEmbedding 整体偏高 (机器学习 vs 苹果水果 0.81)
- **Memory init `inboundLinks: Int = 0`** (不是 [String]), `MemoryStatus` 无 .draft (用 .candidate)

## 完整 reins

- `reins/coder.md` — Swift/SwiftPM 实现
- `reins/verifier.md` — 评审 / 测试 / 量化
- `reins/release.md` — tag / push / changelog
- `workflows/ci.md` — CI 集成
- `skills/dream-cycle.md` — dream run / 调试
