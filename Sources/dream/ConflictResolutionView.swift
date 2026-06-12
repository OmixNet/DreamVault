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

        switch choice {
        case .keepA:
            // 删 B 们的 contradicts 链（标记 archived）
            for opponentID in mem.contradicts {
                if let i = newLedger.memories.firstIndex(where: { $0.id == opponentID }) {
                    newLedger.memories[i].status = .archived
                    newLedger.memories[i].contradicts.removeAll()
                }
            }
            newLedger.memories[memIdx].contradicts.removeAll()
        case .keepB:
            // 删 A 自己
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
            // 触发 AppModel refresh
            model.refreshStatus()
            FileHandle.standardError.write(Data(
                "[ConflictResolution] \(mem.id) → \(choice)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(
                "[ConflictResolution] 写盘失败: \(error.localizedDescription)\n".utf8))
        }
    }
}
