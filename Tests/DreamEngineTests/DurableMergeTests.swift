// P3-1: TextSimilarity + DurableMerge 单测
import XCTest
@testable import DreamEngine
import Foundation

final class TextSimilarityTests: XCTestCase {
    // MARK: - normalize

    func testNormalizeLowercase() {
        let out = TextSimilarity.normalize("Hello WORLD")
        XCTAssertEqual(out, "hello world")
    }

    func testNormalizeCollapseWhitespace() {
        let out = TextSimilarity.normalize("hello   \n\tworld")
        XCTAssertEqual(out, "hello world")
    }

    func testNormalizeStripsPunctuation() {
        let out = TextSimilarity.normalize("hello, world! 你好。")
        // 标点被去, CJK 保留
        XCTAssertTrue(out.contains("hello"))
        XCTAssertTrue(out.contains("world"))
        XCTAssertTrue(out.contains("你好"))
    }

    func testNormalizeChineseIntact() {
        let out = TextSimilarity.normalize("SwiftUI 用于 macOS 13+ 的桌面 UI 非常稳定")
        XCTAssertEqual(out, "swiftui 用于 macos 13 的桌面 ui 非常稳定")
    }

    // MARK: - jaccard

    func testJaccardIdentical() {
        let s = "SwiftUI 用于 macOS 13+ 桌面 UI"
        XCTAssertEqual(TextSimilarity.jaccard(s, s), 1.0, accuracy: 0.001)
    }

    func testJaccardDisjoint() {
        let a = "abcdef"
        let b = "xyz123"
        XCTAssertEqual(TextSimilarity.jaccard(a, b), 0.0, accuracy: 0.001)
    }

    func testJaccardPartial() {
        // 真正不同主题的短文本, sim 应 < 阈值 (不合并)
        // SwiftUI vs AppKit 共享 "用于 macos 桌面 ui" 算 0.5 — 算法上接受合并 (UI 框架同主题),
        // 设计原则: 文本短, 共享一半 trigrams 是真的相关, 合并不亏
        let a = "今天吃了苹果"
        let b = "明天要去跑步"
        let sim = TextSimilarity.jaccard(a, b)
        XCTAssertLessThan(sim, 0.3, "完全不同主题应 < 0.3, 实际: \(sim)")
    }

    func testJaccardSimilarEnough() {
        // 同一教训两次写, 措辞略不同, 应 >= 0.6 触发合并
        let a = "用 SwiftUI 写 macOS 13+ 桌面 UI 性能稳定"
        let b = "用 SwiftUI 写 macOS 13+ 桌面 UI 性能非常稳定"
        let sim = TextSimilarity.jaccard(a, b)
        XCTAssertGreaterThanOrEqual(sim, 0.6, "措辞略不同的同教训应 >= 0.6, 实际: \(sim)")
    }

    func testJaccardChineseSimilar() {
        let a = "raw 文件读写用 FileManager.default 比 Data 简洁"
        let b = "raw 文件读写用 FileManager.default 比 Data 写法更简洁"
        let sim = TextSimilarity.jaccard(a, b)
        XCTAssertGreaterThanOrEqual(sim, 0.6, "中文同质教训应 >= 0.6, 实际: \(sim)")
    }

    func testJaccardEmptyStrings() {
        XCTAssertEqual(TextSimilarity.jaccard("", ""), 1.0)
        XCTAssertEqual(TextSimilarity.jaccard("", "abc"), 0.0)
    }

    func testJaccardShortStrings() {
        // < 3 字符: 整个串当 1 个 trigram
        let sim = TextSimilarity.jaccard("ab", "ab")
        XCTAssertEqual(sim, 1.0)
    }
}

final class DurableMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func src(_ f: String) -> SourceRef {
        SourceRef(file: f, line: 1, excerpt: "excerpt")
    }
    private func makeMem(id: String, text: String, sources: [SourceRef],
                         status: MemoryStatus = .durable,
                         lastAccess: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Memory {
        Memory(id: id, text: text, sources: sources, status: status,
               createdAt: lastAccess, lastAccess: lastAccess)
    }

    func testEmptyInputs() {
        let r = DreamCycle.mergeSimilar(newAccepted: [], existing: [])
        XCTAssertTrue(r.newAccepted.isEmpty)
        XCTAssertEqual(r.mergeCount, 0)
        XCTAssertTrue(r.updatedExisting.isEmpty)
    }

    func testNoDurableToMerge() {
        // 没有 durable 时, mergeSimilar 跳过 (caller 自己在 front 加 candidate 互合)
        let m = makeMem(id: "n1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能稳定",
                        sources: [src("a.md")], status: .candidate)
        let r = DreamCycle.mergeSimilar(newAccepted: [m], existing: [m])
        XCTAssertEqual(r.newAccepted.count, 1, "candidate 不合并, 留在 newAccepted")
        XCTAssertEqual(r.mergeCount, 0)
        XCTAssertEqual(r.updatedExisting.count, 1)  // 没动
    }

    func testMergeIntoDurable() {
        // 现有 1 条 durable (1 source), 新条文本相似 → 应合并, source 数变 2
        let existing = makeMem(id: "d1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能稳定",
                               sources: [src("raw/a.md")])
        let newM = makeMem(id: "n1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能非常稳定",
                           sources: [src("raw/b.md")], status: .candidate)
        let r = DreamCycle.mergeSimilar(newAccepted: [newM], existing: [existing], now: now)
        XCTAssertEqual(r.mergeCount, 1)
        XCTAssertTrue(r.newAccepted.isEmpty, "被合并的新教训应从列表移除")
        XCTAssertEqual(r.updatedExisting[0].sources.count, 2, "现有 durable 应累加到 2 sources")
        XCTAssertEqual(r.updatedExisting[0].status, .durable, "合并后 status 保持 durable")
        XCTAssertEqual(r.updatedExisting[0].lastAccess, now)
        XCTAssertEqual(r.updatedExisting[0].reinforceCount, 1)  // 0 + 1
    }

    func testNoMergeBelowThreshold() {
        let existing = makeMem(id: "d1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能稳定",
                               sources: [src("a.md")])
        let newM = makeMem(id: "n1", text: "完全不同的内容, 关于 AppKit 性能对比",
                           sources: [src("b.md")])
        let r = DreamCycle.mergeSimilar(newAccepted: [newM], existing: [existing], now: now)
        XCTAssertEqual(r.mergeCount, 0)
        XCTAssertEqual(r.newAccepted.count, 1)  // 留在 newAccepted
        XCTAssertEqual(r.updatedExisting.count, 1)  // 没动 existing
    }

    func testMergeSameSourceNotDuplicated() {
        // 现有 + 新 都是同一个 file:line, 不应重复
        let existing = makeMem(id: "d1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能稳定",
                               sources: [src("raw/a.md")])
        let newM = makeMem(id: "n1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能非常稳定",
                           sources: [src("raw/a.md")])  // 同一 source
        let r = DreamCycle.mergeSimilar(newAccepted: [newM], existing: [existing], now: now)
        XCTAssertEqual(r.mergeCount, 1)
        XCTAssertEqual(r.updatedExisting[0].sources.count, 1, "同 file:line 去重, 仍 1 source")
    }

    func testPromotionFromCandidateToDurable() {
        // P3-1 限制: 只跟 durable 比. candidate 之间合并留给 P10+ 扩展
        // 这 case 拿个 existing = durable, 加 1 source 升级 durable 验一下
        let existing = makeMem(id: "d1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能稳定",
                               sources: [src("a.md")], status: .durable)
        let newM = makeMem(id: "n1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能非常稳定",
                           sources: [src("b.md")])
        let r = DreamCycle.mergeSimilar(newAccepted: [newM], existing: [existing], now: now)
        XCTAssertEqual(r.mergeCount, 1)
        XCTAssertEqual(r.updatedExisting[0].sources.count, 2)
        XCTAssertEqual(r.updatedExisting[0].status, .durable, "合并后仍 durable (升级已是 durable)")
    }

    func testMultipleMerges() {
        // 现有 1 条 durable, 新条 3 条: 1 条相似, 2 条不同
        // 调试: 打印 sim 看实际
        let existing = makeMem(id: "d1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能稳定",
                               sources: [src("a.md")])
        let sim1 = makeMem(id: "n1", text: "用 SwiftUI 写 macOS 13+ 桌面 UI 性能非常稳定",
                           sources: [src("b.md")])
        let diff1 = makeMem(id: "n2", text: "vault 用 Git 做版本控制 每次 dream 跑完 commit 写 .dream/ledger.json",
                           sources: [src("c.md")])
        let diff2 = makeMem(id: "n3", text: "KnowledgeGraph 算 Adamic-Adar 找相关记忆 加 wikilink 边更准",
                           sources: [src("d.md")])
        let sSim1 = TextSimilarity.jaccard(sim1.text, existing.text)
        let sDiff1 = TextSimilarity.jaccard(diff1.text, existing.text)
        let sDiff2 = TextSimilarity.jaccard(diff2.text, existing.text)
        print("DEBUG sim1=\(sSim1) diff1=\(sDiff1) diff2=\(sDiff2) threshold=\(TextSimilarity.mergeThreshold)")
        let r = DreamCycle.mergeSimilar(newAccepted: [sim1, diff1, diff2], existing: [existing], now: now)
        XCTAssertEqual(r.mergeCount, 1)
        XCTAssertEqual(r.newAccepted.count, 2, "sim1 被合并, diff1+diff2 保留")
        XCTAssertTrue(r.newAccepted.contains(where: { $0.id == "n2" }), "diff1 (id=n2) 保留")
        XCTAssertTrue(r.newAccepted.contains(where: { $0.id == "n3" }), "diff2 (id=n3) 保留")
    }

    /// 验收用例 (评审 §1.1): 同一教训分两晚, 应是 1 条 durable 2 sources
    /// P3-1 限制: 只跟 durable 比. night1 必须先升 durable (e.g. 2 sources 才能升), 才合
    func testAcceptance_TwoNightsOneDurable() async throws {
        // 模拟夜 1 已有 1 条 durable (2 sources, 已是 durable)
        // 用长文本 + 跟夜 2 高度重叠, 强制 sim >= 0.6
        let night1 = makeMem(id: "n1",
                             text: "用 NSTextStorage 监听 NSTextView 的 attribute 变化, 配合 NSAttributedString 做 wikilink 高亮是 macOS 13+ 桌面 UI 编辑器的标准做法",
                             sources: [src("raw/a.md"), src("raw/c.md")], status: .durable,
                             lastAccess: now.addingTimeInterval(-86400))
        // 夜 2 跑 dream, 生成 1 条新 candidate (新 id, 同主题, 长 + 大量重叠)
        let night2 = makeMem(id: "n2",
                             text: "用 NSTextStorage 监听 NSTextView 的 attribute 变化做 wikilink 高亮, 配合 NSAttributedString 是 macOS 13+ 桌面 UI 编辑器最自然的方案",
                             sources: [src("raw/b.md")], status: .candidate,
                             lastAccess: now)
        // 触发 mergeSimilar
        let result = DreamCycle.mergeSimilar(newAccepted: [night2], existing: [night1], now: now)
        // 验证: night2 合并到 night1, night1 sources 变 3 (a + c + b), 仍 durable
        XCTAssertEqual(result.mergeCount, 1, "夜 1+夜 2 文本重叠度应 >= 0.6 触发合并")
        XCTAssertTrue(result.newAccepted.isEmpty)
        XCTAssertEqual(result.updatedExisting.count, 1)
        let merged = result.updatedExisting[0]
        XCTAssertEqual(merged.sources.count, 3, "合并后 3 sources (a + c + b)")
        XCTAssertEqual(merged.status, .durable, "合并后保持 durable")
    }
}
