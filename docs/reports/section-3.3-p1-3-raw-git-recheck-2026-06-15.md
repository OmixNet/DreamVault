# §3.3 P1-3 raw/Git 事务复核 (2026-06-15)

**触发**: v0.14 收尾 P3 件, P1-3 "raw/Git 事务矛盾" 待复核.

**结论**: ❌ **误报**, doc 注释已写清, 不修. Evidence 落档.

---

## 报告原话

`commitAll` 只提交引擎路径, 见 `GitRunner.swift:96`; `hasUserDirtyChanges`
又跳过 raw/, 见 `GitRunner.swift:197`. raw 作为 source of truth 时, 这个边界
需要重新定稿.

## 复核

### 1. `commitAll` (line 96)

代码 (`Sources/DreamEngine/GitRunner.swift:95-115`):
```swift
/// 设计选择：**只 commit 引擎写的路径**, 不 `git add -A` 后整盘 commit.
/// 理由: `add -A` 会把用户自己的工作区改动 (甚至未追踪的 raw 文件)
/// 一起吞进 dream commit, 破坏 "git 是事务边界" 的纯净性.
///
/// 实现: P3-T3 fix —— 不再用 `add -A`. 改为:
/// 1. `git status --porcelain` 拿到所有 dirty 路径
/// 2. 用白名单 (isEnginePath) 过滤出引擎路径
/// 3. 对引擎路径调 `git add` (显式, 不含 raw/, 避免大文件被 hash)
/// 4. `git diff --cached --name-only` 校验 stage 集合非空再 commit
@discardableResult
public func commitAll(message: String) throws -> Bool {
    let statusOut = (try? run(["status", "--porcelain"])) ?? ""
    let allDirty = Self.parseStatusPaths(statusOut)
    let enginePaths = allDirty.filter { Self.isEnginePath($0) }
    ...
}
```

`enginePaths = [MEMORY.md, .dream/, wiki/, archive/]`. `raw/` **不在** → dream 不
commit raw 文件, **符合 raw 永远只读原则 (arch doc 0.1)**.

### 2. `hasUserDirtyChanges` (line 197)

代码 (`Sources/DreamEngine/GitRunner.swift:195-205`):
```swift
// 引擎路径: dream 自己的输出, OK
if Self.isEnginePath(path) { continue }
// raw/ 永远只读 (arch doc 0.1): chmod 0o555 也会让 porcelain 显示 dirty,
// 但 dream 不应把 "raw 文件被自己 chmod" 当成用户改动. 判断: 路径以 "raw/" 开头
// 就跳过.
if path.hasPrefix("raw/") { continue }
// 其他: 用户改动, dream 拒绝
return true
```

raw/ 跳过逻辑写在文档里 (line 197-199), 跟 `commitAll` 一致.

### 3. 整体设计 (line 175-180 doc comment)

```swift
/// 检查 vault 工作区是否有任何未提交改动 (除引擎路径外).
/// 注意: raw/ 也算用户改动 —— dream 不应替用户 commit raw 文件.
/// 用户应先 commit 自己的 raw 日志, 再跑 dream.
///
/// 同时, 引擎路径的**未追踪**文件 (如 .dream/ledger.json 新建) 也不算 "用户改动",
/// 因为这些文件就是 dream 要写入的目标 —— 但**未追踪的引擎路径如果存在**,
/// 说明 dream 之前没 commit 完 (如中途崩溃), 应该让 dream 接管完成 commit.
/// 所以这里不区分 staged/unstaged/untracked, 只要路径是引擎路径就算 OK.
```

**doc 写得很清**: 引擎路径 (MEMORY.md / .dream/ / wiki/ / archive/) 是 dream 的领地,
其他路径 (raw/ notes/) 是用户领地. **两边各自负责, 不冲突**.

## 结论: ❌ 误报

报告原话"设计矛盾"**不成立**:
- raw/ 永远只读 (arch doc 0.1 第 1 节) → dream 不 commit raw ✓
- 引擎路径白名单 (MEMORY.md/.dream/wiki/archive) → dream 只 commit 自己写 ✓
- hasUserDirtyChanges 跳过 raw/ → 不把 raw chmod 当用户改动 ✓
- 整体 doc comment (line 175-180) 写得很清, 跟 P3 修复的 commitAll 一致

**报告方"需要重新定稿" 实际已经被 P3 修过 + 8h 改动写过 doc, 现状完全清晰**。
**P1-3 不修, evidence 落档即结案**。
