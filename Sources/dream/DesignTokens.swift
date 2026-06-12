// P2-5: 视觉系统统一 (DesignTokens)
// 5 类 token: Spacing / Color / Typography / Radius / Sizing
// 用 static const 暴露, 全 app 统一引用, 改一处全生效
import SwiftUI

/// P2-5: 间距 (8 倍数 grid)
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs:  CGFloat = 4
    public static let sm:  CGFloat = 8
    public static let md:  CGFloat = 12
    public static let lg:  CGFloat = 16
    public static let xl:  CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// P2-5: 圆角
public enum Radius {
    public static let sm: CGFloat = 4
    public static let md: CGFloat = 6
    public static let lg: CGFloat = 8
    public static let xl: CGFloat = 12
    public static let pill: CGFloat = 999  // 圆球
}

/// P2-5: 字体 (system / monospaced / caption 等)
public enum AppFont {
    public static let body = Font.system(size: 13)
    public static let caption = Font.system(size: 11)
    public static let caption2 = Font.system(size: 10)
    public static let title3 = Font.system(size: 16, weight: .semibold)
    public static let title2 = Font.system(size: 18, weight: .bold)
    public static let mono = Font.system(size: 12, design: .monospaced)
    public static let monoSmall = Font.system(size: 10, design: .monospaced)
    /// 数字字号 (跟 durable count 之类对齐)
    public static func monoDigit(_ size: CGFloat = 12) -> Font {
        Font.system(size: size, design: .monospaced)
    }
}

/// P2-5: 颜色 (语义命名, 不跟具体 hex 绑定)
public enum AppColor {
    // 背景层级 (dark mode 自动适配)
    public static let background = Color(NSColor.windowBackgroundColor)
    public static let surface    = Color(NSColor.controlBackgroundColor)
    public static let elevated   = Color(NSColor.underPageBackgroundColor)

    // 文字
    public static let textPrimary   = Color(NSColor.labelColor)
    public static let textSecondary = Color(NSColor.secondaryLabelColor)
    public static let textTertiary  = Color(NSColor.tertiaryLabelColor)

    // 边框
    public static let divider = Color(NSColor.separatorColor)
    public static let outline = Color(NSColor.gridColor)

    // 状态色
    public static let accent  = Color.accentColor          // 系统蓝
    public static let success = Color.green
    public static let warning = Color.yellow
    public static let danger  = Color.red
    public static let info    = Color.blue

    // 半透明遮罩 (banners 用)
    public static let warningBackground = Color.yellow.opacity(0.15)
    public static let infoBackground    = Color.blue.opacity(0.12)
    public static let dangerBackground  = Color.red.opacity(0.12)

    // 选中
    public static let selection = Color.accentColor.opacity(0.3)
}

/// P2-5: 阴影
public enum AppShadow {
    public static let sm = ShadowStyle(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    public static let md = ShadowStyle(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    public static let lg = ShadowStyle(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
}

public struct ShadowStyle: Equatable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat
    public init(color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) {
        self.color = color; self.radius = radius; self.x = x; self.y = y
    }
}

/// P2-5: 通用 modifier — 把 view 套上 token 样式
public extension View {
    /// 标准卡片背景 (surface + radius + shadow)
    func card(padding: CGFloat = Spacing.md, radius: CGFloat = Radius.md) -> some View {
        self.padding(padding)
            .background(AppColor.surface)
            .cornerRadius(radius)
            .shadow(color: AppShadow.sm.color, radius: AppShadow.sm.radius,
                    x: AppShadow.sm.x, y: AppShadow.sm.y)
    }
    /// 标准 banner 样式 (warning / info / danger)
    func bannerStyle(_ style: BannerStyle) -> some View {
        self.padding(Spacing.sm)
            .background(style.background)
            .cornerRadius(Radius.md)
    }
}

public enum BannerStyle {
    case warning, info, danger
    public var background: Color {
        switch self {
        case .warning: return AppColor.warningBackground
        case .info:    return AppColor.infoBackground
        case .danger:  return AppColor.dangerBackground
        }
    }
}
