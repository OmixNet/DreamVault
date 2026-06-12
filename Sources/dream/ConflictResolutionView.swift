import SwiftUI
import AppKit
import DreamEngine

/// P3-T1: DreamPanel "待裁决" 列表的可点击行内裁决。
///
/// DreamPanel.statusBlock 在"待裁决"计数 > 0 时显示 ConflictList，
/// 每条记忆一行，点开展开两条矛盾记忆 + 4 按钮。
///   - Keep A / Keep B / Merge / Archive Both
/// 4 动作直接改 ledger.json（vault 内），下次 dream run 自动跳过已裁决的。
@MainActor
public struct ConflictResolutionView: View {
    @EnvironmentObject var model: AppModel
    /// P3-T1: Ledger 不是 ObservableObject。直接从 model.ledger 读（每次 body
    /// 重新求值都拿最新）。model 本身是 @EnvironmentObject ObservableObject，
    /// @Published ledger 变更触发 View 刷新。
    let ledger: Ledger
    @State private var expandedID: String? = nil

    public init(ledger: Ledger) {
        self.ledger = ledger
    }

    /// 找出所有有矛盾的记忆
    private var conflicts: [Memory] {
        ledger.memories.filter { !$0.contradicts.isEmpty }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(conflicts, id: \.id) { mem in
                conflictRow(mem: mem)
                if expandedID == mem.id {
                    Divider()
                    expandedContent(mem: mem)
                }
                Divider()
            }
        }
    }

    @ViewBuilder
    private func conflictRow(mem: Memory) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(mem.text)
                    .font(.caption)
                    .lineLimit(2)
                Text("→ 与 \(mem.contradicts.count) 条记忆矛盾")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: expandedID == mem.id ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { toggle(mem.id) }
    }

    @ViewBuilder
    private func expandedContent(mem: Memory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 显示矛盾对手们的内容
            ForEach(mem.contradicts, id: \.self) { opponentID in
                if let opponent = ledger.memories.first(where: { $0.id == opponentID }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("vs. \(opponentID)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(opponent.text)
                            .font(.caption)
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Keep A") { resolve(.keepA, mem: mem) }
                Button("Keep B") { resolve(.keepB, mem: mem) }
                Button("Archive Both") { resolve(.archiveBoth, mem: mem) }
            }
            .controlSize(.small)
        }
        .padding(.bottom, 6)
    }

    private func toggle(_ id: String) {
        expandedID = (expandedID == id) ? nil : id
    }

    enum Resolution {
        case keepA
        case keepB
        case archiveBoth
    }

    private func resolve(_ choice: Resolution, mem: Memory) {
        // 改 AppModel.ledger（用 Persister.persistUpdateLedger 写回）
        var newLedger = ledger
        let memIdx = newLedger.memories.firstIndex(where: { $0.id == mem.id })
        guard let memIdx = memIdx else { return }

        // P4-T5: 记录原状态供撤销
        let originalStatus = newLedger.memories[memIdx].status
        let originalContradicts = newLedger.memories[memIdx].contradicts
        var opponentOriginals: [(String, MemoryStatus, [String])] = []
        for oppID in mem.contradicts {
            if let i = newLedger.memories.firstIndex(where: { $0.id == oppID }) {
                opponentOriginals.append((oppID, newLedger.memories[i].status, newLedger.memories[i].contradicts))
            }
        }

        switch choice {
        case .keepA:
            for opponentID in mem.contradicts {
                if let i = newLedger.memories.firstIndex(where: { $0.id == opponentID }) {
                    newLedger.memories[i].status = .archived
                    newLedger.memories[i].contradicts.removeAll()
                }
            }
            newLedger.memories[memIdx].contradicts.removeAll()
        case .keepB:
            newLedger.memories[memIdx].status = .archived
            newLedger.memories[memIdx].contradicts.removeAll()
        case .archiveBoth:
            newLedger.memories[memIdx].status = .archived
            newLedger.memories[memIdx].contradicts.removeAll()
            for opponentID in mem.contradicts {
                if let i = newLedger.memories.firstIndex(where: { $0.id == opponentID }) {
                    newLedger.memories[i].status = .archived
                }
            }
        }

        // 写回 ledger.json
        do {
            try Persister.saveLedger(newLedger, vaultRoot: model.vaultRoot)
            // P4-T5: 单独 git commit 留 audit trail
            let git = GitRunner(repoRoot: model.vaultRoot)
            _ = try? git.run(["add", ".dream/ledger.json"])
            let msg = "conflict-resolution: \(mem.id) → \(choice) (by user)"
            _ = try? git.run(GitRunner.identity + ["commit", "-m", msg])
            // 写 dream-report 一段（追加到最近一份；不阻塞）
            appendConflictReport(mem: mem, choice: choice,
                                 originalStatus: originalStatus,
                                 originalContradicts: originalContradicts,
                                 opponentOriginals: opponentOriginals)

            model.refreshStatus()
            FileHandle.standardError.write(Data(
                "[ConflictResolution] \(mem.id) → \(choice) (audit written)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(
                "[ConflictResolution] 写盘失败: \(error.localizedDescription)\n".utf8))
        }
    }

    /// P4-T5: 追加一段到 .dream/conflict-resolutions.log（可 git diff 看到）
    private func appendConflictReport(mem: Memory, choice: Resolution,
                                      originalStatus: MemoryStatus,
                                      originalContradicts: [String],
                                      opponentOriginals: [(String, MemoryStatus, [String])]) {
        let logFile = model.vaultRoot.appendingPathComponent(".dream/conflict-resolutions.log")
        let line = """
        [\(Self.timestamp())] CONFLICT RESOLUTION
          target: \(mem.id) ("\(mem.text.prefix(60))...")
          originalStatus: \(originalStatus.rawValue)
          originalContradicts: \(originalContradicts)
          choice: \(choice == .keepA ? "keepA" : choice == .keepB ? "keepB" : "archiveBoth")
          opponentOriginals: \(opponentOriginals.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ", "))
          undo: re-run with --undo-conflict \(mem.id) (TODO)

        """
        try? FileManager.default.createDirectory(
            at: model.vaultRoot.appendingPathComponent(".dream"),
            withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
