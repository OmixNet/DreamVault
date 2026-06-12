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

    /// P5-T1: 当前 vault 的 audit log 倒序（最近 N 条）
    @State private var auditLogLines: [String] = []
    @State private var showAuditLog: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(conflicts.count) 待裁决")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                // P0-8: 大 sheet 模式, 一次一对, 左右并排 + 3 button + Merge
                if !conflicts.isEmpty {
                    Button {
                        showSheet = true
                    } label: {
                        Label("Review", systemImage: "rectangle.stack.badge.person.crop")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    showAuditLog.toggle()
                } label: {
                    Label("Audit Log", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 4)
            ForEach(conflicts, id: \.id) { mem in
                conflictRow(mem: mem)
                if expandedID == mem.id {
                    Divider()
                    expandedContent(mem: mem)
                }
                Divider()
            }
            if showAuditLog {
                auditLogView
            }
        }
        .onAppear { reloadAuditLog() }
        .sheet(isPresented: $showSheet) {
            // P0-8: 大 sheet 模式弹独立窗口, 一次一对, 左右并排, 3 button + Merge
            ConflictResolutionSheet(
                ledger: ledger,
                onResolve: { choice, mem in
                    resolve(choice, mem: mem)
                    // 解决后自动进下一对; 没有则关 sheet
                    if conflicts.count <= 1 {
                        showSheet = false
                    }
                    _ = choice  // silence
                },
                onMerge: { mem in
                    mergeTarget = mem
                    mergeSheet = true
                },
                onDismiss: { showSheet = false }
            )
            .frame(minWidth: 760, minHeight: 520)
        }
        .sheet(isPresented: $mergeSheet) {
            if let target = mergeTarget,
               let firstOpp = mem_firstOpponent(of: target) {
                MergeSheetView(
                    memoryA: target,
                    memoryB: firstOpp,
                    vaultRoot: model.vaultRoot,
                    onCommit: { mergedText in
                        mergeCommit(target: target, opponent: firstOpp, mergedText: mergedText)
                        mergeSheet = false
                        mergeTarget = nil
                    },
                    onCancel: {
                        mergeSheet = false
                        mergeTarget = nil
                    }
                )
                .frame(minWidth: 700, minHeight: 500)
            }
        }
    }

    private func mem_firstOpponent(of mem: Memory) -> Memory? {
        guard let firstID = mem.contradicts.first else { return nil }
        return ledger.memories.first(where: { $0.id == firstID })
    }

    /// P8: 合并 target + 对手成一条新记忆，archive 旧两条，清 contradicts。
    private func mergeCommit(target: Memory, opponent: Memory, mergedText: String) {
        var newLedger = ledger
        // Memory 用 sources: [SourceRef]；merge 后 sources = 双方 source 合并去重
        let mergedSources = Array(Set(target.sources + opponent.sources))
        let newMem = Memory(
            id: "merged-\(UUID().uuidString.prefix(8))",
            text: mergedText,
            sources: mergedSources,
            status: .candidate,  // merge 出来的让用户后面再 review / 转 durable
            createdAt: Date(),
            lastAccess: Date(),
            reinforceCount: max(target.reinforceCount, opponent.reinforceCount),
            inboundLinks: target.inboundLinks + opponent.inboundLinks,
            contradicts: [],
            decayClass: target.decayClass.rawValue >= opponent.decayClass.rawValue ? target.decayClass : opponent.decayClass,
            kind: target.kind,
            relatedTo: Array(Set(target.relatedTo + opponent.relatedTo))
        )
        newLedger.memories.append(newMem)
        // archive 旧两条 + 清对手的 contradicts
        for id in [target.id, opponent.id] {
            if let i = newLedger.memories.firstIndex(where: { $0.id == id }) {
                newLedger.memories[i].status = .archived
                newLedger.memories[i].contradicts.removeAll()
            }
        }
        // 清其他记忆的 contradicts 字段里所有对合并前后记忆的引用
        for i in 0..<newLedger.memories.count {
            newLedger.memories[i].contradicts.removeAll(where: {
                $0 == target.id || $0 == opponent.id
            })
        }
        do {
            try Persister.saveLedger(newLedger, vaultRoot: model.vaultRoot)
            let git = GitRunner(repoRoot: model.vaultRoot)
            _ = try? git.run(["add", ".dream/ledger.json"])
            let msg = "conflict-resolution: \(target.id) ⟷ \(opponent.id) → merged into \(newMem.id)"
            _ = try? git.run(GitRunner.identity + ["commit", "-m", msg])
            FileHandle.standardError.write(Data(
                "[ConflictResolution] merge → \(newMem.id)\n".utf8))
            model.refreshStatus()
        } catch {
            FileHandle.standardError.write(Data(
                "[ConflictResolution] merge failed: \(error.localizedDescription)\n".utf8))
        }
    }

    @ViewBuilder
    private var auditLogView: some View {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Audit Log (.dream/conflict-resolutions.log)")
                    .font(.caption).bold()
                Spacer()
                Button("Undo Last") { undoLast() }
                    .controlSize(.mini)
                    .disabled(auditLogLines.isEmpty)
                Button("Close") { showAuditLog = false }
                    .controlSize(.mini)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(auditLogLines.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(4)
            .frame(maxHeight: 120)
        }
        .padding(.top, 6)
    }

    private func reloadAuditLog() {
        let logFile = model.vaultRoot.appendingPathComponent(".dream/conflict-resolutions.log")
        if let data = try? String(contentsOf: logFile, encoding: .utf8) {
            auditLogLines = data.components(separatedBy: "\n")
        } else {
            auditLogLines = []
        }
    }

    /// P5-T1: 撤销最近一次 conflict resolution。
    /// 流程：git revert HEAD → ledger.json 自动回到上次未裁决状态
    /// → model.refreshStatus() → 列表里这条 conflict 重新出现
    private func undoLast() {
        let git = GitRunner(repoRoot: model.vaultRoot)
        do {
            let newHead = try git.revertLastCommit()
            // append 到 audit log 一行 "UNDONE: <hash>"
            let logFile = model.vaultRoot.appendingPathComponent(".dream/conflict-resolutions.log")
            if let data = "  undone: revert → \(newHead)\n".data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: logFile)
                }
            }
            FileHandle.standardError.write(Data(
                "[ConflictResolution] undone via git revert → \(newHead)\n".utf8))
            model.refreshStatus()
            reloadAuditLog()
        } catch {
            FileHandle.standardError.write(Data(
                "[ConflictResolution] undo failed: \(error.localizedDescription)\n".utf8))
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
                            .padding(Spacing.sm)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Keep A") { resolve(.keepA, mem: mem) }
                Button("Keep B") { resolve(.keepB, mem: mem) }
                // P8: 加 Merge 按钮 → 弹双列 diff 编辑器
                Button("Merge…") { mergeTarget = mem; mergeSheet = true }
                Button("Archive Both") { resolve(.archiveBoth, mem: mem) }
            }
            .controlSize(.small)
        }
        .padding(.bottom, 6)
    }

    // P8: Merge sheet 状态
    @State private var mergeSheet: Bool = false
    @State private var mergeTarget: Memory? = nil
    // P0-8: 大 sheet 模式 (一次一对, 左右并排)
    @State private var showSheet: Bool = false
    // P0-8: sheet 内部当前页 (0-based, 0 = 第一对)
    @State private var sheetIndex: Int = 0

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
            // P8 修复：keepA 也得清反向——任何 memory 的 contradicts 含 target id 的
            // 都需要把 target id 删掉（否则 C.contradicts=["A"] 这种反向仍让
            // C 出现在"待裁决"列表）
            for opponentID in mem.contradicts {
                if let i = newLedger.memories.firstIndex(where: { $0.id == opponentID }) {
                    newLedger.memories[i].status = .archived
                    newLedger.memories[i].contradicts.removeAll()
                }
            }
            newLedger.memories[memIdx].contradicts.removeAll()
            for i in 0..<newLedger.memories.count {
                newLedger.memories[i].contradicts.removeAll(where: { $0 == mem.id })
            }
        case .keepB:
            // P8 修复：之前只 archive target + 清 target.contradicts，
            // 没有从对手的 contradicts 里删 target id → 列表里仍"待裁决"。
            newLedger.memories[memIdx].status = .archived
            newLedger.memories[memIdx].contradicts.removeAll()
            for opponentID in mem.contradicts {
                if let i = newLedger.memories.firstIndex(where: { $0.id == opponentID }) {
                    newLedger.memories[i].contradicts.removeAll(where: { $0 == mem.id })
                }
            }
        case .archiveBoth:
            // P8 修复：之前 archive opponents 但没清他们的 contradicts 字段
            newLedger.memories[memIdx].status = .archived
            newLedger.memories[memIdx].contradicts.removeAll()
            for opponentID in mem.contradicts {
                if let i = newLedger.memories.firstIndex(where: { $0.id == opponentID }) {
                    newLedger.memories[i].status = .archived
                    newLedger.memories[i].contradicts.removeAll(where: { $0 == mem.id })
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

// MARK: - P0-8: 大 sheet 模式 (一次一对, 左右并排 + 3 button + Merge 单独)

/// 独立 sheet 视图. 跟 ConflictResolutionView 解耦, 只读 ledger + callback.
/// - ledger: 拿 conflicts 列表
/// - onResolve: 用户点 Keep A / Keep B / Archive Both
/// - onMerge: 用户点 Merge (弹 MergeSheetView)
/// - onDismiss: 用户点关闭
@MainActor
struct ConflictResolutionSheet: View {
    let ledger: Ledger
    let onResolve: (ConflictResolutionView.Resolution, Memory) -> Void
    let onMerge: (Memory) -> Void
    let onDismiss: () -> Void

    @State private var index: Int = 0

    init(ledger: Ledger,
         onResolve: @escaping (ConflictResolutionView.Resolution, Memory) -> Void,
         onMerge: @escaping (Memory) -> Void,
         onDismiss: @escaping () -> Void) {
        self.ledger = ledger
        self.onResolve = onResolve
        self.onMerge = onMerge
        self.onDismiss = onDismiss
    }

    private var conflicts: [Memory] {
        ledger.memories.filter { !$0.contradicts.isEmpty }
    }

    private var current: Memory? {
        guard index >= 0, index < conflicts.count else { return nil }
        return conflicts[index]
    }

    private var opponent: Memory? {
        guard let mem = current,
              let firstID = mem.contradicts.first else { return nil }
        return ledger.memories.first(where: { $0.id == firstID })
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conflict Resolution")
                    .font(.title3).bold()
                Text("\(conflicts.count) pair\(conflicts.count == 1 ? "" : "s") need decision · showing \(min(index + 1, conflicts.count))/\(conflicts.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Close") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        if let mem = current, let opp = opponent {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    candidateCard(label: "A", id: mem.id, text: mem.text,
                                  sources: mem.sources,
                                  isCurrent: true)
                    VStack {
                        Spacer()
                        Image(systemName: "arrow.left.and.right")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("contradicts")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(width: 80)
                    candidateCard(label: "B", id: opp.id, text: opp.text,
                                  sources: opp.sources,
                                  isCurrent: false)
                }
                .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sources")
                            .font(.caption).bold()
                            .foregroundColor(.secondary)
                        ForEach(mem.sources, id: \.file) { s in
                            Text("• \(s.file):\(s.line)  \(s.excerpt.prefix(120))")
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                }
                .frame(maxHeight: 80)
            }
            .padding(Spacing.lg)
        } else if conflicts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                Text("All conflicts resolved")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            // 越界: 自动跳回
            Color.clear.onAppear { index = 0 }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // P0-8: 3 个主按钮 (左侧 destructive, 中性居中, 右侧 keep)
            Button(role: .destructive) {
                if let mem = current {
                    onResolve(.archiveBoth, mem)
                    advance()
                }
            } label: {
                Label("Archive Both", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .disabled(current == nil)
            .controlSize(.large)

            Button {
                if let mem = current {
                    onResolve(.keepA, mem)
                    advance()
                }
            } label: {
                Label("Keep A", systemImage: "a.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(current == nil)
            .controlSize(.large)
            .keyboardShortcut("a", modifiers: [.command])

            Button {
                if let mem = current {
                    onResolve(.keepB, mem)
                    advance()
                }
            } label: {
                Label("Keep B", systemImage: "b.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(current == nil)
            .controlSize(.large)
            .keyboardShortcut("b", modifiers: [.command])

            // P0-8: Merge 单独, 不动 Resolved 状态
            Button {
                if let mem = current { onMerge(mem) }
            } label: {
                Label("Merge…", systemImage: "arrow.triangle.merge")
                    .frame(maxWidth: .infinity)
            }
            .disabled(current == nil || opponent == nil)
            .controlSize(.large)

            // 翻页
            Spacer()
            HStack(spacing: 4) {
                Button {
                    if index > 0 { index -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(index == 0)
                Button {
                    if index < conflicts.count - 1 { index += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(index >= conflicts.count - 1)
            }
            .controlSize(.small)
        }
        .padding(Spacing.md)
    }

    private func advance() {
        // conflicts 列表在 onResolve 后会少一个 (resolve 后 archived, contradicts 清空,
        // 但 ledger 是值类型, callback 不返回新 ledger; sheet 自己 reload 即可)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)  // 等 model.refreshStatus
            let newCount = ledger.memories.filter { !$0.contradicts.isEmpty }.count
            if newCount == 0 {
                onDismiss()
            } else if index >= newCount {
                index = max(0, newCount - 1)
            }
        }
    }

    private func candidateCard(label: String, id: String, text: String,
                               sources: [SourceRef], isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.title2).bold()
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(isCurrent ? Color.blue : Color.gray)
                    .clipShape(Circle())
                Text(id)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
        }
        .frame(maxWidth: .infinity)
    }
}
