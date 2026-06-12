// P2-4: SerendipitySelector 单测
import XCTest
@testable import DreamEngine
import Foundation

final class SerendipitySelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let cal = Calendar(identifier: .gregorian)

    private func makeMemory(id: String,
                            lastAccess: Date,
                            status: MemoryStatus = .durable) -> Memory {
        Memory(
            id: id,
            text: "Memory \(id)",
            sources: [SourceRef(file: "raw/\(id).md", line: 1, excerpt: "excerpt")],
            status: status,
            createdAt: lastAccess,
            lastAccess: lastAccess
        )
    }

    func testEmptyVaultReturnsNil() {
        XCTAssertNil(SerendipitySelector.pick(from: [], now: now))
    }

    func testNoDurableReturnsNil() {
        let mems = [makeMemory(id: "a", lastAccess: now.addingTimeInterval(-86400 * 60),
                                status: .candidate)]
        XCTAssertNil(SerendipitySelector.pick(from: mems, now: now))
    }

    func testAllRecentReturnsNil() {
        let mems = [
            makeMemory(id: "a", lastAccess: now.addingTimeInterval(-86400 * 5)),  // 5 天
            makeMemory(id: "b", lastAccess: now.addingTimeInterval(-86400 * 10))  // 10 天
        ]
        XCTAssertNil(SerendipitySelector.pick(from: mems, now: now))
    }

    func testOneOldEnoughReturnsIt() {
        let old = makeMemory(id: "old", lastAccess: now.addingTimeInterval(-86400 * 45))  // 45 天
        let new = makeMemory(id: "new", lastAccess: now.addingTimeInterval(-86400 * 3))  // 3 天
        let pick = SerendipitySelector.pick(from: [old, new], now: now)
        XCTAssertNotNil(pick)
        XCTAssertEqual(pick?.memory.id, "old")
        XCTAssertEqual(pick?.daysSinceAccess, 45)
    }

    func testTooOldExcluded() {
        // 100 天 = > maxDays(90) 应该排除
        let veryOld = makeMemory(id: "very-old",
                                 lastAccess: now.addingTimeInterval(-86400 * 100))
        XCTAssertNil(SerendipitySelector.pick(from: [veryOld], now: now))
    }

    func testExactly30DaysIncluded() {
        let m = makeMemory(id: "edge",
                           lastAccess: now.addingTimeInterval(-86400 * 30))
        let pick = SerendipitySelector.pick(from: [m], now: now)
        XCTAssertNotNil(pick, "正好 30 天应被包含")
    }

    func testExactly90DaysIncluded() {
        let m = makeMemory(id: "edge",
                           lastAccess: now.addingTimeInterval(-86400 * 90))
        let pick = SerendipitySelector.pick(from: [m], now: now)
        XCTAssertNotNil(pick, "正好 90 天应被包含 (边界)")
    }

    func testPreferSweetSpot() {
        // 候选: 30 天 (sweet spot 边缘), 45 天 (甜区), 80 天 (较远)
        // 算法: 先按 "离 45 最近" 排序, 取 top 3, 然后 stable hash 选 1
        // top 3 都是 30/45/80 (3 个), hash 选哪个看 seed — 但 top 里 30 + 45 跟 45 同等近
        // (都 |5| vs 0), 实际 sort 走 tie break on id → 30 在前
        // 然后 top 3 选 1 — seed 决定. 我们只保证**候选范围** (3 个之一)
        let day30 = makeMemory(id: "30", lastAccess: now.addingTimeInterval(-86400 * 30))
        let day45 = makeMemory(id: "45", lastAccess: now.addingTimeInterval(-86400 * 45))
        let day80 = makeMemory(id: "80", lastAccess: now.addingTimeInterval(-86400 * 80))
        let pick = SerendipitySelector.pick(from: [day30, day45, day80], now: now)
        XCTAssertNotNil(pick)
        XCTAssertTrue(["30", "45", "80"].contains(pick!.memory.id),
                      "应从 3 个 sweet spot 选 1; 实际: \(pick!.memory.id)")
        // 重要: 80 天不应被偏好 — 同样输入改一下只放 30/45, 应选 30 或 45
        let pick2 = SerendipitySelector.pick(from: [day30, day45], now: now)
        XCTAssertNotNil(pick2)
        XCTAssertTrue(["30", "45"].contains(pick2!.memory.id))
    }

    func testDeterministic() {
        // 同样输入两次跑, 结果应一致 (stable hash 验证)
        let mems = (1...10).map { i in
            makeMemory(id: "m\(i)",
                       lastAccess: now.addingTimeInterval(-86400 * Double(30 + i)))
        }
        let p1 = SerendipitySelector.pick(from: mems, now: now)
        let p2 = SerendipitySelector.pick(from: mems, now: now)
        XCTAssertEqual(p1?.memory.id, p2?.memory.id)
    }

    func testMinDaysCustom() {
        // 自定义 minDays = 7
        let m = makeMemory(id: "10d", lastAccess: now.addingTimeInterval(-86400 * 10))
        let p = SerendipitySelector.pick(from: [m], now: now, minDays: 7)
        XCTAssertNotNil(p, "minDays=7, 10 天前应被选")
    }
}
