// P2-1: 菜单栏 logic 单测
import XCTest
@testable import dream
@testable import DreamEngine
import AppKit
import UserNotifications

@MainActor
final class MenuBarControllerTests: XCTestCase {
    // MARK: - SF Symbol 名称

    func testIdleSymbol() {
        XCTAssertEqual(MenuBarController.symbolName(for: .idle), "moon.stars")
    }

    func testRunningSymbol() {
        XCTAssertEqual(MenuBarController.symbolName(for: .running), "moon.stars.fill")
    }

    func testHasNewSymbol() {
        XCTAssertEqual(MenuBarController.symbolName(for: .hasNew(3)), "moon.stars.fill")
        XCTAssertEqual(MenuBarController.symbolName(for: .hasNew(99)), "moon.stars.fill")
    }

    // MARK: - 通知正文

    func testNotificationBodyNoExcerpt() {
        let body = MenuBarController.notificationBody(accepted: 5, archived: 2, topExcerpt: nil)
        XCTAssertTrue(body.contains("5 accepted"))
        XCTAssertTrue(body.contains("2 archived"))
        XCTAssertTrue(body.contains("Tap to open vault"))
    }

    func testNotificationBodyEmptyExcerpt() {
        let body = MenuBarController.notificationBody(accepted: 0, archived: 0, topExcerpt: "")
        XCTAssertTrue(body.contains("Tap to open vault"))
    }

    func testNotificationBodyWithExcerptTruncatesAt80() {
        let long = String(repeating: "x", count: 200)
        let body = MenuBarController.notificationBody(accepted: 1, archived: 0, topExcerpt: long)
        XCTAssertTrue(body.contains("xxx"))
        // 摘录部分不超过 80 字符
        let parts = body.components(separatedBy: "\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertLessThanOrEqual(parts[1].count, 80)
    }

    func testNotificationBodyShortExcerptUntouched() {
        let body = MenuBarController.notificationBody(accepted: 1, archived: 0, topExcerpt: "hello")
        XCTAssertTrue(body.contains("hello"))
    }

    func testForegroundNotificationOptionsUseBannerAndSound() {
        let options = MenuBarController.foregroundNotificationOptions()
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.sound))
        XCTAssertFalse(options.contains(.badge))
    }

    // MARK: - Recent Memory 标题截断

    func testRecentMemoryMenuTitleShort() {
        XCTAssertEqual(MenuBarController.recentMemoryMenuTitle("hi"), "hi")
        XCTAssertEqual(MenuBarController.recentMemoryMenuTitle("a 60-char text here"), "a 60-char text here")
    }

    func testRecentMemoryMenuTitleLongTruncated() {
        let long = String(repeating: "a", count: 100)
        let title = MenuBarController.recentMemoryMenuTitle(long)
        XCTAssertEqual(title.count, 61)  // 60 chars + "…"
        XCTAssertTrue(title.hasSuffix("…"))
    }

    // MARK: - IconState Equatable

    func testIconStateEquality() {
        XCTAssertEqual(MenuBarController.IconState.idle, .idle)
        XCTAssertEqual(MenuBarController.IconState.running, .running)
        XCTAssertEqual(MenuBarController.IconState.hasNew(3), .hasNew(3))
        XCTAssertNotEqual(MenuBarController.IconState.hasNew(3), .hasNew(4))
        XCTAssertNotEqual(MenuBarController.IconState.idle, .running)
    }
}
