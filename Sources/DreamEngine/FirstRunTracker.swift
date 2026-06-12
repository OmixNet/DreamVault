import Foundation

/// P7-T1: first-run 标志管理（纯 Foundation，可在 library + test 用）
public enum FirstRunTracker {
    public static let didShowWelcomeKey = "DreamVault.didShowWelcome"

    /// 判定是否应展示 welcome
    public static func shouldShow() -> Bool {
        UserDefaults.standard.bool(forKey: didShowWelcomeKey) == false
    }

    /// 标记已展示（用户完成 OR 跳过都调）
    public static func markShown() {
        UserDefaults.standard.set(true, forKey: didShowWelcomeKey)
    }

    /// 重置（用户换 vault 后重设）
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: didShowWelcomeKey)
    }
}
