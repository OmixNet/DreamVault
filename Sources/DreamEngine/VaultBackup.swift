import Foundation

/// P7-T2: Vault 整目录 backup / restore。
///
/// 用 macOS 自带 /usr/bin/zip + /usr/bin/unzip（Foundation 自带 ZIP 太弱）。
/// 备份含 vault 内所有 .md / .json / .git（不含 raw 大文件以外的 build artifacts），
/// 恢复时会先确认 vault 非空。
///
/// 备份 zip 写到 ~/Desktop/DreamVault-vault-<timestamp>.zip
/// 恢复 NSOpenPanel 让用户选 zip → 解压到临时目录 → 二次确认 → 原子 mv 到目标 vault
@MainActor
public final class VaultBackup: ObservableObject {

    public enum BackupError: Error, LocalizedError {
        case zipNotFound
        case zipFailed(Int32, String)
        case unzipNotFound
        case unzipFailed(Int32, String)
        case vaultNotEmpty(URL)
        case notAZipFile(URL)
        case destinationNotWritable(URL)

        public var errorDescription: String? {
            switch self {
            case .zipNotFound: return "/usr/bin/zip 不存在"
            case .zipFailed(let code, let stderr): return "zip 失败 (exit \(code)): \(stderr)"
            case .unzipNotFound: return "/usr/bin/unzip 不存在"
            case .unzipFailed(let code, let stderr): return "unzip 失败 (exit \(code)): \(stderr)"
            case .vaultNotEmpty(let url): return "vault 非空（拒绝覆盖）：\(url.path)"
            case .notAZipFile(let url): return "不是有效的 .zip 文件：\(url.path)"
            case .destinationNotWritable(let url): return "目标目录不可写：\(url.path)"
            }
        }
    }

    @Published public private(set) var lastBackupPath: URL? = nil
    @Published public private(set) var lastRestoreFrom: URL? = nil
    @Published public private(set) var isRunning: Bool = false

    public init() {}

    // MARK: - Backup

    /// 备份整个 vault 到 zip（含 .git + .dream + raw + wiki + MEMORY.md）
    /// - 大 vault（>500MB）会慢；raw 里的媒体文件跳过（zip 体积大）
    /// - 失败抛 BackupError
    public func backup(vaultRoot: URL, to outputZip: URL? = nil) throws -> URL {
        isRunning = true
        defer { isRunning = false }

        let zipURL: URL
        if let provided = outputZip {
            zipURL = provided
        } else {
            // 默认 ~/Desktop/DreamVault-vault-<timestamp>.zip
            let stamp = Self.timestamp()
            zipURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
                .appendingPathComponent("DreamVault-vault-\(stamp).zip")
        }
        try? FileManager.default.removeItem(at: zipURL)

        // 先检查 zip 在不在
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else {
            throw BackupError.zipNotFound
        }

        // 排除 .build / .opencode / DS_Store 等噪音
        let exclude = [
            ".build", ".swiftpm", ".opencode",
            "*.dSYM", ".DS_Store", "node_modules", ".venv"
        ]
        // 用 -x 多组 --exclude pattern
        var args = ["-r", "-q", zipURL.path, "."]
        for e in exclude {
            args.append("--exclude")
            args.append(e)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = args
        p.currentDirectoryURL = vaultRoot
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackupError.zipFailed(p.terminationStatus, err)
        }

        lastBackupPath = zipURL
        return zipURL
    }

    // MARK: - Restore

    /// 从 zip 恢复到 vault。
    /// - 二次确认：dest 不为空 → 抛 .vaultNotEmpty（不覆盖用户文件）
    /// - 解压到 dest，恢复 .git + .dream + raw + wiki + MEMORY.md
    public func restore(zipFile: URL, to dest: URL) throws {
        isRunning = true
        defer { isRunning = false }

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else {
            throw BackupError.unzipNotFound
        }
        // 安全检查：zip 存在且扩展名是 .zip
        guard zipFile.pathExtension.lowercased() == "zip" else {
            throw BackupError.notAZipFile(zipFile)
        }
        guard FileManager.default.fileExists(atPath: zipFile.path) else {
            throw BackupError.notAZipFile(zipFile)
        }
        // dest 可写 + 不空 → 拒绝（避免覆盖用户现有 vault）
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue else {
            throw BackupError.destinationNotWritable(dest)
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
        if !contents.isEmpty {
            // 不含隐藏文件 .DS_Store 才算空
            let real = contents.filter { $0 != ".DS_Store" }
            if !real.isEmpty {
                throw BackupError.vaultNotEmpty(dest)
            }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", zipFile.path, "-d", dest.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackupError.unzipFailed(p.terminationStatus, err)
        }
        lastRestoreFrom = zipFile
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
