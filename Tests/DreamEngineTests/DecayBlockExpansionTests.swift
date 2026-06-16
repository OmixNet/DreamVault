import XCTest
@testable import DreamEngine

// ADR-0003 §Backward compatibility: VaultConfig.DecayBlock 加 5 项权重 + 6 态阈值
//
// 验证：
// 1. DecayBlock 默认值符合 ADR-0003 §决策（保守 under-archive 倾向）
// 2. 老 .dream/config.json (3 权重 + 无新字段) 加载 0 报错，新字段走默认
// 3. 新字段 encode → decode round-trip 一致
final class DecayBlockExpansionTests: XCTestCase {

    // MARK: - 1. 默认值

    func test_decayBlock_defaultWeightsMatchADR() {
        // ADR-0003 §决策: wSource=0.10, wUser=0.10, reinforcedDecayDays=14,
        // decayedSalienceThreshold=0.30 (高于 archiveSalienceThreshold=0.15 留中间态)
        let b = VaultConfig.DecayBlock()
        XCTAssertEqual(b.wRecency, 0.5, accuracy: 0.001)
        XCTAssertEqual(b.wFrequency, 0.3, accuracy: 0.001)
        XCTAssertEqual(b.wLinkage, 0.2, accuracy: 0.001)
        XCTAssertEqual(b.wSource, 0.10, accuracy: 0.001)
        XCTAssertEqual(b.wUser, 0.10, accuracy: 0.001)
        XCTAssertEqual(b.reinforcedDecayDays, 14.0, accuracy: 0.001)
        XCTAssertEqual(b.decayedSalienceThreshold, 0.30, accuracy: 0.001)
    }

    func test_decayBlock_decayedThresholdAboveArchiveThreshold() {
        // ADR-0003 §决策: decayedSalienceThreshold > archiveSalienceThreshold
        // 给"可观测的中间态"留 zone：durable > 0.30 → decayed 在 [0.15, 0.30] → archived < 0.15
        let b = VaultConfig.DecayBlock()
        XCTAssertGreaterThan(b.decayedSalienceThreshold, b.archiveSalienceThreshold,
            "decayed 阈值必须高于 archive 阈值，否则没有中间态可观测区")
    }

    // MARK: - 2. 老 config JSON 兼容

    func test_legacyConfigJSON_threeWeightsOnly_decodesCleanly() throws {
        // 模拟 v0.14.x .dream/config.json: 只有 3 个权重 + 无 wSource/wUser 等
        let legacyJSON = """
        {
          "wRecency": 0.4,
          "wFrequency": 0.4,
          "wLinkage": 0.2,
          "tauDays": 30,
          "kFrequency": 5,
          "lLinkage": 8,
          "archiveSalienceThreshold": 0.15,
          "archiveStaleDays": 90
        }
        """
        let decoded = try JSONDecoder().decode(
            VaultConfig.DecayBlock.self,
            from: legacyJSON.data(using: .utf8)!
        )
        // 老字段保留用户值
        XCTAssertEqual(decoded.wRecency, 0.4, accuracy: 0.001)
        XCTAssertEqual(decoded.wFrequency, 0.4, accuracy: 0.001)
        XCTAssertEqual(decoded.wLinkage, 0.2, accuracy: 0.001)
        // 新字段走默认（保守 under-archive 倾向）
        XCTAssertEqual(decoded.wSource, 0.10, accuracy: 0.001)
        XCTAssertEqual(decoded.wUser, 0.10, accuracy: 0.001)
        XCTAssertEqual(decoded.reinforcedDecayDays, 14.0, accuracy: 0.001)
        XCTAssertEqual(decoded.decayedSalienceThreshold, 0.30, accuracy: 0.001)
    }

    func test_newDecayBlockWithAllFields_roundTrips() throws {
        // 测：新字段全部 encode → decode 一致
        let original = VaultConfig.DecayBlock(
            wRecency: 0.4, wFrequency: 0.3, wLinkage: 0.1,
            tauDays: 45, kFrequency: 4, lLinkage: 10,
            archiveSalienceThreshold: 0.10, archiveStaleDays: 120,
            wSource: 0.15, wUser: 0.05,
            reinforcedDecayDays: 21, decayedSalienceThreshold: 0.40
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VaultConfig.DecayBlock.self, from: data)
        XCTAssertEqual(decoded.wSource, 0.15, accuracy: 0.001)
        XCTAssertEqual(decoded.wUser, 0.05, accuracy: 0.001)
        XCTAssertEqual(decoded.reinforcedDecayDays, 21.0, accuracy: 0.001)
        XCTAssertEqual(decoded.decayedSalienceThreshold, 0.40, accuracy: 0.001)
        // 老字段也对
        XCTAssertEqual(decoded.wRecency, 0.4, accuracy: 0.001)
        XCTAssertEqual(decoded.archiveSalienceThreshold, 0.10, accuracy: 0.001)
    }

    func test_fullVaultConfig_saveLoadWithNewFields() throws {
        // 端到端: 整个 VaultConfig 走 loader (写默认 → 读回 → 新字段在)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfg = try DreamConfigLoader.load(vaultRoot: tmp, writeDefaultIfMissing: true)
        XCTAssertEqual(cfg.decay.wSource, 0.10, accuracy: 0.001)
        XCTAssertEqual(cfg.decay.wUser, 0.10, accuracy: 0.001)
        XCTAssertEqual(cfg.decay.reinforcedDecayDays, 14.0, accuracy: 0.001)
        XCTAssertEqual(cfg.decay.decayedSalienceThreshold, 0.30, accuracy: 0.001)

        // 再读一次，验证写盘后能 round-trip
        let cfg2 = try DreamConfigLoader.load(vaultRoot: tmp, writeDefaultIfMissing: false)
        XCTAssertEqual(cfg2.decay.wSource, 0.10, accuracy: 0.001)
    }
}
