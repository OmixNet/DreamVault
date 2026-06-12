// P1-1: durable 100+ banner 阈值测试
import XCTest
@testable import dream
@testable import DreamEngine
import AppKit

@MainActor
final class ThreeStepBannerTests: XCTestCase {
    func testShowBannerWhenDurableOver100AndNotEnabled() {
        XCTAssertTrue(SettingsView.shouldShowThreeStepBanner(durableCount: 100, useThreeStepCoT: false))
        XCTAssertTrue(SettingsView.shouldShowThreeStepBanner(durableCount: 250, useThreeStepCoT: false))
    }

    func testNoBannerWhenDurableUnder100() {
        XCTAssertFalse(SettingsView.shouldShowThreeStepBanner(durableCount: 99, useThreeStepCoT: false))
        XCTAssertFalse(SettingsView.shouldShowThreeStepBanner(durableCount: 0, useThreeStepCoT: false))
    }

    func testNoBannerWhenThreeStepAlreadyEnabled() {
        XCTAssertFalse(SettingsView.shouldShowThreeStepBanner(durableCount: 500, useThreeStepCoT: true))
    }

    func testThresholdIs100() {
        XCTAssertEqual(SettingsView.threeStepBannerThreshold, 100,
                       "Banner 阈值应为 100 条 durable; 改了需同步更新 P1-1 文档")
    }
}
