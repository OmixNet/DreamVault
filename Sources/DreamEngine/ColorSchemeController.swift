import SwiftUI

/// P5-T2: 手动覆盖 color scheme。
/// UserDefaults key: "DreamVault.colorSchemeOverride"
/// - "system" = 跟系统（默认）
/// - "light"  = 强制亮色
/// - "dark"   = 强制暗色
@MainActor
public final class ColorSchemeController: ObservableObject {
    public static let shared = ColorSchemeController()

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .system: return "Follow System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    @Published public var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "DreamVault.colorSchemeOverride") }
    }

    public init() {
        if let raw = UserDefaults.standard.string(forKey: "DreamVault.colorSchemeOverride"),
           let m = Mode(rawValue: raw) {
            self.mode = m
        } else {
            self.mode = .system
        }
    }

    /// 给 SwiftUI .preferredColorScheme 用的 binding
    public var preferredColorScheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
