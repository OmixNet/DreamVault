import Foundation

// MARK: - raw/ 只读守卫
//
// 对应架构文档第 0.1 节（"raw/ 永远只读、永不衰减"）与第 1 节末段：
// "raw/ 在文件系统层面挂为只读（app 启动时 chmod，dream 引擎对它只有读权限）。
//  这把'原则 1'变成机制而非自觉。"
//
// 这一层实现：
//   1. `makeReadonly(vaultRoot:)`  — 把 raw/ 整棵子树（包括子目录）的权限压成
//      0o555（r-x r-x r-x：可读可 traverse，不可写）。保留 x 是因为 Gatherer
//      需要遍历子目录找 .md 文件。
//   2. `isReadonly(vaultRoot:)`     — 探活：raw/ 下任一可写的 .md 文件即视为非只读。
//   3. 调用点：
//        - DreamCycle.runOnce 开头（每次 dream 启动都强压）
//        - CLI `dream run` 进入时（也强压，与 arch doc "app 启动时 chmod" 对齐）
//        - SwiftUI AppDelegate.applicationDidFinishLaunching（GUI 路径）
//
// macOS 特殊性：
//   - 在 SIP / root 拥有的路径上，posixPermissions 会被拒绝；遇到 EPERM 我们
//     写 stderr 但不抛——上层应继续运行（让用户手动 chmod）。
//   - 我们不递归修改 raw 之外的目录；只摸 raw/ 内部。

public enum RawReadonlyGuard {

    /// raw 子目录名（与 Gatherer.rawSubdir 默认值一致）
    public static let rawSubdirName = "raw"

    /// 我们期望的 raw 下文件权限：r-x r-x r-x（不可写、可读、可 traverse）
    public static let readonlyPosixMode: Int = 0o555

    /// raw 子目录的权限：r-x r-x r-x（与文件同模式；不需要写权限）
    public static let readonlyDirMode: Int = 0o555

    /// 把 raw/ 整棵子树压成只读（0o555）。
    ///
    /// 行为：
    ///   - 若 raw/ 不存在 → 直接返回（不报错；新建 vault 在第一次 dream 之前没 raw）
    ///   - 递归遍历 raw/ 下所有 .md 文件与子目录
    ///   - 任何一项 posixPermissions 写失败（EPERM 等）→ 记 stderr，继续下一个
    ///   - 全部成功后调用方可视为 raw/ 已是只读
    ///
    /// - Parameter vaultRoot: vault 根目录（应包含 raw/ 子目录）
    public static func makeReadonly(vaultRoot: URL) throws {
        let fm = FileManager.default
        let rawDir = vaultRoot.appendingPathComponent(rawSubdirName)
        guard fm.fileExists(atPath: rawDir.path) else {
            // 没有 raw/ 不报错——新 vault 第一跑 dream 时还没有 raw 是合法的
            return
        }

        // 先把 raw/ 自身 chmod（递归遍历依赖它本身可 traverse）
        try? chmod0o555(at: rawDir, isDirectory: true, fm: fm)

        // 递归遍历 raw/ 下所有条目（深度优先）
        let enumerator = fm.enumerator(
            at: rawDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator = enumerator else {
            return
        }

        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? chmod0o555(at: url, isDirectory: isDir, fm: fm)
        }
    }

    /// 探活：raw/ 下所有 .md 文件都不可写 → 返回 true。
    /// 任一可写 / raw 不存在 → 返回 false。
    public static func isReadonly(vaultRoot: URL) -> Bool {
        let fm = FileManager.default
        let rawDir = vaultRoot.appendingPathComponent(rawSubdirName)
        guard fm.fileExists(atPath: rawDir.path) else {
            // 没有 raw/ 时，按"无需保护"对待，返回 false（让上层按需决定）。
            // 这个语义对测试尤其重要：tempDir 还没有 raw 时不应该报"已只读"
            return false
        }
        guard let files = try? fm.contentsOfDirectory(
            at: rawDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return false
        }
        let mdFiles = files.filter { $0.pathExtension == "md" }
        if mdFiles.isEmpty {
            // 没有 .md 时，不算"已只读"（也不需要），返回 false
            return false
        }
        for f in mdFiles {
            if isWritable(at: f) { return false }
        }
        return true
    }

    // MARK: - 私有工具

    /// 把单条路径权限压成 0o555，错误不抛、记 stderr。
    private static func chmod0o555(at url: URL, isDirectory: Bool, fm: FileManager) throws {
        let mode = NSNumber(value: isDirectory ? readonlyDirMode : readonlyPosixMode)
        do {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            // EPERM / EACCES（root 拥有、SIP 路径等）—— 跳过但记 stderr
            FileHandle.standardError.write(Data(
                "[RawReadonlyGuard] chmod 0o555 失败（已跳过）: \(url.path) — \(error.localizedDescription)\n".utf8))
        }
    }

    /// 单文件是否对当前用户可写（用 FileManager.isWritableFile(atPath:)）。
    private static func isWritable(at url: URL) -> Bool {
        return FileManager.default.isWritableFile(atPath: url.path)
    }
}