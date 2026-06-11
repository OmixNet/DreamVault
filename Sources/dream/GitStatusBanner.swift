import SwiftUI
import AppKit
import DreamEngine

/// 顶部 Git 状态 banner —— 显示当前文件的 clean / modified / conflict 状态 + 总览。
///
/// 实时刷新策略：用户切换文件 / autosave 后 / dream run 后 / Cmd-S 后各调一次 `refresh()`。
/// 不轮询（性能考虑 + 简单）。
public struct GitStatusBanner: View {
    @EnvironmentObject var model: AppModel
    let currentFile: URL?
    @ObservedObject var watcher: GitStatusWatcher

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(tint)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(tint)
            if let counts = summary, counts.added + counts.removed > 0 {
                Text("+\(counts.added)  −\(counts.removed)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let f = currentFile, watcher.status(for: f) == .conflict {
                conflictActions(file: f)
            } else if watcher.totalModified > 0 {
                Button {
                    watcher.refresh(vaultRoot: model.vaultRoot)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新 git 状态")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.1))
        .overlay(Rectangle().frame(height: 1).foregroundColor(tint.opacity(0.3)), alignment: .bottom)
    }

    private var tint: Color {
        guard let f = currentFile else { return .secondary }
        switch watcher.status(for: f) {
        case .conflict: return .red
        case .modified, .staged, .untracked: return .orange
        case .clean: return .green
        }
    }

    private var icon: String {
        guard let f = currentFile else { return "checkmark.circle" }
        switch watcher.status(for: f) {
        case .conflict: return "exclamationmark.triangle.fill"
        case .modified, .staged: return "pencil.circle.fill"
        case .untracked: return "questionmark.circle"
        case .clean: return "checkmark.circle.fill"
        }
    }

    private var label: String {
        guard let f = currentFile else {
            return watcher.totalModified == 0 ? "clean" : "\(watcher.totalModified) 个文件待处理"
        }
        switch watcher.status(for: f) {
        case .conflict: return "CONFLICT — 文件存在未解决冲突"
        case .modified: return "modified"
        case .staged: return "staged"
        case .untracked: return "untracked"
        case .clean: return "clean"
        }
    }

    private var summary: (added: Int, removed: Int)? {
        guard let f = currentFile else { return nil }
        return watcher.diffSummary(for: f)
    }

    @ViewBuilder
    private func conflictActions(file: URL) -> some View {
        HStack(spacing: 4) {
            Button("Keep Mine") { resolveKeepMine(file: file) }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            Button("Keep Theirs") { resolveKeepTheirs(file: file) }
                .controlSize(.mini)
            Button("Open Raw") {
                NSWorkspace.shared.open(file)
            }
            .controlSize(.mini)
        }
    }

    private func resolveKeepMine(file: URL) {
        // 简化：调 `git checkout --ours <file>`，但 arch doc 0.1 raw 永远不动；
        // 这里只针对非 raw 文件；raw 文件显示 Open Raw 让用户用 IDE 处理
        guard !file.path.contains("/raw/") else {
            NSWorkspace.shared.open(file); return
        }
        let git = GitRunner(repoRoot: model.vaultRoot)
        _ = try? git.run(["checkout", "--ours", "--", file.path])
        watcher.refresh(vaultRoot: model.vaultRoot)
    }

    private func resolveKeepTheirs(file: URL) {
        guard !file.path.contains("/raw/") else {
            NSWorkspace.shared.open(file); return
        }
        let git = GitRunner(repoRoot: model.vaultRoot)
        _ = try? git.run(["checkout", "--theirs", "--", file.path])
        watcher.refresh(vaultRoot: model.vaultRoot)
    }
}

/// vault 整体 git 状态缓存器（@MainActor ObservableObject）
@MainActor
public final class GitStatusWatcher: ObservableObject {
    @Published public private(set) var statuses: [String: GitFileStatus.State] = [:]
    @Published public private(set) var diffs: [String: DiffGenerator.Result] = [:]
    @Published public private(set) var totalModified: Int = 0

    public init() {}

    public func refresh(vaultRoot: URL) {
        let git = GitRunner(repoRoot: vaultRoot)
        guard let porcelain = try? git.statusPorcelain() else {
            self.statuses = [:]
            self.totalModified = 0
            return
        }
        self.statuses = GitStatusParser().parse(porcelain)
        self.totalModified = self.statuses.count
    }

    public func status(for url: URL) -> GitFileStatus.State {
        let rel = relPath(of: url)
        return statuses[rel] ?? .clean
    }

    public func diffSummary(for url: URL) -> (added: Int, removed: Int)? {
        guard let result = diffs[relPath(of: url)] else { return nil }
        return (result.addedCount, result.removedCount)
    }

    public func updateDiff(for url: URL, vaultRoot: URL) {
        let rel = relPath(of: url)
        guard let result = computeDiff(for: url, vaultRoot: vaultRoot) else {
            diffs.removeValue(forKey: rel)
            return
        }
        diffs[rel] = result
    }

    /// 调 git show HEAD:<file> 拿 committed 版本 + 读当前 on-disk → 算 diff
    private func computeDiff(for url: URL, vaultRoot: URL) -> DiffGenerator.Result? {
        let git = GitRunner(repoRoot: vaultRoot)
        let rel = relPath(of: url)
        // HEAD 版本（可能空 = 新文件）
        let headContent: String
        if let data = try? git.run(["show", "HEAD:\(rel)"] as [String]) {
            headContent = data
        } else {
            headContent = ""
        }
        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if headContent == onDisk { return nil }  // clean
        return DiffGenerator().diff(old: headContent, new: onDisk)
    }

    private func relPath(of url: URL) -> String {
        // 简化：用 lastPathComponent（GitRunner 已在 vault 内所以这是相对 vault root）
        url.lastPathComponent
    }
}
