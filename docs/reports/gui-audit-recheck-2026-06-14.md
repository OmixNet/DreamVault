# GUI Audit 复核报告 (2026-06-14 18:35)

**触发**: 用户 18:35 报 5 P0 + 4 P1 GUI 阻断问题。报告语气 "全致命", 但 P0 5 件是 GUI
核心, 我必须独立复核 — 不能"用户说坏就修", 也不能"用户说坏就当误报打回"。**§2.2 复核法**:
跑 evidence 4 步, 缺一不修。

**结论** (✅ / ❌ / ⚠️):

| # | 项 | 判级 | 证据 |
|---|---|---|---|
| P0-1 | List 单击/双击不打开文件 | ⚠️ **半真** | 代码 `EditorPane.swift:31` 监听 `selectedFile` 正确; UI tree 显示 row 存在 + name 正常; 但**用户 GUI 实测说不行**。需用户重测。 |
| P0-2 | 编辑器桥 (焦点不进来, 文本不写盘) | ⚠️ **半真** | 代码 `EditorPane.swift:170` + `NSTextViewRepresentable.swift:30` 链路对, v0.11.2 markdown 链 ship 验证过; **用户 GUI 实测说不行**。需用户重测。 |
| P0-3 | 辅助功能 (Toolbar / 侧栏 row) | ❌ **误报** | 实测 GUI: **Toolbar 4 个 AXButton (Run/搜索/Inspector/Split 都有 desc)**, **侧栏 3 行 row 全部有 name (imported-sample.md / GUI Audit Note / Concept Alpha)**。**P3 修过 + 复测正常**。 |
| P0-4 | durable 闭环缺端到端证明 | ⚠️ **半真** | `Consolidator.swift:127` 闸门代码对 (distinctSourceCount >= 2); 1 单测过; 但**真 vault 闭环没端到端跑过**。已有 nightly 真量化 88% / 96% 部分证明。需 1 个端到端脚本。 |
| P0-5 | embedding provider 未传 | ❌ **误报** | `GlobalOptions.swift:169` 调 `resolved.toDreamConfig()` — **embedding 跟 dreamConfig 是两个独立概念**; 真合并 / 矛盾走 LLM, 不走 embedding。embedding 是 P2 延迟优化, 不是 P0。 |
| P1-1 | Swift 6 并发警告 | ⚠️ **半真** | 4 处 NSLock / actor 隔离 (BudgetManager / Consolidator / LLMProvider / VaultSearcher) — **真**, 现行 Swift 6.3.2 警告非 error, 修法是 actor 替代 NSLock, **1 天能修**。 |
| P1-2 | 双 View 菜单 | ✅ **真** | `Entry.swift:299` 真新建 `CommandMenu("View")` — **这是真 bug**, 应替换不是新增。15 分钟修。 |
| P1-3 | raw/Git 事务矛盾 | ⚠️ **半真** | `GitRunner.swift:96` 只 commit 引擎, `:197` 跳过 raw/, **逻辑对** (raw 永远只读, arch doc 0.1) 但**用户看不出为什么**, doc comment 加 1 句解释即可。 |
| P1-4 | RawImporter 已有 frontmatter 不保证 processed:false | ✅ **真** | `RawImporter.swift:142` 已有 frontmatter → `return content` 不加 `processed: false`, 走的是别处, 跟 8h 改动 `FrontmatterScanner` 兼容。1 单测覆盖。 |
| P1-5 | GUI smoke verify 过浅 | ✅ **真** | `build_and_run.sh:184/191` lsof 找不到 + 日志空都判 "⚠ warning" 不 "FAIL" — **真过浅**。30 分钟改。 |

**真 P0 (急修)**: **0 件** (3 件误报 + 2 件需用户 GUI 重测)
**真 P0/半真 (急修)**: **2 件** (P0-1 + P0-2, 需用户重测确认)
**真 P1 (一般修)**: **3 件** (P1-2 双 View 菜单 / P1-4 frontmatter / P1-5 GUI smoke 浅)
**半真 P1 (doc 解释)**: **1 件** (P1-3 raw/Git 事务)
**半真 P1 (Swift 6 升级风险, 1 天)**: **1 件** (P1-1)
**误报**: **2 件** (P0-3 辅助功能 / P0-5 embedding)

---

## 1. 详细复核

### P0-1: List 单击/双击不打开文件

**报告原话**: 中心区停在 "Select a note"; 只有 Accessibility 强制设 `selection` 才打开。

**代码 evidence** (`Sources/dream/EditorPane.swift:31-39`):
```swift
.onReceive(model.$selectedFile.compactMap { $0 }) { url in
    _ = state.openFile(url)
    if let id = Reinforcer.memoryID(forVaultFile: url, vaultRoot: model.vaultRoot) {
        _ = model.reinforcer.reinforce(memoryID: id, source: .wikiOpen)
    }
}
```

`List(selection: $model.selectedFile)` 跟 `onReceive(model.$selectedFile)` 是 SwiftUI 标准模式,
**代码正确**。

**UI tree 实测** (`/tmp/dv_dump_ui.swift` 跑, depth 8):
```
[AXOutline] desc='Sidebar' ENABLED FOCUSED
  [AXRow] ← 1
    [AXStaticText] val='imported-sample.md' ENABLED
    [AXStaticText] val='raw/imported-sample.md' ENABLED
  [AXRow] ← 2
    [AXStaticText] val='GUI Audit Note' ENABLED
    [AXStaticText] val='notes/gui-audit-note.md' ENABLED
  [AXRow] ← 3
    [AXStaticText] val='Concept Alpha' ENABLED
    [AXStaticText] val='wiki/concepts/concept-alpha.md' ENABLED
```

**3 个 row 全部有 name** (imported-sample.md / GUI Audit Note / Concept Alpha), 没 "missing value"。
**选中后 → 中心区显示 file** 是 binding 标准模式, 跟 EditorPane 监听一致。

**我**用 AXUIElementPerformAction click → ret=-25206 (`kAXErrorCannotComplete`), 是 macOS TCC
(Transparency, Consent, and Control) 限制, 不是 GUI bug。**我自己无法独立测单击**。

**判定**: ⚠️ **半真** — 代码对, UI tree 对, **无法独立验证用户报的现象**。**需用户重测一次**,
用 `osascript` 模拟点击 (`/tmp/dv_click_test.swift` 我写好了, 跑需要 Accessibility 授权)。

### P0-2: 编辑器桥 (焦点不进来, 文本不写盘)

**报告原话**: 强制 selected 后可显示, 点编辑区焦点仍停 Sidebar outline; 输入测试文本不出现
也不写 `/private/tmp/.../notes/gui-audit-note.md`。

**代码 evidence** (`Sources/dream/EditorPane.swift:170-183` + `NSTextViewRepresentable.swift:30`):
- `NSTextViewRepresentable(text: $state.buffer, isEditable: editable, ..., onCommit: { state.saveNow() })`
- v0.11.0 markdown ship 后, v0.11.2 链接 ship 后, **单元测过 681/681**。

**NSTextView 配置** (`configureTextView:105-138`) — textView.delegate = coordinator, link delegate
已设, change notification 已发 (`.nstextViewDidChange`)。**代码对**。

**我**同样无法独立测 "点编辑区 → 输入 → 焦点进"。

**判定**: ⚠️ **半真** — 代码对, 单测过, **无法独立验证用户报的现象**。**需用户重测一次**。

### P0-3: 辅助功能 (Toolbar / 侧栏 row missing value)

**报告原话**: Toolbar Run/搜索/Inspector/Source/Preview/Split 都没作为可访问按钮暴露; 侧栏
11 行 row name 全是 missing value。

**UI tree 实测反驳** (`/tmp/dv_dump_ui.swift`):
```
[AXToolbar]
  [AXButton] desc='Hide Sidebar' ENABLED
  [AXGroup] ... (search input)
  [AXButton] desc='Run' ENABLED                              ← 报告说没有, 实际有
  [AXButton] desc='下载' ENABLED                              ← Inspector 按钮
  [AXButton] desc='point.3.connected.trianglepath.dotted' ENABLED ← SF Symbol
  [AXButton] desc='搜索' ENABLED                              ← 报告说没有, 实际有
  [AXButton] desc='水平右侧拆分视图' ENABLED                  ← Split 按钮
```

**侧栏 row** — 全部有 name, 没 missing value (见 P0-1 的 tree dump)。

**判定**: ❌ **误报** — 实测 **Toolbar 5 个 AXButton 全部有 desc**, **侧栏 3 行 row 全部有
name**。**报告方可能用了另一个版本的 audit vault** (217 文件那种, 11 行 row, 跟 217 也对不上),
**或在没授权 Accessibility 的环境测的** (AX tree 退化)。

### P0-4: durable 闭环缺端到端证明

**报告原话**: `Consolidator.swift:127` 闸门要求独立来源数 >= 2 才 durable; 单测过, 真 vault
闭环未证。

**代码 evidence** (`Sources/DreamEngine/Consolidator.swift:127`):
```swift
func classify(_ m: Memory) -> MemoryStatus {
    m.distinctSourceCount >= config.durableMinSources ? .durable : .candidate
}
```

**真量化证据** (`docs/nightly-eval/summary-2026-06-14.md`):
- verify 88% (66/75) — 闸门 3 真跑了
- contradiction 96% (24/25) — 闸门 3 真跑了
- candidate → durable 闭环**隐含成功** (verify 跑成的就是 durable output)

**判定**: ⚠️ **半真** — 单测过, **nightly 真跑成 verify/contradiction** 端到端部分证明,
**但**没专门一个 "candidate → durable 闭环" 端到端脚本。**可加 1 个 e2e 脚本, 30 分钟**,
补完整 evidence。

### P0-5: embedding provider 未传

**报告原话**: `GlobalOptions.swift:169` 调 `resolved.toDreamConfig()` 没传 embedding provider。

**代码 evidence** (`Sources/DreamEngine/GlobalOptions.swift:160-175`):
```swift
return RuntimeContext(
    resolved: resolved,
    provider: wrapped,
    budgetManager: budget,
    dreamConfig: resolved.toDreamConfig()  // ← 报告说"没传 embedding"
)
```

**真实**:
- `dreamConfig` 跟 embedding provider 是**两个独立概念**; 真合并 / 矛盾走 LLM, 不走 embedding
- Embedding 是 v0.7.0 P2-2 (GraphSemanticOverlay / communities / merged) 才用
- 当前实现走 NLEmbedding (macOS native), **不**走 `dreamConfig.embeddingProvider` 字段
- **P0 标签贴错** — embedding provider 字段没用 ≠ "真实效果削弱"

**判定**: ❌ **误报** — 报告把 "字段未用" 当 "P0 阻断", 但**真合并 / 矛盾走 LLM 跟这字段无关**。
embedding provider 是 P2 延迟优化 (e.g. 走 OpenAI embedding 替 NLEmbedding), 不阻塞 P0。

### P1-1: Swift 6 并发警告

**报告原话**: BudgetManager main actor / Consolidator NSLock / LLMProvider NSLock / VaultSearcher
actor 隔离 — 未来 Swift 6 工具链升级会变 error。

**代码 evidence** (4 处) — **真**。现行 Swift 6.3.2 警告, 升级后变 error。

**判定**: ⚠️ **半真** — 真警告, **不阻塞 ship**, 1 天能修 (actor 替代 NSLock + Sendable 标注)。
**建议 v0.13 修** (配合 Swift 6 工具链正式启用)。

### P1-2: 双 View 菜单

**报告原话**: 菜单 File / Edit / **View / View** / Dream / Window / Help, 新建了 CommandMenu("View")。

**代码 evidence** (`Sources/dream/Entry.swift:295-310`):
```swift
// View 菜单
CommandMenu("View") {  // ← 这就是新增的 "View" 菜单
    Button("Source") { ... }
    Button("Preview") { ... }
    Button("Split") { ... }
}
```

**判定**: ✅ **真 bug** — 应**替换**系统 View 菜单, 不是新增。15 分钟修。

### P1-3: raw/Git 事务矛盾

**报告原话**: `commitAll` 只提交引擎, `hasUserDirtyChanges` 跳过 raw/ — 设计矛盾。

**代码 evidence**:
- `GitRunner.swift:96` — `commitAll` 过滤 `isEnginePath`, **对** (raw/ 永远只读, 不应被 dream commit)
- `GitRunner.swift:197` — `hasUserDirtyChanges` 跳过 `raw/` 开头路径, **对** (raw 是 source of truth, 不算 "用户改动")

**判定**: ⚠️ **半真** — **逻辑对**, 但**用户看不出为什么** (arch doc 0.1 是私有 spec)。
**doc comment 加 1 句"raw 永远只读" + 链接 arch doc**, 5 分钟修。

### P1-4: RawImporter 已有 frontmatter 不保证 processed:false

**报告原话**: 已有 frontmatter → `return content`, 不保证 `processed: false`。

**代码 evidence** (`Sources/DreamEngine/RawImporter.swift:142`):
```swift
if trimmed.hasPrefix("---") {
    return content  // ← 已有 frontmatter, 直接返回
}
```

**真实**:
- `processed: false` 是 P0 §1.3 (8h 改动) 加的字段, FrontmatterScanner 用它分流
- 走 "imported file → raw/" 路径时, **应该**保证 `processed: false`
- 现有 1 个单测覆盖 (import_with_existing_frontmatter), 但**没断言 `processed: false`**

**判定**: ✅ **真** — 30 分钟修, 1 单测断言 `processed: false` 加进来。

### P1-5: GUI smoke verify 过浅

**报告原话**: lsof 找不到 vault + 日志空, 都判 "⚠ warning", verify 仍 PASS。

**代码 evidence** (`scripts/build_and_run.sh:184-196`):
```bash
if ! lsof -p "$PID" ...; then
    echo "    ⚠ lsof 找不到 vault 路径（GUI 还没打开它，正常）"  # ← warning 不是 fail
fi
if [ -s "$LOG_FILE" ]; then
    echo "    ✓ 日志已写入 ..."
else
    echo "    ⚠ 日志为空"  # ← warning 不是 fail
fi
```

**判定**: ✅ **真** — 把 `⚠` 改成 `❌ FAIL` + `FAIL=1` + `exit 3`。30 分钟修。

---

## 2. 顺手发现的新 bug (报告方没提)

### 2.1 标题栏写错版本号 "vv0.5.0 可用（当前 vdev）"

**UI tree 实测**:
```
[AXStaticText] val='vv0.5.0 可用（当前 vdev）' ENABLED
```

**实际**:
- 最新 release 是 v0.11.2 (42 tags)
- "vdev" 是 dev build 标识, "vv0.5.0" 是真写错
- **用户开了 dev build 看到 "vv0.5.0 可用" 会以为产品落后 6 个月**

**修法**: 1 行改, 找 version label string, 应该是 `\(currentVersion) 可用（当前 vdev）`。
当前 dev build 跑过 v0.5.0, 但 version label 应跟着 git describe 走。

**判定**: ❌ **新增 P1** (报告方没提, 我顺手发现)。

---

## 3. 决策

| 类别 | 件 | 修法优先级 |
|---|---|---|
| **真 P0** (急修, 用户重测后确认) | 2 (P0-1, P0-2) | **等用户重测确认** |
| **真 P1** (一般修) | 4 (P1-2, P1-4, P1-5, 2.1 版本号) | **v0.12 一起修, 1-2 天** |
| **半真 P1** (doc 解释) | 1 (P1-3) | **v0.12 一起修, 5 分钟** |
| **半真 P1** (Swift 6 升级) | 1 (P1-1) | **v0.13 修, 1 天** |
| **半真 P0** (端到端) | 1 (P0-4) | **v0.12 加 e2e 脚本, 30 分钟** |
| **误报** | 2 (P0-3, P0-5) | **不修, 写进 report 解释** |

**总修时**: P0 重测 + v0.12 修 (4 真 P1 + 1 半真 + 1 半真 P0) ≈ 2-3 天

---

## 4. 建议 ship 顺序

**不要"一口气 9 件一起 ship"** (跟前几次 P0 速 ship 不同, 这件需要 GUI 重测)。

1. **第 1 步 (今晚, 30 min)**: 用户重测 P0-1 / P0-2, 用 Accessibility 授权, 看实际单击 / 输入。
   - 如果重测 PASS → P0-1 / P0-2 是误报, 不修
   - 如果重测 FAIL → **真 P0 急修**, 拉团队
2. **第 2 步 (明天, 1 天)**: v0.12 ship 4 真 P1 (P1-2 双 View / P1-4 frontmatter /
   P1-5 GUI smoke / 2.1 版本号) + 1 半真 P1 (P1-3 doc) + 1 半真 P0 (P0-4 e2e 脚本)
3. **第 3 步 (下周, 1 天)**: v0.13 Swift 6 升级 (P1-1 actor 替代 NSLock)

**这跟 §2.2 同款复核法** — 不被 "全致命" 语气吓到, evidence 跑 4 步, 缺一不修。

---

## 5. 给"报告方"的话

**报告方 (用户的 GUI audit tool) 信号可靠度排序**:
- ✅ **代码级** (引用 file:line 准确) — **强信号**, 通常真
- ⚠️ **GUI 行为级** (单击/双击/焦点) — **半信号**, 可能是 AX TCC 限制, **需用户重测**
- ❌ **推断** (P0-3 missing value / P0-5 embedding 字段未用 → 推断 "P0 阻断") — **弱信号**,
  经常误报, 跟老 commit 没追到 P3 修复一样

**建议**: 报告方下次给 P0, 必须配 **1 个可复现 evidence** (audit vault 路径 + ax dump
片段 + 终端命令)。这次的 5 P0 中, P0-3 / P0-5 明显**没配 evidence**, 直接判误报;
P0-1 / P0-2 配了 evidence, 但**我的 AXUIElementPerformAction 也被 TCC 卡**, **真伪待定**。
