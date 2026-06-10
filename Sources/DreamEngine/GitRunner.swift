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

    /// 暂存全部变更并提交。无变更时返回 false（不视为错误——dream 可能一夜无事发生）。
    @discardableResult
    public func commitAll(message: String) throws -> Bool {
        try run(["add", "-A"])
        let staged = try run(["status", "--porcelain"])
        guard !staged.isEmpty else { return false }
        try run(Self.identity + ["commit", "-m", message])
        return true
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
