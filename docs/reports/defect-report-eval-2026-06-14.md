# DreamVault 缺陷报告深度评估 + 修复计划

> 评估时间: 2026-06-14
> 报告来源: 8h 评审 #2 (产品视角 + 系统稳定性视角)
> 评估方式: 逐条 grep + read 源码验证, 不只承认也不只反驳, 区分**真**/**半真**/**误报** 3 类
> 目的: 给出修复优先级 + 修法, 等用户 review 后再动手改

---

## 总览

| § | 主题 | 报告 | 评估 | 优先级 |
|---|---|---|---|---|
| 1.1 | O(N²) topRelated | 致命 | ✅ **真** | **P0** |
| 1.2 | `git add -A` 撑爆磁盘 | 致命 | ❌ **误报** (P3-T3 修过) | - |
| 1.3 | `String(contentsOf:)` UI 卡顿 | 严重 | ✅ **真** | **P0** |
| 1.4 | 无 RetryPolicy | 严重 | ❌ **误报** (3 attempts + 指数退避 + jitter) | - |
| 2.1 | 矛盾 UI 死胡同 | 严重 | ⚠️ **半真** (View 存在, UI 未 hook) | **P1** |
| 2.2 | 强迫用户当程序员 | 严重 | ⚠️ **半真** (Settings 已加, dirty workspace 抛错未改) | **P0** |
| 2.2 | 缺 Settings panel | 严重 | ❌ **误报** (P0-7 + 8h 改动已加) | - |
| 2.2 | launchd / SMAppService | 严重 | ⚠️ **半真** (Settings toggle, SMAppService 未用) | **P2** |
| 2.3 | `consolidate3Step` 闲置 | 欺诈 | ❌ **误报** (`consolidateSmart` 调度, 3 步默认) | - |
| 3.1 | rollback 删库 | 暴雷 | ❌ **误报** (只删当次 report stamp, 不删目录) | - |
| 3.2 | IP_ADDR 误伤版本号 | 数据丢失 | ⚠️ **半真** (5 段防住, 4 段版本号承认限制) | **P2** |
| 3.3 | 编辑器体验差 | 不合格 | ⚠️ **半真** (NSTextView 有, 行号/高亮/链接缺) | **P1** |

**4 真 + 4 半真 + 4 误报 = 12 项**

**真问题 4 项全部 P0/P1 级**, 误报 4 项是看老 commit 没追到 P3 修复, **不要被报告的"全部致命"语气带偏**.

---

## 1. 灾难级的性能与架构瓶颈

### 1.1 荒谬的 O(N²) 图谱计算 ✅ 真

**报告原话**: Persister.swift line 78-85, `graph.topRelated` 遍历 + Adamic-Adar 嵌套循环, N=10000 时 O(N²) = 1 亿次迭代, CPU 100% 卡死.

**验证** (`Sources/DreamEngine/Persister.swift:99`):
```swift
for m in active {                              // 外层 N
    let related = graph.topRelated(to: m.id, limit: 5)
    ...
}
```
`graph.topRelated` (KnowledgeGraph.swift:71) 内部又对**所有其他节点**算 Adamic-Adar → 内层 N. **确证 O(N²)**.

**影响**:
- N=1000: 1M ops, <1s, 接受
- N=10000: 100M ops, ~30s, 卡顿
- N=100000: 10B ops, **数小时**, 不可用

**根因**:
- topRelated 每次重算全图 Adamic-Adar
- Persister 每晚重新建图 (`KnowledgeGraph(memories: active)`) + 重新算所有分数
- 无增量更新机制

**修法** (3 选 1):

**(a) 增量缓存** (推荐, 改 Persister):
```swift
public actor RelatedCache {
    private var scores: [String: [(id: String, score: Double)]] = [:]
    private var lastBuild: Date = .distantPast

    func rebuildIfStale(ledger: [Memory], ttl: TimeInterval = 86400) {
        if Date().timeIntervalSince(lastBuild) < ttl { return }
        // 重算全部, 持久化到 disk
    }
}
```
- 优点: 改动小, 一次 rebuild 后 24h 内 O(N) 查表
- 缺点: 24h 重建时仍 O(N²), 但 1 天 1 次可接受

**(b) 跳数限制** (KnowledgeGraph):
```swift
public func topRelated(to id: String, limit: Int = 5, maxHops: Int = 2) -> [...] {
    // BFS 2 跳, 跳过距离 > maxHops 的节点
    // O(N) 平均 (跳数限制剪枝)
}
```
- 优点: 真 O(N) 平均
- 缺点: 牺牲远距离关联

**(c) 异步 + 分批** (Persister 调度):
```swift
// Persister.persist 走 TaskGroup, 分 1000 节点一批, 跨 N 晚分摊
```
- 优点: 兼容老代码
- 缺点: 不解决根本问题, 仍 O(N²) 总计算

**推荐 (a) + (b) 组合**: topRelated 加 maxHops 剪枝 + RelatedCache 24h 缓存.

**测试**: 加 10000 节点 fixture, 验证 `topRelated + cache` < 5s, 老代码 > 30s.

**修时**: 0.5-1 天
**风险**: 中 (改持久化路径, 必须保证 0 退化 + 报告输出同格式)

---

### 1.2 野蛮的 Git 操作 ❌ 误报

**报告原话**: GitRunner.swift line 90 `try run(["add", "-A"])`, raw/ 大文件被 hash 进 .git/objects.

**验证** (`Sources/DreamEngine/GitRunner.swift:96-117`):
```swift
public func commitAll(message: String) throws -> Bool {
    let statusOut = (try? run(["status", "--porcelain"])) ?? ""
    let allDirty = Self.parseStatusPaths(statusOut)
    let enginePaths = allDirty.filter { Self.isEnginePath($0) }   // 白名单
    guard !enginePaths.isEmpty else { return false }
    try run(["add", "--"] + enginePaths)                          // 显式路径
    ...
}
```

**白名单** (line 79-84):
```swift
static let enginePaths = [
    "MEMORY.md", ".dream/", "wiki/", "archive/",
]
// **不含 raw/**
```

**结论**: P3-T3 已修 (`commitAll` 不再用 `add -A`, 走白名单 + `add --` 显式路径, `add` 行前有 `--` 阻隔 args 注入).

**报告不准确** (应该是看老 commit, 没追到 P3-T3). 误报.

**仍可改进**:
- 当前实现: 白名单**不含 raw/**, 但如果用户把 raw/ 设成 git tracked, 误判会跟.
- 加 `git check-ignore raw/` 校验 + `isEnginePath` 加 explicit "not in raw/" 反向规则.

**不修** (低优先级, P3-T3 已经正确处理).

---

### 1.3 主线程的暴力 I/O ✅ 真

**报告原话**: Views.swift / Entry.swift 用 `String(contentsOf: f)` 全文读 + `.contains("processed: false")`, 5MB 笔记假死.

**验证** (`Sources/dream/CLI.swift:160-161`):
```swift
guard let content = try? String(contentsOf: f, encoding: .utf8) else { return false }
return content.contains("processed: false")
```
**确证**, 每文件全文读, 5MB 文件 1 次 50-200ms, 1000 文件累计 1-3 分钟, 单线程卡顿明显.

**Entry.swift:931-932 注释**:
> P3-T5 fix: 用 Gatherer.parseFrontmatter 替代 .contains("processed: false") 全文扫描
> 老逻辑: 读全文 + .contains("processed: false"), 对每个 .md 都读几十 KB 到 MB.

**部分修过** (Entry.swift 主路径走 FrontmatterParser), 但 **CLI.swift:160-161 还在用全文** + **其他 Views / GitStatusBanner / SearchSheet 仍用 `String(contentsOf:)`** (line 203, 243, 547).

**修法** (3 步):

**step 1**: 抽 `FrontmatterScanner.scanFile(URL) -> (hasProcessedFalse: Bool, error: Error?)`:
```swift
public enum FrontmatterScanner {
    /// 流式按行扫 frontmatter, 找到 'processed: false' 立即返 (不读 body).
    /// O(几十行) per file, 跟文件大小无关.
    public static func hasProcessedFalse(_ url: URL) -> Bool {
        guard let stream = InputStream(url: url) else { return false }
        stream.open()
        defer { stream.close() }
        let buf = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()
        var inFrontmatter = false
        var sawClosing = false
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: buf.count)
            if n <= 0 { break }
            accumulated.append(buf, count: n)
            // 找 "---\n" 开始
            if !inFrontmatter, accumulated.starts(with: Data("---\n".utf8)) {
                inFrontmatter = true
            }
            // 找 "---" 闭合
            if inFrontmatter {
                if let range = accumulated.range(of: Data("---".utf8), in: 1..<accumulated.count) {
                    // 看 frontmatter 块里有没有 processed: false
                    let frontmatter = accumulated.subdata(in: 0..<range.upperBound)
                    let str = String(data: frontmatter, encoding: .utf8) ?? ""
                    if str.contains("processed: false") { return true }
                    sawClosing = true
                    break
                }
            }
            // 防无限增长 (OOB)
            if accumulated.count > 64 * 1024 { break }  // frontmatter 不会超 64KB
        }
        return false
    }
}
```

**step 2**: CLI.swift:160-161 / Views.swift / GitStatusBanner 等替换调用.

**step 3**: 测试:
```swift
func testFrontmatterScanner_5MBBody_doesNotLoadEntirely() {
    let big = writeBigMD(body: String(repeating: "x", count: 5_000_000), frontmatter: "processed: false")
    XCTAssertTrue(FrontmatterScanner.hasProcessedFalse(big))  // <10ms
}
```

**修时**: 0.5 天
**风险**: 低 (新增 helper, 替换调用, 老逻辑留作 fallback)

---

### 1.4 脆弱的单点故障模型 ❌ 误报

**报告原话**: Consolidator 无 RetryPolicy, 大模型超时导致一晚回滚.

**验证** (`Sources/DreamEngine/Consolidator.swift` `callLLMWithRetry`):
```swift
func callLLMWithRetry(system: String, user: String,
                      maxAttempts: Int = 3) async throws -> String {
    var lastError: Error?
    for attempt in 1...maxAttempts {
        do {
            return try await llm.complete(system: system, user: user)
        } catch {
            lastError = error
            if attempt < maxAttempts {
                let baseDelay = pow(2.0, Double(attempt - 1))  // 1s, 2s, 4s
                let jitter = Double.random(in: 0...0.5)
                try? await Task.sleep(nanoseconds: UInt64((baseDelay + jitter) * 1_000_000_000))
            }
        }
    }
    throw lastError ?? LLMRetryError.exhausted
}
```

**确证 3 attempts + 指数退避 (1s, 2s, 4s) + jitter**.

**报告不准确** (应该是看老代码, P3-3 没追到 retry 加进).

**仍可改进** (低优先级):
- 当前: `Consolidator.callLLMWithRetry` 包装, **但 `OllamaProvider.complete` 自己没有 catch retry** — 失败 3 次还是 throw.
- 改善: 把 retry 逻辑下沉到 `OllamaProvider`, 加 maxRetries 配置, 跨调用共享 (e.g. 5 分钟内 100 次失败后熔断 1 小时).

**不修** (P3-3 现状可用, 改善是优化不是修).

---

## 2. 严重的产品设计逻辑断层

### 2.1 毫无意义的半成品功能 ⚠️ 半真

**报告原话**: `withContradictsCount` 显示但不能点不能看, 死胡同.

**验证**:
- `Sources/dream/ConflictResolutionView.swift` **存在** (P0-8 修过, v0.5.0-rc8 提交)
- `Sources/dream/Views.swift:792`: `row("Needs review", value: count)` 文字, **没 sheet 弹出**
- `Sources/dream/Views.swift:819`: `if model.status.withContradictsCount > 0 { ... }` — 有 conditional, 看具体怎么用

**半真**: View 写了, UI 没 hook.

**修法** (UI 改造):
```swift
// Sources/dream/Views.swift line 819 区域
if model.status.withContradictsCount > 0 {
    Button {
        selectedConflict = firstContradict  // @State Memory?
    } label: {
        row("Needs review", value: "\(count) →")
    }
    .sheet(item: $selectedConflict) { conflict in
        ConflictResolutionView(memory: conflict, ledger: ledger, onResolve: ...)
    }
}
```

**测试**: 加 UI 集成测试 (XCUITest? 或 in-memory ViewModel test):
```swift
func testNeedsReviewClickOpensConflictSheet() {
    let model = StatusViewModel(ledger: withContradicts)
    model.openFirstConflict()
    XCTAssertNotNil(model.activeSheet)
}
```

**修时**: 1 天
**风险**: 中 (UI 改造, 跟现有 sheet pattern 对齐)

---

### 2.2 强迫用户当程序员 ⚠️ 半真

**报告原话**: dirty workspace 抛错, 强迫用户先 commit. 用户写完直接 Cmd+Q, 系统罢工.

**验证** (`Sources/DreamEngine/DreamCycle.swift:175-181`):
```swift
if !dirty.isEmpty {
    throw DreamError.userDirtyWorkspace
}
```

**确证** — 抛错, 不 commit 用户工作区改动.

**修法** (3 选 1):

**(a) 自动 commit 用户非引擎改动** (推荐):
```swift
if !dirty.isEmpty {
    // 自动 stage + commit 用户非引擎路径, 用 dream commit 但 message 标 "user auto-save"
    let userPaths = dirty.filter { !GitRunner.isEnginePath($0) }
    if !userPaths.isEmpty {
        try? runGit(["add", "--"] + userPaths)
        try? runGit(["commit", "-m", "[dream auto-save] user edits before nightly run"])
    }
}
```
- 优点: 透明, 用户无感
- 缺点: 改变"git 是事务边界"语义, 但只在 dream 启动时, 可接受

**(b) 自动 stash + 跑完 unstash**:
```swift
if !dirty.isEmpty {
    try? runGit(["stash", "push", "-u", "-m", "dream pre-run"])
    defer {
        try? runGit(["stash", "pop"])
    }
}
```
- 优点: 完全不改用户历史
- 缺点: stash conflict 风险, 需 fallback

**(c) 静默 "force include raw/"** (改 isEnginePath):
- 不推荐, raw/ 本来就是只读

**推荐 (a)**: 自动 commit 用户非引擎改动, message 标记.

**修时**: 0.5 天
**风险**: 中 (改 DreamCycle 启动流程, 必须保证跟 P3-T3 的白名单兼容)

**Settings 已有 llmChoice 跟 LLM provider Picker** (Sources/dream/SettingsView.swift:212, 8h 改动加的). **`DREAMVAULT_LLM` env var 仍然覆盖 Settings** (CLI flag > vault > settings > env > hardcoded), 报告说"GUI 程序需配 env" — **不是**, GUI 走 Settings 即可. 误报.

**launchd 仍是 user-level LaunchAgent, 没走 SMAppService**:
- Settings 有 toggle (SettingsView.swift:186-194)
- `scripts/install.sh` 首次安装仍需 bash
- 注释解释: "不是系统级 (/Library/LaunchDaemons/, 需 root + SMAppService helper binary), user-level 是正确选择"
- **半真**: Settings UI 已加, SMAppService 走系统级是 overkill

**修法** (低优先级):
- `scripts/install.sh` 改为 GUI 一键安装 (菜单 File → Install as Nightly Job)
- Settings toggle 调 SMAppService 注册系统级 daemon (需 entitlements, 复杂)

**修时**: 1-2 天 (一键安装), 2-3 天 (SMAppService)
**风险**: 高 (SMAppService 需代码签名 + entitlements)

---

### 2.3 欺诈性的最强功能 ❌ 误报

**报告原话**: `consolidate3Step` 闲置, line 99 硬编码 `consolidate()`.

**验证** (`Sources/DreamEngine/DreamCycle.swift:226`):
```swift
let result = try await consolidator.consolidateSmart(gathered.candidates)
```

`Consolidator.consolidateSmart` 内部走 `config.useThreeStepCoT` 分支:
- `true` (P3-3 默认) → `consolidate3Step` (3 段)
- `false` → `consolidate` (2 步)

**P3-3 §1.2 修复** 已 ship, 3 步默认开.

**报告不准确**. 误报.

---

## 3. 低级的数据安全风险与 Bug

### 3.1 暴力的回滚逻辑会引发删库 ❌ 误报

**报告原话**: `for path in [".dream/reports", ...] try? fm.removeItem(at: url)` 删整目录.

**验证** (`Sources/DreamEngine/DreamCycle.swift:389-399`):
```swift
private func rollbackDreamArtifacts(vaultRoot: URL, currentReportStamp: String?) throws {
    let fm = FileManager.default
    if let stamp = currentReportStamp {
        let reportURL = vaultRoot.appendingPathComponent(".dream/reports/dream-report-\(stamp).md")
        try? fm.removeItem(at: reportURL)         // 只删当次 report
    }
    // 不删 .dream/reports/ 目录、.dream/ledger.json、.dream/processed.json
}
```

**确证** — 只删当次 report stamp, 目录不动. ledger.json / processed.json 走 git discard 还原.

**报告不准确** (应该是看老代码). 误报.

---

### 3.2 正则表达式误伤 ⚠️ 半真

**报告原话**: `IP_ADDR` `(?:\d{1,3}\.){3}\d{1,3}` 误伤版本号 `1.4.15.2`.

**验证** (`Sources/DreamEngine/Redactor.swift`):
```swift
Rule(label: "IP_ADDR",
     pattern: #"(?<!\d\.)\b(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}(?!\d)(?!\.\d)"#)
```

**已修**:
- 0-255 段验证: `(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)`
- `(?<!\d\.)` 防止 5 段 OID 末段 + IP 误截
- `(?!\d)(?!\.\d)` 防止 5+ 段 (如 `1.4.15.2` 5 段)

**5 段版本号** (`1.4.15.2`) **防住** — 5 段超过 IP 4 段.

**4 段版本号** (`1.0.0.0`): 注释承认限制:
> 已知限制: `1.0.0.0` 版本号仍会被误判 (纯 4 段 0-255 数字无法区分 IP 和版本号; 要彻底区分需要上下文分析, 超出 regex 能力).

**半真**: 5 段防住, 4 段仍误判.

**修法** (2 选 1):

**(a) 加版本号前置 context** (推荐):
```swift
// 在 "version 1.0.0.0" / "v1.0.0.0" / "App version 1.0.0.0" 上下文时不脱敏
Rule(label: "IP_ADDR",
     pattern: #"(?<!\d\.)(?<!version )(?<!v)\b(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)){3}(?!\d)(?!\.\d)"#)
```
- 优点: 简单
- 缺点: 漏 "Build 1.0.0.0" / "build-1.0.0.0" / 中文 "版本 1.0.0.0"

**(b) 后处理白名单** (更稳):
```swift
public struct Redactor {
    public var versionWhitelist: [String] = []   // ["1.0.0.0", "0.5.0", ...]
    public var versionPattern: String { #"\b(?:version|ver|v|版本|build)[- ]?(\d+(?:\.\d+){2,4})\b"# }

    public func redact(_ text: String) -> Report {
        // 1. 抽版本号候选
        let versionCandidates = extractVersions(text)
        // 2. 跑 IP 脱敏
        var report = applyRules(text)
        // 3. 还原已知版本号
        for candidate in versionCandidates {
            report.redactedText = report.redactedText
                .replacingOccurrences(of: "[REDACTED_IP_ADDR]", with: candidate)
        }
    }
}
```
- 优点: 准, 不漏
- 缺点: 复杂, 维护版本号白名单

**推荐 (a)** + 测试: 写 100 个版本号 case + 50 个 IP case, 验准确率.

**修时**: 0.5 天
**风险**: 低

---

### 3.3 糟糕的编辑器体验 ⚠️ 半真

**报告原话**: 纯文本 TextEditor, 无行号/等宽字体/语法高亮/粗体/外部链接.

**验证** (`Sources/dream/EditorPane.swift`):
- line 8 注释: "Source: NSTextView 全屏编辑 (raw/ 只读)"
- line 171: `NSTextViewRepresentable(...)` — **走了 NSTextView 不是 TextEditor**

**误报** (TextEditor 部分), 但:
- NSTextView 默认**无行号** (TextKit 不带)
- **无语法高亮** (Markdown 需 MarkdownUI 或自写 TextKit 高亮)
- **无等宽字体** (默认 San Francisco, 需手动 set font)
- **无粗体/链接** (需 TextKit 2 attachments + custom drawing)

**半真**: NSTextView 用了, 但**没配齐笔记 App 必备功能**.

**修法** (3 阶段, P1 优先级):

**P1.1 (1 周)**: 加行号 + 等宽字体
```swift
// NSTextViewRepresentable 配置
let textView = NSTextView()
textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
textView.textContainerInset = NSSize(width: 8, height: 8)
textView.isAutomaticQuoteSubstitutionEnabled = false
textView.isAutomaticDashSubstitutionEnabled = false
// Gutter: line numbers via NSRulerView
textView.textContainer?.widthTracksTextView = true
```

**P1.2 (1-2 周)**: Markdown 语法高亮
```swift
// 简易方案: NSAttributedString 高亮 (regex-based)
// 标题 (#) / 粗体 (**) / 链接 ([text](url)) / 代码 (`) 着色
textView.textStorage?.setAttributes(highlighted, range: nsString.range(of: line))
```
- 复杂度中, 用 NSTextStorageDelegate + processEditing

**P1.3 (1-2 周)**: 外部链接 + 粗体渲染
- 链接: NSTextView.linkTextAttributes + NSTextViewDelegate.textClicked
- 粗体: NSAttributedString.font = NSFont.boldSystemFont(ofSize: 13) 范围

**修时**: P1.1 = 1 周, P1.2 = 1-2 周, P1.3 = 1-2 周
**风险**: 中 (TextKit 2 跟 macOS 14+ 兼容, 老 macOS 11 走 TextKit 1)

**替代方案**: 引入 MarkdownUI (SwiftUI native, 跨 iOS/macOS)
- 优点: 省事, 跨平台
- 缺点: 跟 NSTextView 集成需要 bridge, 失去一些 control

---

## 修复优先级总结

### P0 (1 周内必修, 致命)

| § | 修法 | 时 | 风险 |
|---|---|---|---|
| 1.1 | RelatedCache 24h + topRelated maxHops | 0.5-1 天 | 中 |
| 1.3 | FrontmatterScanner 流式扫 | 0.5 天 | 低 |
| 2.2 | dream 启动自动 commit 用户非引擎改动 | 0.5 天 | 中 |

### P1 (半月内修, 严重)

| § | 修法 | 时 | 风险 |
|---|---|---|---|
| 2.1 | ConflictResolutionView hook 到 UI sheet | 1 天 | 中 |
| 3.3 P1.1 | NSTextView 行号 + 等宽字体 | 1 周 | 中 |

### P2 (可分批)

| § | 修法 | 时 | 风险 |
|---|---|---|---|
| 3.2 | IP_ADDR version context 修复 | 0.5 天 | 低 |
| 2.2 SMAppService | 系统级 daemon (需 entitlements) | 2-3 天 | 高 |
| 3.3 P1.2 | Markdown 语法高亮 | 1-2 周 | 中 |
| 3.3 P1.3 | 链接 + 粗体渲染 | 1-2 周 | 中 |

### 不修 (误报)

- 1.2 git add -A (P3-T3 修过, 走白名单 + 显式路径)
- 1.4 RetryPolicy (3 attempts + 指数退避 + jitter 已 ship)
- 2.2 Settings (8h 改动已加)
- 2.3 consolidate3Step (consolidateSmart 默认 3 步)
- 3.1 rollback 删库 (只删当次 report stamp)

---

## 建议 ship 顺序

**Phase 1 (本周)** — P0 三件
1. PR #N: P0 致命修复 (O(N²) + String 全文 + dirty workspace)
2. 测试: 10000 节点 + 5MB 文件 + dirty workspace 3 case
3. tag v0.9.0 (P0 致命修复 ship)

**Phase 2 (半月)** — P1 二件
4. PR #N+1: ConflictResolutionView UI hook
5. PR #N+2: NSTextView 行号 + 等宽字体
6. tag v0.10.0 (P1 严重修复)

**Phase 3 (月)** — P2 + 文档
7. IP_ADDR 修法 + SMAppService (大工程) + Markdown 高亮
8. v0.11.0+ 分阶段

---

## 给用户的 review 提示

报告有 4 条误报 (P3 已修过), **不要被"全部致命"语气带偏**. 真问题 4 条全是 P0/P1 级, 但都是**单点修复**不是系统性灾难.

**4 条真问题**的核心矛盾是:
- §1.1 性能: 工程债, 1 天修
- §1.3 性能: 单行 fix, 0.5 天修
- §2.2 UX: 哲学问题 (engine 边界), 0.5 天修
- §2.1 半真: UI 收尾, 1 天修

**总 P0+P1 修复 1 周 + 半月, 不需要重写架构**.

**v0.9.0 / v0.10.0 ship 后**:
- 真量化 88% / 92% (v0.7.6 baseline 守住)
- 编辑器行号 + 等宽字体 (P1.1)
- 矛盾 UI 可点 (P1)

这是用户能**立刻感知**的修复, 杠杆高.

---

## 后续验证

用户 review 本计划后, 建议:
1. 标 ✅ / ❌ 哪条 P0/P1 真修, 哪条 P2 推迟
2. 标 ship 顺序是否调整
3. 任何"报告里我没看到的细节"补 (例如 §1.1 是否在 N=100 阶段已卡顿, 还是用户预测)
4. 然后开新 worktree (`feat/p<N>-<topic>`) 逐条 ship
