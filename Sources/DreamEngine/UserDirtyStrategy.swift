import Foundation

/// P8: raw/ dirty 三选项策略（用户决策后写进 UserDefaults 永久记忆）
///
/// 选 Auto-Commit → 后续 dream run 自动 git add raw/ && commit "user: auto commit before dream"
/// 选 Prompt      → 每次都弹 alert
/// 选 Skip        → 遇到 raw/ dirty 直接报错让用户手动处理
public enum UserDirtyStrategy: String, CaseIterable {
    case autoCommit = "autoCommit"
    case prompt = "prompt"
    case skip = "skip"

    public var displayName: String {
        switch self {
        case .autoCommit: return "Auto-commit (silently commit user changes)"
        case .prompt:     return "Always prompt me"
        case .skip:       return "Never touch (ask me to handle manually)"
        }
    }

    public static let userDefaultsKey = "DreamVault.userDirtyStrategy"

    /// nil = 还没问过用户（第一次走 alert）
    public static func load() -> UserDirtyStrategy? {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let s = UserDirtyStrategy(rawValue: raw) else {
            return nil
        }
        return s
    }

    public static func save(_ strategy: UserDirtyStrategy) {
        UserDefaults.standard.set(strategy.rawValue, forKey: userDefaultsKey)
    }
}
