import XCTest
@testable import DreamEngine
import AppKit

/// P3-C3: DreamCycle.runOnce onStage 回调应按顺序触发 5 步。
@MainActor
final class DreamStageCallbackTests: XCTestCase {

    func testRunOnce_emitsGatherEvent() async throws {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try setupVault(vault)

        let events = await runDreamCollectingEvents(vault: vault)
        XCTAssertTrue(events.contains(where: { $0.hasPrefix("gather") }),
                      "应有 gather stage 事件，actual: \(events)")
    }

    func testRunOnce_emptyRaw_emitsGatherZero() async throws {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let events = await runDreamCollectingEvents(vault: vault)
        XCTAssertTrue(events.contains(where: { $0.contains("gather done: 0") }),
                      "空 vault 应有 gather done: 0，actual: \(events)")
    }

    // MARK: - helper

    private func runDreamCollectingEvents(vault: URL) async -> [String] {
        await withCheckedContinuation { cont in
            var events: [String] = []
            let cycle = DreamCycle(vaultRoot: vault, llm: MockLLMProvider(), git: nil)
            Task {
                _ = try? await cycle.runOnce { event in
                    events.append(event)
                }
                cont.resume(returning: events)
            }
        }
    }

    private func makeVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-c3-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for sub in ["raw", "wiki/entities", "wiki/concepts", "wiki/syntheses", "wiki/archive", ".dream"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub),
                                                     withIntermediateDirectories: true)
        }
        return dir
    }

    private func setupVault(_ vault: URL) throws {
        let rawFile = vault.appendingPathComponent("raw/2026-06-12-test.md")
        try """
        ---
        title: test
        processed: false
        ---

        # test

        Some content.
        """.write(to: rawFile, atomically: true, encoding: .utf8)
    }
}
