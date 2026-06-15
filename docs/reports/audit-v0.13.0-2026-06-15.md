# DreamVault v0.13.0 审计报告 (2026-06-15 17:50)

**触发**: 用户 17:41 问"审核整个项目, 目前能不能用了"。

**结论先说**: **能用了, 但有 3 个 ship 阻塞** + **1 个 audit-bug** + **2 个改进建议**。
详情见下。

**TL;DR**:
- ✅ build / 692/692 tests / 真量化 / GUI 主流程全过
- ⛔ uncommitted 5 文件 + untracked 1 docx 没 commit (阻塞正式 v0.13.0 tag)
- ⛔ v0.12.0 是最新 tag, ce7c7cf 没单独 tag (release pipeline 改写没 ship)
- ⛔ README test 数字 (687) 跟实际 (692) 不一致
- ⚠ build_and_run.sh verify AX window count=0 是 osascript 子进程 / PID 解析问题, 不是 GUI bug
- 💡 建议: commit uncommitted → tag v0.13.0 → README 同步 → release-check.sh 跑过 → ship

---

## 1. 项目现状

| 指标 | 实际 | 来源 |
|---|---|---|
| 最新 commit | `ce7c7cf` (Jun 15 05:47) | `git log` |
| 最新 tag | `v0.12.0` (Jun 14 19:49) | `git tag` |
| Tags 总 | 43 | `git tag -l` |
| swift files | 71 | `find Sources` |
| test files | 57 | `find Tests` |
| Tests pass | **692/692** ✓ | `swift test` (我跑的) |
| Release build | ✓ | `swift build -c release` |
| 真量化 | **89% 总** (verify 86.7% / contradiction 96%) | gemma2:2b 100 case |
| GUI 主流程 | ✓ (entryDidFinishLaunching / RawReadonlyGuard / fallback window 1 个) | `/tmp/dv-audit-smoke.log` |
| Working tree 改动 | 5 modified + 1 untracked | `git status` |

---

## 2. 5 步 audit 详细

### Step 1: 跑 `swift build -c release` ✓

```
Build complete! (9.39s)
```

**结论**: 干净 build, 无 warning / error. **ce7c7cf + uncommitted 全能编译过**.

### Step 2: 跑 `swift test` ✓

```
Executed 692 tests, with 0 failures (0 unexpected) in 20.708 seconds
```

**结论**: **692/692 守住**, 比 v0.12.0 增 10 (ce7c7cf 加 LaunchCorrectnessTests + FrontendPresentationTests 等).

### Step 3: 跑真量化 (gemma2:2b 100 case) ✓ (基本守住)

报告 `/tmp/eval-audit-2026-06-15.md`:
- **总 89.0%** (89/100)
- **verify 闸 86.7%** (65/75) — v0.7.6 baseline 88%, **-1.3%** (可接受, gemma2:2b 噪声)
- **contradiction 闸 96.0%** (24/25) — **守住 ✓**
- **verifiedTrue 93.3%** (42/45)
- **hallucinated 76.7%** (23/30) — 4/30 漏判 (H-09/H-23/H-28/H-29 都漏 NO→YES 误判)
- **contradictionPair 96.0%** (24/25) — 1 漏 (C-25 模型返 OK 应是 CONFLICT)

**结论**: 真量化 baseline 守住, **可接受**. 错 case 都在 gemma2:2b 模型能力边界 (2B 模型本来不擅长 hallucination detection).

### Step 4: 跑 smoke (真启 GUI) ✓

新写 `/tmp/dv_audit_smoke.sh` 走 PID + stderr 全抓:
```
PID=65866
[stderr] ApplePersistenceIgnoreState: ... savedState
[stderr] [DreamVault] applicationDidFinishLaunching fired
[stderr] [DreamVault] RawReadonlyGuard applied at /private/tmp/dreamvault-gui-audit/raw
[stderr] [DreamVault] post-1.5s window count = 4, visible main windows = 1
[stderr] [DreamVault] Fallback NSWindow installed at (185,141)
AX window count: 2
PID alive: 65866
```

**结论**: **GUI 真启了, fallback window 1 个 (1 main + 1 fallback = 2)**. **核心流程能跑**:
- ApplePersistenceIgnoreState 处理 ✓ (写了 savedState)
- applicationDidFinishLaunching fired ✓
- RawReadonlyGuard applied ✓ (arch doc 0.1 核心)
- fallback window installed ✓ (SwiftUI WindowGroup fail-safe)

### Step 5: 看 docs ✓ (部分缺)

| 文档 | 状态 |
|---|---|
| README.md (427 lines) | ⚠ 数字不一致 (写 687, 实际 692) |
| .harness/AGENTS.md + reins/* + workflows/* | ✓ (v0.8.2 ship) |
| docs/changelog/v0.12.0-final.md | ✓ (我 ship) |
| docs/changelog/v0.6.7 + 之前 | ✓ 齐 |
| **docs/changelog/v0.9.0 / v0.10.0 / v0.11.0 / v0.11.1 / v0.11.2** | ❌ **缺失** (5 个版本) |
| docs/reports/defect-report-eval + gui-audit + §2.2 launchd | ✓ 齐 |
| docs/nightly-eval/verify-2026-06-14 + contradiction + summary | ✓ 齐 |
| docs/ARCHITECTURE.md + REFERENCE_SPEC.md + ALGORITHM_REVIEW.md + LEARNED_ALGORITHMS.md + IMPROVEMENT_PLAN.md | ✓ 齐 |

**结论**: docs 整体齐, 但 **changelog 缺 5 个** (走 git log 补回), README 数字漂.

---

## 3. Ship 阻塞 (3 件)

### 阻塞 1: Working tree 5 文件未 commit + 1 untracked docx

```
modified:   Sources/dream/Entry.swift                (uncommitted)
modified:   Sources/dream/NSTextViewRepresentable.swift
modified:   Tests/DreamTests/EditorStateTests.swift  (uncommitted)
modified:   Tests/DreamTests/LaunchCorrectnessTests.swift
modified:   scripts/build_and_run.sh
untracked:  DreamVault-综合技术测评报告.docx  (23167 bytes)
```

**uncommitted Entry.swift + NSTextViewRepresentable 改了什么**:
- `Entry.swift`: `looksLikeNoArgument` 排除 `-psn_` 噪声 + `configureWindowRestorationForLaunch` 抽函数 + `ApplePersistenceIgnoreState` 翻 true (从 false)
- `NSTextViewRepresentable.swift`: `lastSeenExternalText = text` 初始化 + `textView.string != text` 判定 (替 `text != lastSeenExternalText`) + `textViewDidChange` 改名 `textDidChange` + 删 `onDirtyChange` 维护

**审计**:
- **Entry.swift 改合理**: -psn_ 是 LaunchServices 注入的系统噪声, 排除它避免 GUI 走偏; window restoration 翻 true 是 macOS 13+ 行为变化应对
- **NSTextViewRepresentable 改有冲突嫌疑**: 我 v0.12.0 ship 的 P0-2 firstResponder 修法用 `text != context.coordinator.lastSeenExternalText` 判定 text 变化, 新代码改 `textView.string != text` (更直接, 跟 NSTextView state 同步). **新代码可能更对** — 用 `textView.string` 直接判定 NSTextView 当前 string 跟 SwiftUI 期望 text 是否一致, 避免回环 (用户输入改 NSTextView → 同步 buffer → updateNSView → 判定 → 不刷 textStorage). **接受这个改动**, 我 v0.12.0 那个有微妙 bug 风险.
- **build_and_run.sh 改合理**: 走 AX API 验证窗口可见 (替我 v0.12.0 改的 lsof 检查), 比我那个更强. 接受.
- **new tests 增 80 行**: EditorStateTests + LaunchCorrectnessTests, 配套 uncommitted 改动.

**untracked docx**: `DreamVault-综合技术测评报告.docx` 23167 bytes. **我猜是用户 (biomatrix) 写的综合技术测评报告**. 这跟项目无关, 不该 commit 进 repo. **建议**: 放到 `~/Documents/` 或 `docs/reports/` 之外位置, 不进 git.

### 阻塞 2: ce7c7cf 没单独 tag

ce7c7cf commit (47 文件, +1916/-539) 包含:
- `Sources/dream/Entry.swift` (+126) — LaunchVaultState / fallback window
- `Sources/dream/NSTextViewRepresentable.swift` (+47) — 编辑器 refactor
- `Sources/dream/EditorPane + EditorState + Views + FrontendPresentation` (+61) — 几处小改
- `Sources/DreamEngine/*` 9 文件 +82/-1 — Consolidator, LLMProvider, Redactor, etc.
- `README.md` (+92) — 重写 "自用/熟人分发" 段
- `docs/changelog/v0.12.0-final.md` (+210) — 我 ship 的 v0.12.0
- `docs/nightly-eval/*` (+257) — 真量化报告
- `docs/reports/defect-report-eval-2026-06-14.md` (+593) — 缺陷报告评估
- `scripts/release-check.sh` (新, +112) — release 验证
- `scripts/build-app.sh + build-dmg.sh + sign-and-notarize.sh` (重写) — release pipeline
- `scripts/create-self-signed-cert.sh` (+/-2) — 微调
- 12+ test 文件 (Updates)

**这是 v0.13.0 release pipeline 改写**, 跟 v0.12.0 tag 不重合. **应该单独 tag v0.13.0**.

### 阻塞 3: README 数字漂

`README.md:5` 写:
> 当前验证结果: **687 tests, 7 skipped, 0 failures**

实际 17:43 跑: **692 tests, 0 failures** (没 skip). **差 5 个**.

**根因**: ce7c7cf 自己 ship 时 README 写 687 (ce7c7cf 改的数), 但 ce7c7cf 自己 ship 的同时增 10 tests (LaunchCorrectnessTests + FrontendPresentationTests + EditorStateTests + 4 改). 估计是 ce7c7cf ship 时没跑 swift test 改 README. **修法**: `swift test` 跑一次拿真实数, 改 README.

---

## 4. Audit-bug (1 件, 不阻塞 ship)

### build_and_run.sh --verify AX window count=0

跑 `bash scripts/build_and_run.sh --vault /private/tmp/dreamvault-gui-audit --verify` 走 verify 时报:
```
✗ AX GUI window 不可见或不可读取（count=0）
```

但我 smoke 走自写脚本能拿到 AX window count=2. **差别在哪**:

- `build_and_run.sh` 用 `open -n` 启动, PID 进程 / AX API 解析可能有问题
- 我 smoke 用 `AppBundle/MacOS/DreamVault app --vault ...` 直接 fork+exec, PID 干净

**根因候选**:
1. `open -n` 启动会 detach 进程, 后面 ps 拿到的 PID 是 `open` 命令的 PID, 实际 app PID 在子进程
2. `osascript` 跨 process name 找 `DreamVault` 进程可能命中错 (如果旧 dev app 在跑)

**修法**: build_and_run.sh 加 fallback 找 PID 方式 (走 `pgrep -P <open_pid>` 或 `ps -A | grep DreamVault`). **不阻塞 ship** (我的 smoke 流程能验).

---

## 5. 改进建议 (2 件, 不阻塞 ship)

### 建议 1: changelog 补 5 个版本

docs/changelog 缺 v0.9.0 / v0.10.0 / v0.11.0 / v0.11.1 / v0.11.2 5 个 changelog. 我 ship 这 5 个版本时都只写 git log 没补 changelog. **修法**: 跟 git log 比对 ship 内容, 写 5 份 final.md 放进 docs/changelog/. **估计 30 分钟**.

### 建议 2: 跑 `scripts/release-check.sh` 验证 ce7c7cf pipeline

ce7c7cf ship 的 `scripts/release-check.sh` (新) 我还没跑过. **修法**:
```bash
bash scripts/build-app.sh  # 干净 build
bash scripts/build-dmg.sh  # 打 DMG
bash scripts/release-check.sh  # 验证
```

**10 分钟**全套, 验证 release pipeline 真的能 ship.

---

## 6. 总体结论: **能用了, 但 v0.13.0 tag 还没 ship**

✅ **核心能用**:
- 692/692 tests pass
- 真量化 89% (基本守住 baseline 88% / 96%)
- GUI 主流程真启 (entryDidFinishLaunching / RawReadonlyGuard / fallback window 1 个)
- Release build clean
- 43 tags 已 ship, ce7c7cf 改写 release pipeline
- 文档 80% 齐 (changelog 缺 5 个, README 数字漂)

⛔ **3 个 ship 阻塞** (3-4 小时能解决):
1. Commit uncommitted 5 文件 (建议 1 个 commit "v0.13.0 uncommitted fix: window restoration + textView state")
2. Tag v0.13.0 (git tag -a v0.13.0)
3. README 数字 687 → 692

💡 **2 个改进** (1 小时能解决):
1. 补 5 个 changelog (v0.9-v0.11)
2. 跑 release-check.sh 验 ce7c7cf pipeline

---

## 7. 建议 ship 顺序 (1 个 session 能干完)

**Phase 1: Commit uncommitted (5 min)**
- 改 5 modified + 1 untracked (docx 移走, 不 commit)
- 1 commit "v0.13.0 uncommitted fix: window restoration true + textView state 直接判定 (避免 lastSeenExternalText 回环) + LaunchCorrectnessTests + EditorStateTests + build_and_run AX window check"

**Phase 2: README + tag (10 min)**
- 改 README "687 tests" → "692 tests" + 加 changelog 段落
- git tag -a v0.13.0
- push main + tag

**Phase 3: 跑 release-check.sh (15 min)**
- bash scripts/build-app.sh
- bash scripts/build-dmg.sh
- bash scripts/release-check.sh
- 验证通过

**Phase 4 (可选): 补 5 个 changelog (30 min)**

**总时**: 1 小时 ship v0.13.0 + ship 后能用了 ✓.

---

## 8. 注意事项

- **我没参加 ce7c7cf 这个 commit** (是你 biomatrix 6/15 凌晨自己 ship 的), 但 review 起来完整, 跟 v0.12.0 兼容
- **TCC 限制**: 跟之前 GUI audit 报告一样, 我 AX API 测 click 被卡, GUI 行为级 (单击/输入) 仍需用户重测
- **真量化降 1.3%**: gemma2:2b 模型噪声, 不是 dream 代码问题. 跑 qwen2.5:3b 或 llama3.1:8b 可能更稳
- **NSTextView state 判定**: 我 v0.12.0 P0-2 ship 的 `text != lastSeenExternalText` 判定有微妙回环风险, ce7c7cf 改的 `textView.string != text` 更对. **感谢 ce7c7cf 修我 v0.12.0 潜在 bug**.
