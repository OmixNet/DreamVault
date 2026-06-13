import Foundation

// MARK: - raw/ 只读守卫
//
// 对应架构文档第 0.1 节（"raw/ 永远只读、永不衰减"）与第 1 节末段：
// "raw/ 在文件系统层面挂为只读（app 启动时 chmod，dream 引擎对它只有读权限）。
//  这把'原则 1'变成机制而非自觉。"
//
// 这一层实现：
//   1. `makeReadonly(vaultRoot:)`  — 把 raw/ 下的文件压成只读，把目录保持为可
//      traverse 且可接收新导入文件。这样 raw 文件不可被编辑，同时 GUI Import 仍能
//      把新文件落进 raw/。
//   2. `isReadonly(vaultRoot:)`     — 探活：raw/ 下任一可处理文件可写即视为非只读。
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

    /// raw 子目录的权限：rwx r-x r-x。目录保留 owner 写权限，支持受控导入新 raw 文件。
    public static let readonlyDirMode: Int = 0o755

    /// 把 raw/ 下文件压成只读，并保持目录可遍历/可接收新导入。
    ///
    /// 行为：
    ///   - 若 raw/ 不存在 → 直接返回（不报错；新建 vault 在第一次 dream 之前没 raw）
    ///   - 递归遍历 raw/ 下所有文件与子目录
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

        // 先把 raw/ 自身 chmod（递归遍历依赖它本身可 traverse；导入依赖 owner 可写）
        try? chmodReadonlyMode(at: rawDir, isDirectory: true, fm: fm)

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
            try? chmodReadonlyMode(at: url, isDirectory: isDir, fm: fm)
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
        guard let enumerator = fm.enumerator(
            at: rawDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        var sawRawFile = false
        for case let f as URL in enumerator {
            guard isProtectedRawFile(f) else { continue }
            sawRawFile = true
            if isWritable(at: f) { return false }
        }
        return sawRawFile
    }

    /// Importer 写入新文件后可调用这个方法立刻恢复 raw 文件不可写状态。
    public static func makeFileReadonly(_ url: URL) {
        let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        try? chmodReadonlyMode(at: url, isDirectory: isDir, fm: FileManager.default)
    }

    // MARK: - 私有工具

    /// 把单条路径权限压成 raw 保护模式，错误不抛、记 stderr。
    private static func chmodReadonlyMode(at url: URL, isDirectory: Bool, fm: FileManager) throws {
        let mode = NSNumber(value: isDirectory ? readonlyDirMode : readonlyPosixMode)
        do {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            // EPERM / EACCES（root 拥有、SIP 路径等）—— 跳过但记 stderr
            FileHandle.standardError.write(Data(
                "[RawReadonlyGuard] chmod raw readonly mode 失败（已跳过）: \(url.path) — \(error.localizedDescription)\n".utf8))
        }
    }

    private static func isProtectedRawFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "txt"
    }

    /// 单文件是否对当前用户可写（用 FileManager.isWritableFile(atPath:)）。
    private static func isWritable(at url: URL) -> Bool {
        return FileManager.default.isWritableFile(atPath: url.path)
    }
}
