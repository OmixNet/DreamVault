import XCTest
@testable import DreamEngine

/// P3-4 评审 §2.6 修复: Gatherer 按 markdown 标题分块, 真实化 sourceLine + excerpt
/// 防 Ollama num_ctx 静默截断. 覆盖:
/// - chunkBody 按 `## ` split + 超 maxChars 强制切
/// - annotateChunksWithLineNumbers 行号偏移 (1-based)
/// - gather() 单文件 1 块 / 多块 / 超 max 强制切的 ChunkStat 报告
/// - excerpt 真实化 (= chunk 全文, 不再恒 200 字符)
/// - 与 SourceRefValidator 兼容: P0-3 substring check 必过
final class GathererChunkingTests: XCTestCase {

    // MARK: - chunkBody 单元

    /// 1. 单行 body → 1 块 (不分块)
    func testChunkBody_singleLine_returnsOneChunk() {
        let chunks = Gatherer.chunkBody("hello world", maxChars: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "hello world")
    }

    /// 2. 短 body (≤ maxChars) 不分块 (不管几个 H2)
    func testChunkBody_shortBody_returnsOneChunk() {
        let body = """
        ## Intro
        A short intro.

        ## Body
        Some content here.
        """
        let chunks = Gatherer.chunkBody(body, maxChars: 4000)
        XCTAssertEqual(chunks.count, 1, "≤ maxChars 不分块 (短 raw 浪费 LLM 算力)")
    }

    /// 3. 多 H2 标题, 总长 > maxChars → 每个 H2 = 1 块 + 1 块 intro
    func testChunkBody_multipleH2_splitByH2() {
        // 长 body (5000 字符), maxChars=4000 → 强制 H2 split
        let fillerA = String(repeating: "A", count: 2000)
        let fillerB = String(repeating: "B", count: 2000)
        let fillerC = String(repeating: "C", count: 2000)
        let body = "起始 intro 段\n\(fillerA)\n## Section A\n\(fillerB)\n## Section B\n\(fillerC)\n## Section C"
        let chunks = Gatherer.chunkBody(body, maxChars: 4000)
        // intro + 3 H2 sections = 4 块 (总长 6000+ > 4000 触发 split)
        XCTAssertGreaterThanOrEqual(chunks.count, 4, "intro + 3 H2 = ≥4 块 (长 body 强制 split)")
        XCTAssertTrue(chunks[0].contains("起始 intro 段"), "块 0 = intro (没标题)")
    }

    /// 4. 无 H2 标题 → 整段 1 块
    func testChunkBody_noH2_returnsOneChunk() {
        let body = """
        没有 H2 标题的长文本
        只是一段连续的 plain text
        行 3
        行 4
        """
        let chunks = Gatherer.chunkBody(body, maxChars: 4000)
        XCTAssertEqual(chunks.count, 1, "无 H2 → 整段 1 块")
        XCTAssertEqual(chunks[0], body)
    }

    /// 5. 单块超 maxChars → 强制按 "\n" 切 (避免切到单词中间)
    func testChunkBody_oversizedChunk_forceSplitsAtNewline() {
        // 构造一个 200 字符的 H2 段, maxChars=50 → 应被切成 ≥ 4 块
        let line1 = String(repeating: "A", count: 30)
        let line2 = String(repeating: "B", count: 30)
        let line3 = String(repeating: "C", count: 30)
        let line4 = String(repeating: "D", count: 30)
        let body = "## Big Section\n\(line1)\n\(line2)\n\(line3)\n\(line4)"
        let chunks = Gatherer.chunkBody(body, maxChars: 50)
        XCTAssertGreaterThan(chunks.count, 1, "单块超 maxChars → 强制切多块")
        // 关键: 切出来的子串必须是 body 的连续 substring (P0-3 substring 闸门要)
        for chunk in chunks {
            XCTAssertTrue(body.contains(chunk), "chunk 必须是 body 连续 substring, got: \(chunk)")
        }
    }

    /// 6. 强制切优先选最近 "\n" (避免切到单词中间)
    func testChunkBody_oversizedChunk_breaksAtNewlineNotMidword() {
        let body = "## Section\nAAAA\nBBBB\nCCCC\nDDDD"
        let chunks = Gatherer.chunkBody(body, maxChars: 15)
        // 期望: 第 1 块 = "## Section\n" (在 10 字符处有 "\n", 切 AFTER it 保留词完整)
        // 而不是 "## Section\nAA" (切到 "AA" 单词中间)
        let first = chunks[0]
        // 切点应正好在 "\n" 处 (块 ends with "\n" 后)
        XCTAssertTrue(first.hasSuffix("\n"),
                      "块边界应在 \\n 后 (保留词完整), got: '\(first)'")
    }

    /// 7. 空 body → 0 块
    func testChunkBody_emptyBody_returnsEmpty() {
        let chunks = Gatherer.chunkBody("", maxChars: 4000)
        XCTAssertTrue(chunks.isEmpty)
    }

    // MARK: - annotateChunksWithLineNumbers 单元

    /// 8. 单块从 bodyStartLine 开始
    func testAnnotate_singleChunk_lineEqualsBodyStart() {
        let body = "第一行\n第二行\n第三行"
        let chunks = ["第一行\n第二行\n第三行"]
        let result = Gatherer.annotateChunksWithLineNumbers(
            chunks: chunks, fullBody: body, bodyStartLine: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].line, 10, "单块起始行 = bodyStartLine")
    }

    /// 9. 多块: 块 1 line=bodyStart, 块 2 line=bodyStart+块1行数
    func testAnnotate_multiChunk_lineOffsetsAccumulate() {
        let body = "AAA\n## Section B\nBBB\n## Section C\nCCC"
        let chunks = ["AAA", "## Section B\nBBB", "## Section C\nCCC"]
        let result = Gatherer.annotateChunksWithLineNumbers(
            chunks: chunks, fullBody: body, bodyStartLine: 5)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].line, 5, "块 0 = bodyStart")
        XCTAssertEqual(result[1].line, 6, "块 1 = bodyStart+1 (AAA 1 行 + bodyStart)")
        XCTAssertEqual(result[2].line, 8, "块 2 = bodyStart+3 (AAA 1 + 空 + Section B 1 + 空 + BBB 1 = 3 行)")
    }

    /// 10. bodyStartLine=1 (无 frontmatter 文件), 1-based 行号正确
    func testAnnotate_bodyStartLineOne_oneBased() {
        let body = "line 1\nline 2"
        let chunks = ["line 1\nline 2"]
        let result = Gatherer.annotateChunksWithLineNumbers(
            chunks: chunks, fullBody: body, bodyStartLine: 1)
        XCTAssertEqual(result[0].line, 1, "1-based: 块 0 起始行 = 1")
    }

    // MARK: - gather() 集成

    /// 11. 单行 raw → 1 个 candidate (不分块), chunkStats[file].chunks=1
    func testGather_singleLineRaw_oneCandidate() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeRaw("a.md", body: "single line", in: tmp)
        let g = Gatherer(vaultRoot: tmp, maxChunkChars: 4000)
        let result = try g.gather()
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.chunkStats["raw/a.md"]?.chunks, 1)
        XCTAssertEqual(result.chunkStats["raw/a.md"]?.truncated, false)
    }

    /// 12. 多 H2 raw (长 body) → N 个 candidates (1 per H2 + intro), chunkStats.chunks=N
    func testGather_multiH2Raw_multipleCandidates() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 长 body (> 4000 字符) 强制 H2 split
        let fillerA = String(repeating: "A", count: 2000)
        let fillerB = String(repeating: "B", count: 2000)
        let body = "起始 intro\n\(fillerA)\n## Section A\nA 内容\n## Section B\n\(fillerB)\n## Section C\nB 内容"
        try writeRaw("long.md", body: body, in: tmp)
        let g = Gatherer(vaultRoot: tmp, maxChunkChars: 4000)
        let result = try g.gather()
        XCTAssertGreaterThanOrEqual(result.candidates.count, 3, "intro + ≥2 H2 = ≥3 candidates (长 body 强制 split)")
        XCTAssertGreaterThanOrEqual(result.chunkStats["raw/long.md"]?.chunks ?? 0, 3)
        XCTAssertEqual(result.chunkStats["raw/long.md"]?.truncated, true,
                       "长 body (> maxChars) → truncated=true 告警")
    }

    /// 13. 单 H2 块超 maxChars → 强制切, chunkStats.truncated=true
    func testGather_oversizedChunk_truncatedFlag() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 1 个 H2 段 200 字符, maxChars=50 → 强制切多块 (但 truncated 标志按设计意图 = true)
        let body = "## Big\n" + String(repeating: "X\n", count: 50)
        try writeRaw("big.md", body: body, in: tmp)
        let g = Gatherer(vaultRoot: tmp, maxChunkChars: 50)
        let result = try g.gather()
        XCTAssertGreaterThan(result.candidates.count, 1, "超 max → 多 candidates")
        XCTAssertEqual(result.chunkStats["raw/big.md"]?.truncated, true,
                       "超 maxChars 强制切 → truncated=true 告警")
    }

    /// 14. excerpt 真实化 (= chunk 全文), 不再恒 200 字符
    func testGather_excerptIsChunkText_notFirst200Chars() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 1 个 H2 段 500 字符, maxChars=4000 → 1 块
        let longSection = String(repeating: "X", count: 500)
        let body = "## Big Section\n\(longSection)"
        try writeRaw("a.md", body: body, in: tmp)
        let g = Gatherer(vaultRoot: tmp, maxChunkChars: 4000)
        let result = try g.gather()
        let candidate = result.candidates.first!
        let chunkText = candidate.text
        XCTAssertEqual(candidate.sources.first?.excerpt, chunkText,
                       "excerpt 真实化 = chunk.text (= chunk 全文, 不再恒 200 字符)")
        XCTAssertGreaterThan(chunkText.count, 200, "chunk > 200 字符 (覆盖原 excerpt 上限)")
    }

    /// 15. P0-3 闸门兼容: 块 substring check 必过 (chunk 必真在 sourceContents 里)
    func testGather_passesSourceRefValidator() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let body = """
        intro
        ## A
        A 的内容
        ## B
        B 的内容
        """
        try writeRaw("a.md", body: body, in: tmp)
        let g = Gatherer(vaultRoot: tmp, maxChunkChars: 4000)
        let result = try g.gather()
        // 每个 candidate 的 excerpt 必须在 sourceContents["raw/a.md"] (= 脱敏后 body) 里
        let fileBody = result.sourceContents["raw/a.md"]!
        for candidate in result.candidates {
            let excerpt = candidate.sources.first?.excerpt ?? ""
            XCTAssertTrue(fileBody.contains(excerpt),
                          "P0-3 闸门: chunk excerpt 必须 substring of file body, got: \(excerpt.prefix(30))")
        }
    }

    /// 16. sourceLine 真实化: 多块时每块 line 不同 (按块在原文件起始行)
    func testGather_sourceLineReflectsChunkOffset() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 长 body (> 4000 字符) 强制 H2 split
        let fillerA = String(repeating: "A", count: 2000)
        let fillerB = String(repeating: "B", count: 2000)
        let body = "intro 行\n\(fillerA)\n## Section A\nA 内容\n## Section B\n\(fillerB)\n## Section C\nB 内容"
        try writeRaw("a.md", body: body, in: tmp)
        let g = Gatherer(vaultRoot: tmp, maxChunkChars: 4000)
        let result = try g.gather()
        let candidates = result.candidates
        // 短 raw 1 块, 长 raw ≥3 块 (intro + 2 H2). body 6000+ 字符 > 4000 强制 split.
        XCTAssertGreaterThanOrEqual(candidates.count, 3)
        // 块 0: "intro 行" + fillerA, line = bodyStartLine (4, frontmatter 3 行)
        XCTAssertEqual(candidates[0].sources.first?.line, 4)
        // 后续块按块内行数偏移 (至少 ≥ 1)
        XCTAssertGreaterThan(candidates[1].sources.first?.line ?? 0, 4)
    }
}

// MARK: - 测试 fixtures

private func makeTempDir() -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dreamvault-p3-4-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func writeRaw(_ name: String, body: String, in dir: URL) throws {
    let rawDir = dir.appendingPathComponent("raw")
    try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
    let url = rawDir.appendingPathComponent(name)
    let content = """
    ---
    processed: false
    ---
    \(body)
    """
    try content.write(to: url, atomically: true, encoding: .utf8)
}
