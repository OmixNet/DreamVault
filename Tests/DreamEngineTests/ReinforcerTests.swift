import XCTest
@testable import DreamEngine

/// P9c-P0-2: 覆盖 Reinforcer 的核心语义：
///   1. 首次 reinforce +1
///   2. 同 day 同 source 不重复 +1（防抖）
///   3. 跨 day 重新 +1
///   4. 同 day 不同 source 分别 +1
///   5. candidate 不强化
///   6. 落盘 → 重载 → 计数保留
///   7+. 额外：archived 仍可强化 / memoryID 解析工具 / 老 ledger 兼容
@MainActor
final class ReinforcerTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dreamvault-reinforcer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempDir = tmp
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    // MARK: - 工具

    /// 准备一条 memory 并把它写进 ledger（让 Reinforcer init 时能加载）
    private func seedMemory(id: String = "m-1",
                            status: MemoryStatus = .durable,
                            at date: Date = Date()) throws {
        let mem = Memory(
            id: id,
            text: "seed \(id)",
            sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
            status: status,
            createdAt: date,
            lastAccess: date,
            reinforceCount: 0
        )
        let ledger = Ledger(memories: [mem])
        try Persister.saveLedger(ledger, vaultRoot: tempDir)
    }

    // MARK: - 1. 首次 reinforce +1

    func testReinforce_firstTime_increments() throws {
        try seedMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r = Reinforcer(vaultRoot: tempDir)
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: now),
                      "首次 reinforce 应生效")
        XCTAssertEqual(r.lastReinforceCount, 1)
        // 落盘后 reload，确认 ledger 真的变了
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories.count, 1)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 1)
        XCTAssertEqual(reloaded.memories[0].lastAccess, now)
    }

    // MARK: - 2. 同 day 同 source 不重复 +1

    func testReinforce_sameDaySameSource_noDoubleCount() throws {
        try seedMemory()
        let r = Reinforcer(vaultRoot: tempDir)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let later = day.addingTimeInterval(3600 * 4)  // 同一天，4 小时后
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: day))
        XCTAssertFalse(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: later),
                       "同 source 同 day 应被防抖掉")
        XCTAssertEqual(r.lastReinforceCount, 1)
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 1,
                       "防抖掉时不应改变落盘的计数")
    }

    // MARK: - 3. 跨 day 重新 +1

    func testReinforce_nextDay_countsAgain() throws {
        try seedMemory()
        let r = Reinforcer(vaultRoot: tempDir)
        // 起始：2023-11-14 10:00
        var day1 = DateComponents()
        day1.year = 2023; day1.month = 11; day1.day = 14; day1.hour = 10
        let cal = Calendar(identifier: .gregorian)
        let d1 = cal.date(from: day1)!
        // 第二天 2023-11-15 09:00
        var day2 = day1; day2.day = 15; day2.hour = 9
        let d2 = cal.date(from: day2)!
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: d1))
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: d2),
                      "跨 day 应再 +1")
        XCTAssertEqual(r.lastReinforceCount, 2)
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 2)
    }

    // MARK: - 4. 同 day 不同 source 分别 +1

    func testReinforce_differentSource_countsSeparately() throws {
        try seedMemory()
        let r = Reinforcer(vaultRoot: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: now))
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .searchClick, now: now),
                      "不同 source 不互防抖")
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .dreamReference, now: now))
        XCTAssertEqual(r.lastReinforceCount, 3)
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 3)
        // 每个 source 的最后一次 reinforce 日期都被记录
        let bySource = reloaded.memories[0].lastReinforceBySource
        XCTAssertNotNil(bySource[ReinforceSource.wikiOpen.rawValue])
        XCTAssertNotNil(bySource[ReinforceSource.searchClick.rawValue])
        XCTAssertNotNil(bySource[ReinforceSource.dreamReference.rawValue])
    }

    // MARK: - 5. candidate 不强化

    func testReinforce_candidateNotReinforced() throws {
        try seedMemory(id: "m-1", status: .candidate)
        let r = Reinforcer(vaultRoot: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: now),
                       "candidate 状态不应被强化（spec：单源观察不算被确认）")
        XCTAssertEqual(r.lastReinforceCount, 0)
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 0,
                       "candidate 不应有任何计数变化落盘")
        XCTAssertTrue(reloaded.memories[0].lastReinforceBySource.isEmpty,
                      "candidate 不应写 lastReinforceBySource")
    }

    // MARK: - 6. 落盘 → 重载 → 计数保留

    func testReinforce_persistence_roundTrip() throws {
        try seedMemory()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let r1 = Reinforcer(vaultRoot: tempDir)
            XCTAssertTrue(r1.reinforce(memoryID: "m-1", source: .wikiOpen, now: day))
            XCTAssertTrue(r1.reinforce(memoryID: "m-1", source: .searchClick, now: day))
        }
        // 重新构造一个 Reinforcer（模拟进程重启）→ 应能加载到前一次强化计数
        let r2 = Reinforcer(vaultRoot: tempDir)
        // 重载后再次 reinforce 应被防抖（同 day 同 source）
        XCTAssertFalse(r2.reinforce(memoryID: "m-1", source: .wikiOpen, now: day),
                       "重启后同 day 同 source 应仍被防抖（lastReinforceBySource 已落盘）")
        XCTAssertFalse(r2.reinforce(memoryID: "m-1", source: .searchClick, now: day),
                       "重启后 searchClick 同 day 应仍被防抖")
        // 落盘计数应仍是 2（防抖掉时不应改 ledger）
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 2,
                       "重载 Reinforcer 后 ledger 计数应仍是 2")
    }

    // MARK: - 7+. 额外

    func testReinforce_archivedStillCounts() throws {
        try seedMemory(status: .archived)
        let r = Reinforcer(vaultRoot: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(r.reinforce(memoryID: "m-1", source: .wikiOpen, now: now),
                      "archived 不应被防抖掉（它仍然存在于 ledger）")
    }

    func testReinforce_unknownMemoryID_returnsFalse() throws {
        let r = Reinforcer(vaultRoot: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(r.reinforce(memoryID: "nope", source: .wikiOpen, now: now),
                       "不存在的 id 应直接 false，不应崩")
    }

    func testMemoryID_forVaultRelPath() {
        XCTAssertEqual(Reinforcer.memoryID(forVaultRelPath: "wiki/concepts/abc-123.md"),
                       "abc-123")
        XCTAssertEqual(Reinforcer.memoryID(forVaultRelPath: "wiki/entities/foo.md"), "foo")
        XCTAssertEqual(Reinforcer.memoryID(forVaultRelPath: "wiki/syntheses/bar.md"), "bar")
        XCTAssertEqual(Reinforcer.memoryID(forVaultRelPath: "wiki/archive/old.md"), "old")
        // 非 wiki 路径 → nil
        XCTAssertNil(Reinforcer.memoryID(forVaultRelPath: "raw/x.md"))
        XCTAssertNil(Reinforcer.memoryID(forVaultRelPath: "MEMORY.md"))
        XCTAssertNil(Reinforcer.memoryID(forVaultRelPath: "wiki/concepts/"))
        XCTAssertNil(Reinforcer.memoryID(forVaultRelPath: "wiki/concepts/noext"))
    }

    func testLastReinforceBySource_decoderBackwardCompat() throws {
        // 模拟 P9c-P0-2 之前写下的老 ledger：没有 lastReinforceBySource 字段
        let old = """
        {
          "id": "old",
          "text": "t",
          "sources": [{"file":"raw/a.md","line":1,"excerpt":"x"}],
          "status": "durable",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastAccess": "2026-01-01T00:00:00Z",
          "reinforceCount": 0,
          "inboundLinks": 0,
          "contradicts": []
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let m = try dec.decode(Memory.self, from: Data(old.utf8))
        XCTAssertTrue(m.lastReinforceBySource.isEmpty,
                      "老 ledger 缺 lastReinforceBySource 应解码为空 dict")
    }

    // MARK: - 8+. bulk helper (DreamCycle 调用)

    func testReinforceBySourceFiles_boostsExistingDurable() throws {
        // 准备：durable m-1 引用 raw/a.md，candidate m-2 也引用 raw/a.md，durable m-3 引用 raw/b.md
        let m1 = Memory(id: "m-1", text: "t1",
                        sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                        status: .durable)
        let m2 = Memory(id: "m-2", text: "t2",
                        sources: [SourceRef(file: "raw/a.md", line: 2, excerpt: "y")],
                        status: .candidate)
        let m3 = Memory(id: "m-3", text: "t3",
                        sources: [SourceRef(file: "raw/b.md", line: 1, excerpt: "z")],
                        status: .durable)
        try Persister.saveLedger(Ledger(memories: [m1, m2, m3]), vaultRoot: tempDir)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hit = Reinforcer.reinforceBySourceFiles(["raw/a.md"], vaultRoot: tempDir, now: now)
        XCTAssertEqual(hit.sorted(), ["m-1"],
                       "durable m-1 命中；candidate m-2 不命中；m-3 引用 b.md 不命中")
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories.first { $0.id == "m-1" }?.reinforceCount, 1)
        XCTAssertEqual(reloaded.memories.first { $0.id == "m-2" }?.reinforceCount, 0,
                       "candidate 不应被 bulk 强化")
        XCTAssertEqual(reloaded.memories.first { $0.id == "m-3" }?.reinforceCount, 0,
                       "未共享 raw 源的不应被强化")
    }

    func testReinforceBySourceFiles_perDayDebounce() throws {
        let m1 = Memory(id: "m-1", text: "t",
                        sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                        status: .durable)
        try Persister.saveLedger(Ledger(memories: [m1]), vaultRoot: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = now.addingTimeInterval(3600)
        let h1 = Reinforcer.reinforceBySourceFiles(["raw/a.md"], vaultRoot: tempDir, now: now)
        let h2 = Reinforcer.reinforceBySourceFiles(["raw/a.md"], vaultRoot: tempDir, now: later)
        XCTAssertEqual(h1, ["m-1"])
        XCTAssertTrue(h2.isEmpty, "同 day 应被防抖掉")
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 1)
    }

    func testReinforceBySourceFiles_emptyInput_noop() throws {
        let m1 = Memory(id: "m-1", text: "t",
                        sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                        status: .durable)
        try Persister.saveLedger(Ledger(memories: [m1]), vaultRoot: tempDir)
        let hit = Reinforcer.reinforceBySourceFiles([], vaultRoot: tempDir)
        XCTAssertTrue(hit.isEmpty)
        let reloaded = Persister.loadLedger(vaultRoot: tempDir)
        XCTAssertEqual(reloaded.memories[0].reinforceCount, 0,
                       "空输入不应改 ledger")
    }
}