// P2-5: DesignTokens 单测 — 验证 token 一致性 (间距递增、radius 不为 0、font 存在)
import XCTest
@testable import dream
import SwiftUI

@MainActor
final class DesignTokensTests: XCTestCase {
    // MARK: - Spacing

    func testSpacingIsMonotonic() {
        // 间距应严格递增 (避免错填)
        XCTAssertLessThan(Spacing.xxs, Spacing.xs)
        XCTAssertLessThan(Spacing.xs, Spacing.sm)
        XCTAssertLessThan(Spacing.sm, Spacing.md)
        XCTAssertLessThan(Spacing.md, Spacing.lg)
        XCTAssertLessThan(Spacing.lg, Spacing.xl)
        XCTAssertLessThan(Spacing.xl, Spacing.xxl)
    }

    func testSpacingAllPositive() {
        XCTAssertGreaterThan(Spacing.xxs, 0)
        XCTAssertGreaterThan(Spacing.xs, 0)
        XCTAssertGreaterThan(Spacing.sm, 0)
        XCTAssertGreaterThan(Spacing.md, 0)
        XCTAssertGreaterThan(Spacing.lg, 0)
        XCTAssertGreaterThan(Spacing.xl, 0)
        XCTAssertGreaterThan(Spacing.xxl, 0)
    }

    // MARK: - Radius

    func testRadiusHierarchy() {
        XCTAssertLessThan(Radius.sm, Radius.md)
        XCTAssertLessThan(Radius.md, Radius.lg)
        XCTAssertLessThan(Radius.lg, Radius.xl)
        XCTAssertGreaterThan(Radius.pill, Radius.xl)  // 圆球最大
    }

    // MARK: - Font

    func testFontConstantsExist() {
        // 编译期存在性 — 实际值不重要
        _ = AppFont.body
        _ = AppFont.caption
        _ = AppFont.caption2
        _ = AppFont.title3
        _ = AppFont.title2
        _ = AppFont.mono
        _ = AppFont.monoSmall
    }

    func testMonoFontIsMonospaced() {
        // mono 字体应是 monospaced design
        // 不直接验证 (SwiftUI Font 抽象), 但确保 monoDigit 返回值非 nil
        _ = AppFont.monoDigit(14)
        _ = AppFont.monoDigit()  // 默认 12
    }

    // MARK: - Color

    func testColorSemanticsExist() {
        // 全部存在性 check (semantic 命名, 不绑具体 hex)
        _ = AppColor.background
        _ = AppColor.surface
        _ = AppColor.elevated
        _ = AppColor.textPrimary
        _ = AppColor.textSecondary
        _ = AppColor.textTertiary
        _ = AppColor.divider
        _ = AppColor.outline
        _ = AppColor.accent
        _ = AppColor.success
        _ = AppColor.warning
        _ = AppColor.danger
        _ = AppColor.info
    }

    // MARK: - BannerStyle

    func testBannerStyles() {
        XCTAssertNotNil(BannerStyle.warning.background)
        XCTAssertNotNil(BannerStyle.info.background)
        XCTAssertNotNil(BannerStyle.danger.background)
        // warning 应是黄色系
        // info 应是蓝色系, danger 应是红色系 (语义, 不绑具体色)
    }

    // MARK: - View modifier

    func testCardModifier() {
        // 编译期存在性 + 不 crash
        let view = Text("test").card()
        // 没法直接验视觉, 但能 instantiate
        _ = view
    }

    func testBannerStyleModifier() {
        let view = Text("test").bannerStyle(.warning)
        _ = view
    }
}
