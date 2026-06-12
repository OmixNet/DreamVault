import Foundation

/// P7-T3: 写文件的"崩了不写一半"模式。
///
/// 流程：
///   1. 写到 <target>.tmp.<uuid>（同目录）
///   2. fsync（如果可能）确保数据落盘
///   3. 原子 rename 到 target
/// 任何中间崩了：target 是上次成功的旧版本，tmp 文件残留可清理。
///
/// 不依赖 `Data.write(to:atomically: true)` —— 那是 Foundation 内部实现
/// （macOS 上是 tmp + rename，但 iOS / Linux 不一定）。这里显式做 + 自带
/// fsync 选项。
public enum AtomicFile {

    public enum AtomicWriteError: Error, LocalizedError {
        case writeFailed(URL, Error)
        case renameFailed(URL, Error)
        case noParentDirectory(URL)

        public var errorDescription: String? {
            switch self {
            case .writeFailed(let url, let err): return "write failed: \(url.path): \(err.localizedDescription)"
            case .renameFailed(let url, let err): return "rename failed: \(url.path): \(err.localizedDescription)"
            case .noParentDirectory(let url): return "parent dir doesn't exist: \(url.deletingLastPathComponent().path)"
            }
        }
    }

    /// 写 Data 到 target。atomically = tmp + rename。
    /// - fsync: 是否调 fsync() 强制数据落盘（更慢但更安全；machine crash / power loss
    ///   后不会写一半）。默认 true。CI / 测试可设 false 加速。
    public static func write(data: Data, to target: URL, fsync: Bool = true) throws {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw AtomicWriteError.noParentDirectory(target)
        }
        // tmp 名：target + ".tmp." + uuid
        let tmp = parent
            .appendingPathComponent(target.lastPathComponent + ".tmp." + UUID().uuidString)
        do {
            try data.write(to: tmp, options: [.atomic])
            if fsync {
                // 打开 tmp 调 fsync
                let fd = Darwin.open(tmp.path, Darwin.O_RDONLY)
                if fd >= 0 {
                    Darwin.fsync(fd)
                    Darwin.close(fd)
                }
            }
        } catch {
            // 清理 tmp
            try? FileManager.default.removeItem(at: tmp)
            throw AtomicWriteError.writeFailed(tmp, error)
        }
        // 原子 rename
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } catch {
            // replace 失败（target 旧文件不存在场景会失败）→ 退到 mv
            do {
                try FileManager.default.moveItem(at: tmp, to: target)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw AtomicWriteError.renameFailed(target, error)
            }
        }
    }
}
