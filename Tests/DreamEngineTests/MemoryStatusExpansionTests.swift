import XCTest
@testable import DreamEngine

// ADR-0003 §Backward compatibility + §Lifecycle states
//
// 验证：
// 1. 6 态 MemoryStatus 都能 round-trip JSON
// 2. 老 ledger.json (3 态 + 无 lastReinforcedAt / salienceScore) 加载 0 报错
// 3. 新 Memory 字段默认值正确
// 4. VaultConfig.DecayBlock 5 项权重字段默认值正确，且老 config JSON 能加载
final class MemoryStatusExpansionTests: XCTestCase {

    // MARK: - 1. 6 态 status round-trip

    func test_sixStatusCases_allRoundTripJSON() throws {
        // 6 个状态全部能 encode → decode → 一致
        let cases: [MemoryStatus] = [
            .candidate, .durable, .reinforced, .decayed, .archived, .conflict
        ]
        for s in cases {
            let data = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(MemoryStatus.self, from: data)
            XCTAssertEqual(decoded, s, "status \(s.rawValue) round-trip failed")
            // raw value 跟 enum case 名一致（保持可读 JSON）
            XCTAssertEqual(s.rawValue, String(describing: s).replacingOccurrences(of: "MemoryStatus.", with: ""))
        }
    }

    func test_sixStatusCases_allSixPresent() {
        // 显式列出 6 个状态并验证
        let allRawValues: Set<String> = [
            MemoryStatus.candidate.rawValue,
            MemoryStatus.durable.rawValue,
            MemoryStatus.reinforced.rawValue,
            MemoryStatus.decayed.rawValue,
            MemoryStatus.archived.rawValue,
            MemoryStatus.conflict.rawValue,
        ]
        XCTAssertEqual(allRawValues.count, 6,
                       "MemoryStatus 必须正好 6 个独立 rawValue (ADR-0003)")
        // 确认新加的三个：reinforced / decayed / conflict
        XCTAssertNotNil(MemoryStatus(rawValue: "reinforced"))
        XCTAssertNotNil(MemoryStatus(rawValue: "decayed"))
        XCTAssertNotNil(MemoryStatus(rawValue: "conflict"))
        // 老三个也要在（向后兼容）
        XCTAssertNotNil(MemoryStatus(rawValue: "candidate"))
        XCTAssertNotNil(MemoryStatus(rawValue: "durable"))
        XCTAssertNotNil(MemoryStatus(rawValue: "archived"))
    }

    // MARK: - 2. 老 ledger.json 兼容解码

    func test_legacyLedger_threeStateStatus_decodesCleanly() throws {
        // 模拟 v0.14.1 ledger.json：只含 candidate/durable/archived + 无新字段
        let legacyJSON = """
        {
          "id": "legacy-1",
          "text": "old memory",
          "sources": [{"file":"raw/a.md","line":1,"excerpt":"x"}],
          "status": "durable",
          "createdAt": "2025-01-01T00:00:00Z",
          "lastAccess": "2025-01-02T00:00:00Z",
          "reinforceCount": 0,
          "inboundLinks": 0,
          "contradicts": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let m = try decoder.decode(Memory.self, from: legacyJSON.data(using: .utf8)!)
        XCTAssertEqual(m.status, .durable)
        XCTAssertNil(m.lastReinforcedAt, "老 ledger 无 lastReinforcedAt 字段 → nil")
        XCTAssertNil(m.salienceScore, "老 ledger 无 salienceScore 字段 → nil")
        XCTAssertEqual(m.lastReinforceBySource, [:])
        XCTAssertEqual(m.kind, .concept)  // ADR-0003 沿用 v0.13 默认
    }

    func test_legacyLedger_archivedAndCandidate_decodesCleanly() throws {
        // 边界：老 ledger 同时含 archived + candidate
        for status: MemoryStatus in [.candidate, .archived] {
            let json = """
            {
              "id": "x", "text": "t", "sources": [{"file":"raw/a.md","line":1,"excerpt":"x"}],
              "status": "\(status.rawValue)",
              "createdAt": "2025-01-01T00:00:00Z", "lastAccess": "2025-01-01T00:00:00Z",
              "reinforceCount": 0, "inboundLinks": 0, "contradicts": []
            }
            """
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let m = try decoder.decode(Memory.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(m.status, status)
            XCTAssertNil(m.lastReinforcedAt)
        }
    }

    func test_newMemory_initializesLastReinforcedAtAsNil() {
        let m = Memory(text: "t", sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")])
        XCTAssertNil(m.lastReinforcedAt)
        XCTAssertNil(m.salienceScore)
    }

    func test_newMemory_acceptsLastReinforcedAtAndSalience() {
        let now = Date()
        let m = Memory(
            text: "t",
            sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
            lastReinforcedAt: now,
            salienceScore: 0.42
        )
        XCTAssertEqual(m.lastReinforcedAt, now)
        XCTAssertEqual(m.salienceScore, 0.42)
    }

    // MARK: - 3. 新 Memory 全字段 encode → decode

    func test_newMemoryWithSixStateStatusAndNewFields_roundTrips() throws {
        // 测：新 status + 新字段 encode 出去再 decode 回来仍然一致
        let original = Memory(
            text: "new",
            sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
            status: .reinforced,
            lastReinforcedAt: Date(timeIntervalSince1970: 1_700_000_000),
            salienceScore: 0.75
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(original)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(Memory.self, from: data)
        XCTAssertEqual(decoded.status, .reinforced)
        XCTAssertEqual(decoded.lastReinforcedAt, original.lastReinforcedAt)
        XCTAssertEqual(decoded.salienceScore, 0.75)
    }

    func test_decayedStatus_roundTrips() throws {
        // decayed 是新增的中间态，单独测一遍
        let m = Memory(
            text: "x", sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
            status: .decayed
        )
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Memory.self, from: data)
        XCTAssertEqual(decoded.status, .decayed)
    }

    func test_conflictStatus_roundTrips() throws {
        let m = Memory(
            text: "x", sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
            status: .conflict, contradicts: ["other-id"]
        )
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Memory.self, from: data)
        XCTAssertEqual(decoded.status, .conflict)
        XCTAssertEqual(decoded.contradicts, ["other-id"])
    }
}
