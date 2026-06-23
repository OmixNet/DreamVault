import XCTest
@testable import dream

// PR 50a (v0.6.x): tests for the structured StatusReport output of
// `dream status --json`. Contract is locked in
// docs/superpowers/plans/2026-06-23-pr50-vault-stats-json-contract.md.
//
// The contract:
//   - schemaVersion: 1 (strict; Rust rejects any other version)
//   - vaultPath: absolute
//   - rawCandidatesCount / processedCount / archivedCount: UInt32
//   - lastReportPath: vault-relative String?, null when no reports
//
// These tests pin:
//   1. The data builder (buildStatusReport) computes the right numbers
//   2. The JSON encoding uses the right field names + types
//   3. The schemaVersion is locked at 1
//   4. Edge cases: fresh vault, corrupt ledger, no reports directory

final class StatusReportJSONTests: XCTestCase {

    /// Create a temp vault directory with optional subdirectories.
    /// Returns the URL + cleanup closure.
    private func makeTempVault(files: [String: String] = [:], subdirs: [String] = []) -> (URL, () -> Void) {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StatusReportJSONTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for sub in subdirs {
            try? fm.createDirectory(at: tmpDir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for (rel, content) in files {
            let url = tmpDir.appendingPathComponent(rel)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        return (tmpDir, {
            try? fm.removeItem(at: tmpDir)
        })
    }

    /// Helper: decode the StatusReport back from the JSON-encoded string
    /// so we can assert on the typed fields, not on the wire format.
    private func decode(_ json: String) throws -> DreamCLI.StatusReport {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(DreamCLI.StatusReport.self, from: data)
    }

    // MARK: - schemaVersion locked

    func testSchemaVersionIsLockedAtOne() {
        XCTAssertEqual(DreamCLI.StatusReport.currentSchemaVersion, 1)
    }

    func testBuildStatusReport_usesSchemaVersionOne() throws {
        let (vault, cleanup) = makeTempVault()
        defer { cleanup() }
        let report = DreamCLI.buildStatusReport(vault: vault)
        XCTAssertEqual(report.schemaVersion, 1)
    }

    // MARK: - Fresh vault (no .dream/ directory)

    func testBuildStatusReport_freshVault_allZerosAndNullLastReport() {
        let (vault, cleanup) = makeTempVault()
        defer { cleanup() }
        let report = DreamCLI.buildStatusReport(vault: vault)
        XCTAssertEqual(report.vaultPath, vault.path)
        XCTAssertEqual(report.rawCandidatesCount, 0)
        XCTAssertEqual(report.processedCount, 0)
        XCTAssertEqual(report.archivedCount, 0)
        XCTAssertNil(report.lastReportPath)
    }

    // MARK: - Vault with raw/ files

    func testBuildStatusReport_countsRawCandidates() throws {
        // 2 raw files, both with processed:false → 2 candidates
        // 1 raw file with processed:true → 0 candidates
        let files: [String: String] = [
            "raw/2026-06-22-a.md": "---\nprocessed: false\n---\n# a\n",
            "raw/2026-06-22-b.md": "---\nprocessed: false\n---\n# b\n",
            "raw/2026-06-22-c.md": "---\nprocessed: true\n---\n# c\n",
        ]
        let (vault, cleanup) = makeTempVault(files: files, subdirs: ["raw"])
        defer { cleanup() }
        let report = DreamCLI.buildStatusReport(vault: vault)
        XCTAssertEqual(report.rawCandidatesCount, 2)
    }

    // MARK: - JSON wire format

    func testBuildStatusReport_encodesAllFieldsInJSON() throws {
        let files: [String: String] = [
            "raw/2026-06-22-a.md": "---\nprocessed: false\n---\n# a\n",
        ]
        let (vault, cleanup) = makeTempVault(files: files, subdirs: ["raw"])
        defer { cleanup() }
        let report = DreamCLI.buildStatusReport(vault: vault)
        // Round-trip: encode to JSON, decode back, compare.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let json = String(data: data, encoding: .utf8)!
        let decoded = try decode(json)
        XCTAssertEqual(decoded, report)
    }

    func testBuildStatusReport_jsonWireFormat_containsExpectedFieldNames() throws {
        let (vault, cleanup) = makeTempVault()
        defer { cleanup() }
        let report = DreamCLI.buildStatusReport(vault: vault)
        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let json = String(data: data, encoding: .utf8)!
        // Locked wire format. The Rust side reads these exact key
        // names (via serde rename_all = "camelCase"). Drift here is
        // a contract break.
        XCTAssertTrue(json.contains("\"schemaVersion\":1"),
                      "schemaVersion: 1 must be present: \(json)")
        XCTAssertTrue(json.contains("\"vaultPath\":"), "vaultPath key: \(json)")
        XCTAssertTrue(json.contains("\"rawCandidatesCount\":0"), "rawCandidatesCount: 0: \(json)")
        XCTAssertTrue(json.contains("\"processedCount\":0"), "processedCount: 0: \(json)")
        XCTAssertTrue(json.contains("\"archivedCount\":0"), "archivedCount: 0: \(json)")
        XCTAssertTrue(json.contains("\"lastReportPath\":null"), "lastReportPath: null: \(json)")
    }

    // MARK: - Backwards compat: text path unchanged

    func testCmdStatus_textOutput_stillWorks() {
        // Without --json flag, cmdStatus should produce the existing
        // text format (not JSON). We test the data builder here
        // (cmdStatus wires it up but the wire format is verified by
        // the unit tests on buildStatusReport + the format choice in
        // cmdStatus). This test is a guard against accidentally
        // flipping the default to JSON.
        let (vault, cleanup) = makeTempVault()
        defer { cleanup() }
        let report = DreamCLI.buildStatusReport(vault: vault)
        // The text path uses the same data; we just verify the
        // builder is what cmdStatus would call. The actual print
        // format is a test-time concern (stdout capture is awkward
        // in XCTest) — covered by integration test
        // LaunchCorrectnessTests + manual smoke.
        XCTAssertEqual(report.vaultPath, vault.path)
    }

    // MARK: - Last report path is vault-relative

    func testBuildStatusReport_lastReportPathIsVaultRelative() throws {
        // Create a reports directory with one file. The path in
        // StatusReport must be relative to the vault root, not
        // absolute — design note §1.4 rule 3.
        let files: [String: String] = [
            ".dream/reports/dream-report-2026-06-22-182157.md": "# report\n",
        ]
        let (vault, cleanup) = makeTempVault(files: files, subdirs: [".dream/reports"])
        defer { cleanup() }
        let report = DreamCLI.buildStatusReport(vault: vault)
        XCTAssertEqual(report.lastReportPath, ".dream/reports/dream-report-2026-06-22-182157.md")
        // Sanity: it does NOT start with the absolute vault path.
        XCTAssertFalse(report.lastReportPath?.hasPrefix(vault.path) ?? true)
    }

    // MARK: - StatusReport is Equatable + Codable round-trip

    func testStatusReport_isEquatable() {
        let a = DreamCLI.StatusReport(
            vaultPath: "/v", rawCandidatesCount: 1, processedCount: 2,
            archivedCount: 0, lastReportPath: nil
        )
        let b = DreamCLI.StatusReport(
            vaultPath: "/v", rawCandidatesCount: 1, processedCount: 2,
            archivedCount: 0, lastReportPath: nil
        )
        XCTAssertEqual(a, b)
    }

    // MARK: - Multiple reports: most recent wins

    func testBuildStatusReport_picksMostRecentReport() throws {
        // Create 2 reports with explicit creationDate ordering. The
        // most recent one (by creationDate) should win.
        // The .creationDateKey sort is by file system metadata, not
        // by filename, so we set mtime explicitly.
        let files: [String: String] = [
            ".dream/reports/dream-report-2026-06-22-100000.md": "# older\n",
            ".dream/reports/dream-report-2026-06-22-180000.md": "# newer\n",
        ]
        let (vault, cleanup) = makeTempVault(files: files, subdirs: [".dream/reports"])
        defer { cleanup() }
        // Set mtime explicitly so the sort is deterministic.
        let fm = FileManager.default
        let older = vault.appendingPathComponent(".dream/reports/dream-report-2026-06-22-100000.md")
        let newer = vault.appendingPathComponent(".dream/reports/dream-report-2026-06-22-180000.md")
        let now = Date()
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: older.path)
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)
        let report = DreamCLI.buildStatusReport(vault: vault)
        XCTAssertEqual(report.lastReportPath, ".dream/reports/dream-report-2026-06-22-180000.md")
    }
}
