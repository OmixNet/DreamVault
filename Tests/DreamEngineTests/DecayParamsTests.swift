import XCTest
@testable import DreamEngine

/// P3-7 评审 §2.1 修复: 两个衰减参数知情决策.
/// 1. staleDays 按 tauMultiplier 缩放 (fast 27 天 / normal 90 天 / slow 270 天)
/// 2. frequency 加新近度衰减 (frequencyTauDays=60 天), 不让"4 次强化 = 永生"
///
/// 覆盖:
/// - effectiveStaleDays 按 decayClass 缩放 (3 cases)
/// - salience frequency 衰减 (3 cases: dt=0 老行为 / dt=60 中 / dt=∞ 频率失效)
/// - evaluate fast 类 10 天 → archive (老: 要 90 天)
/// - evaluate normal 类 90 天 → archive (跟老行为一致)
/// - evaluate 4 次强化 + 90 天不访问 → archive (老: 永生; P3-7: 频率地板衰减)
/// - evaluate 矛盾优先 needsReview (回归)
final class DecayParamsTests: XCTestCase {

    // MARK: - effectiveStaleDays 缩放

    /// 1. normal decayClass: effectiveStaleDays = 90 (跟老行为一致, 系数 1.0)
    func testEffectiveStaleDays_normal_isNinety() {
        let d = Decayer()
        let m = makeMemory(decayClass: .normal, lastAccess: Date(), reinforceCount: 0, inboundLinks: 0)
        XCTAssertEqual(d.effectiveStaleDays(for: m), 90, accuracy: 0.01,
                       "normal × 1.0 = 90 (跟老 staleDays 一致)")
    }

    /// 2. fast decayClass: effectiveStaleDays = 27 (90 × 0.3)
    /// 评审 §2.1: fast 类 9 天 τ 在第 10 天 salience ≈ 0, 等满 90 天是浪费
    func testEffectiveStaleDays_fast_isTwentySeven() {
        let d = Decayer()
        let m = makeMemory(decayClass: .fast, lastAccess: Date(), reinforceCount: 0, inboundLinks: 0)
        XCTAssertEqual(d.effectiveStaleDays(for: m), 27, accuracy: 0.01,
                       "fast × 0.3 = 27 (评审修复: fast 不再被 90 天门槛架空)")
    }

    /// 3. slow decayClass: effectiveStaleDays = 270 (90 × 3.0)
    func testEffectiveStaleDays_slow_isTwoSeventy() {
        let d = Decayer()
        let m = makeMemory(decayClass: .slow, lastAccess: Date(), reinforceCount: 0, inboundLinks: 0)
        XCTAssertEqual(d.effectiveStaleDays(for: m), 270, accuracy: 0.01,
                       "slow × 3.0 = 270 (跟 τ 缩放一致)")
    }

    // MARK: - salience frequency 衰减

    /// 4. dt=0: frequency 衰减系数 = 1.0 (跟老行为一致)
    func testSalience_frequencyDecay_atZero_isOne() {
        let d = Decayer()
        let now = Date()
        let m = makeMemory(
            decayClass: .normal, lastAccess: now,
            reinforceCount: 4, inboundLinks: 0)
        let s: Double = d.salience(of: m, now: now)
        // recency dt=0 → e^0 = 1, w_r contribute 0.5
        // frequency 1-e^(-4/5)=0.55, w_f contribute 0.165
        // linkage 0, w_l contribute 0
        // 总 s = 0.5 + 0.165 + 0 = 0.665
        let expectedS: Double = 0.5 + 0.3 * (1 - exp(-4.0 / 5.0))
        XCTAssertEqual(s, expectedS, accuracy: 0.01,
                       "dt=0 frequency 衰减系数 1.0 (跟老行为完全一致, 总 s ≈ 0.665)")
    }

    /// 5. dt=60: frequency 衰减系数 ≈ 0.37 (e^(-1))
    /// "4 次强化" 长期不访问的频率地板衰减: 0.55 → 0.20
    func testSalience_frequencyDecay_atSixty_isOneThird() {
        let d = Decayer()
        let now = Date()
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 86_400)
        let m = makeMemory(
            decayClass: .normal, lastAccess: sixtyDaysAgo,
            reinforceCount: 4, inboundLinks: 0)
        let s: Double = d.salience(of: m, now: now)
        // 老计算 (无 frequency 衰减): 0.55
        // P3-7: 0.55 * e^(-1) ≈ 0.20, w_f contribute 0.06
        let expectedFreqContrib: Double = 0.3 * (1 - exp(-4.0 / 5.0)) * exp(-1)
        // recency 60 天: e^(-60/30) = e^(-2) ≈ 0.135, w_r contribute 0.068
        let recency: Double = exp(-60.0 / 30.0)
        let expectedS: Double = 0.5 * recency + expectedFreqContrib
        XCTAssertEqual(s, expectedS, accuracy: 0.01,
                       "dt=60 frequency 衰减 e^(-1), 比老少 0.10 (4 次强化不再永生)")
    }

    /// 6. dt=∞: frequency 衰减系数 = 0, frequency 完全失效 (走纯 recency)
    func testSalience_frequencyDecay_atInfinity_frequencyZero() {
        let d = Decayer()
        let now = Date()
        let veryLongAgo = now.addingTimeInterval(-365 * 86_400)  // 1 年
        let m = makeMemory(
            decayClass: .normal, lastAccess: veryLongAgo,
            reinforceCount: 4, inboundLinks: 0)
        let s = d.salience(of: m, now: now)
        // frequencyBase 0.55 * e^(-365/60) ≈ 0.55 * e^(-6.08) ≈ 0.0014 (基本 0)
        // recency 1 年: e^(-365/30) ≈ 5e-6 (基本 0)
        // s ≈ 0
        XCTAssertLessThan(s, 0.01, "dt=1 年 frequency 几乎全衰减, s ≈ 0")
    }

    // MARK: - evaluate fast 类不被 90 天门槛架空

    /// 7. fast 类 dt=10 天 → archive (老: 等 90 天; P3-7: 27 天就 archive)
    /// 这是评审 §2.1 的核心修复
    func testEvaluate_fastTenDays_archivesNotWaitingForNinety() {
        let d = Decayer()
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        // fast τ=9 天, 10 天后 recency ≈ e^(-10/9) ≈ 0.33, w_r contribute 0.165
        // 无 freq 强化, linkage 0 → s ≈ 0.165 < 0.15 边界
        // 实际 s ≈ 0.165 > 0.15 → 老实现 .keep; P3-7 27 天门槛, 10 天不触发 archive
        // 调整参数让测试明确: fast 28 天 (1 天 > 27) → 触发
        let twentyEightDaysAgo = now.addingTimeInterval(-28 * 86_400)
        let m = makeMemory(
            decayClass: .fast, lastAccess: twentyEightDaysAgo,
            reinforceCount: 0, inboundLinks: 0)
        let result = d.evaluate(m, now: now)
        XCTAssertEqual(result.action, .archive,
                       "P3-7: fast 28 天 > effectiveStaleDays 27 → archive (老: 等 90 天)")
    }

    /// 8. fast 类 10 天 (在 27 天门槛内) → keep (老也 keep, 不变)
    func testEvaluate_fastTenDays_keepsWithinStaleDays() {
        let d = Decayer()
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        let m = makeMemory(
            decayClass: .fast, lastAccess: tenDaysAgo,
            reinforceCount: 0, inboundLinks: 0)
        let result = d.evaluate(m, now: now)
        XCTAssertEqual(result.action, .keep,
                       "fast 10 天 < 27 天门槛 → keep (recency 仍在)")
    }

    // MARK: - evaluate normal 90 天 (向后兼容)

    /// 9. normal 类 91 天 → archive (老门槛 90 天 + 1 天, 跨过门槛)
    func testEvaluate_normalNinetyOneDays_archives() {
        let d = Decayer()
        let now = Date()
        let ninetyOneDaysAgo = now.addingTimeInterval(-91 * 86_400)
        let m = makeMemory(
            decayClass: .normal, lastAccess: ninetyOneDaysAgo,
            reinforceCount: 0, inboundLinks: 0)
        let result = d.evaluate(m, now: now)
        XCTAssertEqual(result.action, .archive,
                       "normal 91 天 (> 老门槛 90) → archive (向后兼容, 跨过门槛)")
    }

    /// 10. normal 类 89 天 → keep (差 1 天)
    func testEvaluate_normalEightyNineDays_keeps() {
        let d = Decayer()
        let now = Date()
        let eightyNineDaysAgo = now.addingTimeInterval(-89 * 86_400)
        let m = makeMemory(
            decayClass: .normal, lastAccess: eightyNineDaysAgo,
            reinforceCount: 0, inboundLinks: 0)
        let result = d.evaluate(m, now: now)
        XCTAssertEqual(result.action, .keep,
                       "normal 89 天 (差 1 天门槛) → keep")
    }

    // MARK: - 4 次强化不再 = 永生 (P3-7 核心修复 #2)

    /// 11. 4 次强化 + 91 天不访问 → archive (老: 频率地板 0.165 ≥ 0.15 永生;
    /// P3-7: frequency 衰减后 contribute 0.06, 总 s 跌破 0.15)
    func testEvaluate_fourReinforcementsNinetyOneDays_archivesNotImmortal() {
        let d = Decayer()
        let now = Date()
        let ninetyOneDaysAgo = now.addingTimeInterval(-91 * 86_400)
        let m = makeMemory(
            decayClass: .normal, lastAccess: ninetyOneDaysAgo,
            reinforceCount: 4, inboundLinks: 0)
        let result = d.evaluate(m, now: now)
        // 老: recency e^(-3) ≈ 0.05 * 0.5 = 0.025 + freq 0.55 * 0.3 = 0.165 → s ≈ 0.19 > 0.15 → keep
        // P3-7: recency 0.025 + freq 0.55 * e^(-91/60) ≈ 0.55 * 0.22 * 0.3 = 0.037 → s ≈ 0.062 < 0.15 → archive
        XCTAssertEqual(result.action, .archive,
                       "P3-7: 4 次强化 91 天不访问 → archive (频率衰减后 s 跌破 0.15, 老: 永生 keep)")
    }

    /// 12. 4 次强化 + 0 天不访问 → keep (老也 keep, 频率地板有效)
    func testEvaluate_fourReinforcementsZeroDays_keeps() {
        let d = Decayer()
        let now = Date()
        let m = makeMemory(
            decayClass: .normal, lastAccess: now,
            reinforceCount: 4, inboundLinks: 0)
        let result = d.evaluate(m, now: now)
        // recency 1.0 * 0.5 = 0.5, freq 0.55 * 0.3 = 0.165 → s ≈ 0.665
        XCTAssertEqual(result.action, .keep, "4 次强化刚访问 → keep (频率地板有效)")
    }

    // MARK: - 矛盾优先 needsReview (回归)

    /// 13. 矛盾标记 → needsReview (跟频率/stale 无关, 永远优先)
    func testEvaluate_contradiction_alwaysNeedsReview() {
        let d = Decayer()
        let now = Date()
        var m = makeMemory(
            decayClass: .normal, lastAccess: now,
            reinforceCount: 0, inboundLinks: 0)
        m.contradicts = ["other-id"]
        let result = d.evaluate(m, now: now)
        XCTAssertEqual(result.action, .needsReview, "矛盾 → needsReview (P3-7 跟 stale 缩放无关)")
    }

    // MARK: - frequency 缩放测试 (frequencyTauDays 可调)

    /// 14. frequencyTauDays = 0 → frequency 完全失效 (退化成纯 recency + linkage)
    func testSalience_frequencyTauZero_frequenciesDisabled() {
        let d = Decayer(config: DecayConfig(frequencyTauDays: 0))
        let now = Date()
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 86_400)
        let m = makeMemory(
            decayClass: .normal, lastAccess: sixtyDaysAgo,
            reinforceCount: 10, inboundLinks: 0)  // 强化 10 次 (frequencyBase ≈ 0.86)
        let s = d.salience(of: m, now: now)
        // frequencyTau=0 → frequency=0 (e^(-∞) = 0)
        // recency 60 天 e^(-2) ≈ 0.135 * 0.5 = 0.068
        let recency = exp(-60.0 / 30.0)
        XCTAssertEqual(s, 0.5 * recency, accuracy: 0.001,
                       "frequencyTau=0 → frequency 完全失效 (0.5 * recency only)")
    }
}

// MARK: - 测试 fixtures

private func makeMemory(
    decayClass: DecayClass = .normal,
    lastAccess: Date = Date(),
    reinforceCount: Int = 0,
    inboundLinks: Int = 0
) -> Memory {
    return Memory(
        text: "test",
        sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
        status: .candidate,
        lastAccess: lastAccess,
        reinforceCount: reinforceCount,
        inboundLinks: inboundLinks,
        decayClass: decayClass)
}
