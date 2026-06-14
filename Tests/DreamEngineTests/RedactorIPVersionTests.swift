import XCTest
@testable import DreamEngine

/// P2 修复 (缺陷报告 §3.2) 测试: IP_ADDR 4 段版本号不再误判.
/// 验证:
/// - 老 4 段版本号 (1.0.0.0, 2.4.15.1) 在 "version" / "v" / "版本" 前缀下不脱敏
/// - 真 IP (192.168.1.1, 10.0.0.1) 仍正常脱敏
/// - 边界: 5 段 OID 仍防, 5+ 段 OID 仍防, 嵌套 OID 仍防
/// - 反向: 没前缀的 4 段 (1.0.0.0) 仍脱敏 (防止过度放宽)
final class RedactorIPVersionTests: XCTestCase {

    // MARK: - 版本号前置词不脱敏

    /// 1. "version 1.0.0.0" 不脱敏 (英文 version)
    func testVersionPrefix_version_1_0_0_0_notRedacted() {
        let r = Redactor().redact("App updated to version 1.0.0.0 today")
        XCTAssertFalse(r.hadSensitive, "version 1.0.0.0 是版本号, 不应脱敏")
        XCTAssertEqual(r.redactedText, "App updated to version 1.0.0.0 today")
    }

    /// 2. "Version" 大写
    func testVersionPrefix_Version_capitalized() {
        let r = Redactor().redact("Version 2.4.15.1 release")
        XCTAssertFalse(r.hadSensitive, "Version 大写也应跳过")
    }

    /// 3. "v1.0.0.0" 不脱敏 (v 前缀)
    func testVersionPrefix_v_lowercase() {
        let r = Redactor().redact("Build v1.0.0.0 on 2026-06-14")
        XCTAssertFalse(r.hadSensitive, "v1.0.0.0 是版本号, 不应脱敏")
    }

    /// 4. "v0.5.0.0" 不脱敏 (v + 数字 0)
    func testVersionPrefix_v0() {
        let r = Redactor().redact("dreamvault v0.5.0.0 ships")
        XCTAssertFalse(r.hadSensitive, "v0.5.0.0 应跳过")
    }

    /// 5. "v9.9.9.9" 不脱敏 (v + 数字 9, 上限测试)
    func testVersionPrefix_v9() {
        let r = Redactor().redact("released v9.9.9.9 today")
        XCTAssertFalse(r.hadSensitive, "v9.9.9.9 应跳过")
    }

    /// 6. "版本 1.4.15.2" 不脱敏 (中文)
    func testVersionPrefix_chinese() {
        let r = Redactor().redact("App 更新到了版本 1.4.15.2")
        XCTAssertFalse(r.hadSensitive, "中文版本号应跳过")
    }

    /// 7. "版本号 1.4.15.2" 不脱敏 (中文长前缀)
    func testVersionPrefix_chinese_long() {
        let r = Redactor().redact("当前版本号 1.4.15.2")
        XCTAssertFalse(r.hadSensitive, "中文版本号长前缀应跳过")
    }

    /// 8. "Build 1.0.0.0" 不脱敏
    func testVersionPrefix_build() {
        let r = Redactor().redact("Build 1.0.0.0 release")
        XCTAssertFalse(r.hadSensitive, "Build 前缀应跳过")
    }

    /// 9. "build-1.0.0.0" 不脱敏 (带连字符)
    func testVersionPrefix_build_dash() {
        let r = Redactor().redact("container build-1.0.0.0 tag")
        XCTAssertFalse(r.hadSensitive, "build- 前缀应跳过")
    }

    // MARK: - 真 IP 仍脱敏

    /// 10. 真 IP 192.168.1.1 仍脱敏
    func testRealIP_192_168_1_1_stillRedacted() {
        let r = Redactor().redact("Server at 192.168.1.1")
        XCTAssertTrue(r.hadSensitive, "真 IP 应脱敏")
        XCTAssertTrue(r.redactedText.contains("[REDACTED_IP_ADDR]"))
    }

    /// 11. 真 IP 10.0.0.1 仍脱敏
    func testRealIP_10_0_0_1_stillRedacted() {
        let r = Redactor().redact("gateway 10.0.0.1")
        XCTAssertTrue(r.hadSensitive)
    }

    /// 12. 公网 IP 8.8.8.8 仍脱敏
    func testRealIP_8_8_8_8_stillRedacted() {
        let r = Redactor().redact("DNS 8.8.8.8")
        XCTAssertTrue(r.hadSensitive)
    }

    /// 13. 多 IP 仍脱敏
    func testMultipleIPs_allRedacted() {
        let r = Redactor().redact("frontend 10.0.0.1 backend 10.0.0.2")
        XCTAssertEqual(r.counts["IP_ADDR"], 2)
    }

    // MARK: - 边界: 5+ 段 OID 仍防

    /// 14. 5 段 OID 1.2.3.4.5 不脱敏 (老 P3 修复)
    func testOID_5segments_notRedacted() {
        let r = Redactor().redact("OID 1.2.3.4.5 in certificate")
        XCTAssertFalse(r.hadSensitive, "5 段 OID 不应误判为 IP")
    }

    /// 15. 6 段 OID 1.2.3.4.5.6 也不脱敏
    func testOID_6segments_notRedacted() {
        let r = Redactor().redact("ISO 1.2.3.4.5.6 standard")
        XCTAssertFalse(r.hadSensitive, "6 段 OID 不应误判")
    }

    // MARK: - 反向: 没前缀的 4 段仍脱敏 (防过度放宽)

    /// 16. 没前缀的 1.0.0.0 仍脱敏 (防过度放宽)
    func testNoPrefix_1_0_0_0_stillRedacted() {
        let r = Redactor().redact("the address 1.0.0.0")
        XCTAssertTrue(r.hadSensitive, "无前缀 1.0.0.0 仍应脱敏 (可能 IP)")
    }

    /// 17. 没前缀的 4 段 (中间有空格) 仍脱敏
    func testNoPrefix_4segment_padded() {
        let r = Redactor().redact("configure 100.200.50.1 in settings")
        XCTAssertTrue(r.hadSensitive)
    }

    // MARK: - 嵌套 OID 不误判 (老 P3 修复仍生效)

    /// 18. 嵌套 5 段中内嵌 4 段: 1.2.3.4.5 含 2.3.4.5 → 5 段防, 4 段嵌套不该误判
    /// 5 段整体: (?<!\d\.) 防止 1.2.3.4.5 拆 5 次匹配 (每次 4 段)
    func testNested_5segmentOID_doesNotMatchSubset() {
        let r = Redactor().redact("OID: 1.2.3.4.5")
        XCTAssertFalse(r.hadSensitive, "5 段 OID 整体不脱敏 (内嵌 4 段也不单独脱敏)")
    }

    // MARK: - 不破坏其他规则

    /// 19. IP + version 同时出现, 各自处理
    func testMixed_IP_and_version() {
        let r = Redactor().redact("server 10.0.0.1 runs version 1.0.0.0")
        XCTAssertEqual(r.counts["IP_ADDR"] ?? 0, 1, "IP 脱敏 1 次")
        XCTAssertTrue(r.redactedText.contains("[REDACTED_IP_ADDR]"))
        XCTAssertTrue(r.redactedText.contains("version 1.0.0.0"), "version 1.0.0.0 不脱敏")
    }

    /// 20. 5 段 OID + version 同时出现
    func testMixed_OID_and_version() {
        let r = Redactor().redact("OID 1.2.3.4.5, version 2.0.0.0")
        XCTAssertFalse(r.hadSensitive, "5 段 OID + 4 段版本号都不脱敏")
    }
}
