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
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
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
    static let identity = ["-c", "user.name=DreamEngine", "-c", "user.email=dream@dreamvault.local"]

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
    /// 实现：临时 stage 所有改动（容错：路径可能不存在），然后 unstage 非引擎路径，
    /// 最后只 commit 剩下的（应该是 0 或引擎路径）。
    /// 调用方应先用 hasUserDirtyChanges() 确认工作区干净。
    @discardableResult
    public func commitAll(message: String) throws -> Bool {
        // 1. 临时 stage 所有（用 -A 容错，未追踪文件也不报错）
        try run(["add", "-A"])
        // 2. 列出已 staged 的路径，把非引擎的 unstage 掉
        let stagedOut = try run(["diff", "--cached", "--name-only"])
        let stagedPaths = stagedOut.components(separatedBy: "\n").filter { !$0.isEmpty }
        let toUnstage = stagedPaths.filter { !Self.isEnginePath($0) }
        if !toUnstage.isEmpty {
            // 用 `git reset HEAD --` 而不是 `git restore --staged`，因为空仓库（无 HEAD）
            // 时 restore 会 fatal；reset 在空仓库上也工作。
            try run(["reset", "HEAD", "--"] + toUnstage)
        }
        // 3. 看最终 staged
        let final = try run(["diff", "--cached", "--name-only"])
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        try run(Self.identity + ["commit", "-m", message])
        return true
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
            guard line.count >= 4 else { continue }
            let afterStatus = line.dropFirst(3)
            // rename 形式取箭头右边
            let path: String
            if let arrowRange = afterStatus.range(of: " -> ") {
                path = String(afterStatus[arrowRange.upperBound...])
            } else {
                path = String(afterStatus)
            }
            // 引擎路径：dream 自己的输出，OK
            if Self.isEnginePath(path) { continue }
            // 其他：用户改动（包括 raw/），dream 拒绝
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
        try run(["rev-parse", "HEAD"])
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
