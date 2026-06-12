import Foundation

/// 用 Process 封装 git，提供 dream 引擎需要的最小操作集：commit / tag / revert。
/// vault 即一个 git 仓库，git 是 dream 周期的事务边界与回滚机制（架构文档第 3 节）。
public struct GitRunner {
    public let repoRoot: URL

    public struct GitError: Error, CustomStringConvertible {
        public let command: [String]
        public let exitCode: Int32
        public let stderr: String
        public var description: String {
            "git \(command.joined(separator: " ")) 失败 (exit \(exitCode)): \(stderr)"
        }
    }

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    /// 运行一条 git 子命令，返回 stdout（去尾部空白）。非零退出抛 GitError。
    @discardableResult
    public func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = repoRoot
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw GitError(command: args, exitCode: p.terminationStatus,
                           stderr: err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // P0-2 fix: 只 trim 尾部空白。**保留前导** —— v1 porcelain 的
        // " M wiki/concepts/a.md"（X=空格，Y=M）开头就是空格，
        // 之前 trimCharacters 会把前导空格吞掉让 parser 错把 X 解析为 'M'。
        if let lastNonWhitespace = out.lastIndex(where: { !$0.isWhitespace }) {
            return String(out[...lastNonWhitespace])
        }
        return ""
    }

    /// repoRoot 是否已是 git 仓库
    public func isRepo() -> Bool {
        (try? run(["rev-parse", "--is-inside-work-tree"])) == "true"
    }

    /// 初始化仓库（已是仓库则无操作）
    public func initIfNeeded() throws {
        guard !isRepo() else { return }
        try run(["init"])
    }

    /// 暂存指定路径（相对 repoRoot）
    public func add(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try run(["add", "--"] + paths)
    }

    /// dream 提交统一署名为引擎，不依赖宿主机 git 配置（无配置的全新 vault 也能提交）
    public static let identity = ["-c", "user.name=DreamEngine", "-c", "user.email=dream@dreamvault.local"]

/// dream 写出的路径集合。其他路径都被视为"用户领地"，dream 不触碰。
    static let enginePaths = [
        "MEMORY.md",
        ".dream/",
        "wiki/",
        "archive/",
    ]

    static func isEnginePath(_ path: String) -> Bool {
        Self.enginePaths.contains { p in
            path == p || path.hasPrefix(p)
        }
    }

    /// 暂存全部变更并提交。无变更时返回 false（不视为错误——dream 可能一夜无事发生）。
    ///
    /// 设计选择：**只 commit 引擎写的路径**，不 `git add -A` 后整盘 commit。
    /// 理由：`add -A` 会把用户自己的工作区改动（甚至未追踪的 raw 文件）
    /// 一起吞进 dream commit，破坏"git 是事务边界"的纯净性。
    ///
    /// 实现：P3-T3 fix —— 不再用 `add -A`。改为：
    /// 1. `git status --porcelain` 拿到所有 dirty 路径
    /// 2. 用白名单（isEnginePath）过滤出引擎路径
    /// 3. 对引擎路径调 `git add`（显式，不含 raw/，避免大文件被 hash）
    /// 4. `git diff --cached --name-only` 校验 stage 集合非空再 commit
    @discardableResult
    public func commitAll(message: String) throws -> Bool {
        // 1. 拿所有 dirty 路径（untracked + modified + staged）
        let statusOut = (try? run(["status", "--porcelain"])) ?? ""
        let allDirty = Self.parseStatusPaths(statusOut)

        // 2. 过滤出引擎路径（白名单）
        let enginePaths = allDirty.filter { Self.isEnginePath($0) }
        guard !enginePaths.isEmpty else {
            return false  // 没引擎写的变更，nothing to commit
        }

        // 3. 显式 add 引擎路径
        try run(["add", "--"] + enginePaths)

        // 4. 校验：必须至少 1 个文件真在 index 里（容错：路径可能已被删）
        let final = (try? run(["diff", "--cached", "--name-only"])) ?? ""
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        try run(Self.identity + ["commit", "-m", message])
        return true
    }

    /// 把 `git status --porcelain` 输出解析为路径列表（去重 + 跳过空行 + 跳过子模块状态）
    /// v1 porcelain 状态字段固定 2 字符 + 空格 + 路径。
    private static func parseStatusPaths(_ porcelain: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in porcelain.components(separatedBy: "\n") {
            guard line.count >= 4 else { continue }
            // 跳过前导空格（" M file" 第一字符是空格）
            var i = 0
            // 状态字段（最多 2 个非空格字符）
            var statusLen = 0
            while i < line.count, line[line.index(line.startIndex, offsetBy: i)] != " ", statusLen < 2 {
                i += 1
                statusLen += 1
            }
            // 跳过分隔空格
            while i < line.count, line[line.index(line.startIndex, offsetBy: i)] == " " {
                i += 1
            }
            guard i < line.count else { continue }
            let path = String(line[line.index(line.startIndex, offsetBy: i)...])
            // rename 形式 "old -> new" 取 RHS
            let cleaned: String
            if let arrow = path.range(of: " -> ") {
                cleaned = String(path[arrow.upperBound...])
            } else {
                cleaned = path
            }
            if seen.insert(cleaned).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    /// 检查 vault 工作区是否有任何未提交改动（除引擎路径外）。
    /// 注意：raw/ 也算用户改动 —— dream 不应替用户 commit raw 文件。
    /// 用户应先 commit 自己的 raw 日志，再跑 dream。
    ///
    /// 同时，引擎路径的**未追踪**文件（如 .dream/ledger.json 新建）也不算"用户改动"，
    /// 因为这些文件就是 dream 要写入的目标 —— 但**未追踪的引擎路径如果存在**，
    /// 说明 dream 之前没 commit 完（如中途崩溃），应该让 dream 接管完成 commit。
    /// 所以这里不区分 staged/unstaged/untracked，只要路径是引擎路径就算 OK。
    public func hasUserDirtyChanges() throws -> Bool {
        let porcelain = try run(["status", "--porcelain"])
        for line in porcelain.components(separatedBy: "\n") where !line.isEmpty {
            // git porcelain v1 格式是 "XY filename"（X=index 状态，Y=worktree 状态，
            // 共 2 个状态字符 + 1 个空格 + 文件名）。但某些 git 版本对 "M  raw/..."
            // 会省略 leading 空格，所以从第一个非状态字符开始算更稳。
            // 状态字符只可能是：A/M/T/D/R/C/U/?/!/空格。空格 + 路径 = 文件名起点。
            // 找到第一个 ASCII 字母或 '?' 之后是空格，那个空格之后就是文件名。
            // 跳过前导空格（v1 porcelain 第一字符可能是空格表示 "M "）
            var i = line.startIndex
            while i < line.endIndex, line[i] == " " || line[i] == "\t" {
                i = line.index(after: i)
            }
            // 跳过状态字符（最多 2 个非空格）
            var statusCount = 0
            while i < line.endIndex, statusCount < 2,
                  line[i] != " " && line[i] != "\t" {
                i = line.index(after: i)
                statusCount += 1
            }
            // skip 分隔空格
            while i < line.endIndex, line[i] == " " || line[i] == "\t" {
                i = line.index(after: i)
            }
            guard i < line.endIndex else { continue }
            let afterStatus = String(line[i...])
            // rename 形式取箭头右边
            let path: String
            if let arrowRange = afterStatus.range(of: " -> ") {
                path = String(afterStatus[arrowRange.upperBound...])
            } else {
                path = afterStatus
            }
            // 引擎路径：dream 自己的输出，OK
            if Self.isEnginePath(path) { continue }
            // raw/ 永远只读（arch doc 0.1）：chmod 0o555 也会让 porcelain 显示 dirty，
            // 但 dream 不应把"raw 文件被自己 chmod"当成用户改动。判断：路径以 "raw/" 开头
            // 就跳过。
            if path.hasPrefix("raw/") { continue }
            // 其他：用户改动，dream 拒绝
            return true
        }
        return false
    }

    /// 打标签（轻量 tag）
    public func tag(_ name: String) throws {
        try run(["tag", name])
    }

    /// revert 最近一次提交（--no-edit，不开编辑器）。这是 DreamPanel"回滚上次 dream"的底层。
    public func revertLast() throws {
        try run(Self.identity + ["revert", "--no-edit", "HEAD"])
    }

    /// 当前 HEAD 的 commit hash
    public func headHash() throws -> String {
        return try run(["rev-parse", "HEAD"])
    }

    /// 回滚最近一次 commit。**不能**用于已被 push 的 commit（v0.3 自签名本地使用够用）。
    /// P5-T1: ConflictResolutionView undo 用
    public func revertLastCommit() throws -> String {
        let head = try headHash()
        try run(Self.identity + ["revert", "--no-edit", head])
        return try headHash()
    }

    /// git status --porcelain 输出（空 = 工作区干净）
    public func statusPorcelain() throws -> String {
        try run(["status", "--porcelain"])
    }

    /// 丢弃工作区中已跟踪文件的未提交修改（用于 dream 事务失败时回滚）。
    /// 注意：不动未跟踪文件——raw/ 里用户新扔进来的日志绝不能被回滚误删；
    /// 引擎自己新建的未跟踪文件由 DreamCycle 按清单显式删除。
    public func discardTrackedChanges() throws {
        try run(["checkout", "--", "."])
    }
}
