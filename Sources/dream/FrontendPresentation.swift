import Foundation
import DreamEngine

enum FrontendPresentation {
    static func vaultDisplayName(path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !withoutTrailingSlash.isEmpty else { return "DreamVault" }
        return (withoutTrailingSlash as NSString).lastPathComponent
    }

    static func vaultSubtitle(path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func budgetUsage(count: Int, limit: Int) -> String {
        let limitText = limit == 0 ? "∞" : "\(limit)"
        return "\(count) / \(limitText) calls"
    }

    static func monthlySpend(cost: Double, limit: Double) -> String {
        let limitText = limit == 0 ? "∞" : String(format: "$%.2f", limit)
        return String(format: "$%.2f / %@", cost, limitText)
    }

    static func documentTitle(relPath: String, body: String) -> String {
        TitleResolver.displayTitle(relPath: relPath, body: body)
    }

    static func relativePath(of url: URL, vaultRoot: URL) -> String {
        let abs = url.standardizedFileURL.path
        let root = vaultRoot.standardizedFileURL.path
        if abs.hasPrefix(root + "/") {
            return String(abs.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    static func documentKindLabel(relPath: String) -> String {
        switch TitleResolver.classify(relPath: relPath) {
        case .raw:
            return "Raw"
        case .wikiMemory:
            return "Wiki"
        case .memoryMd:
            return "Memory"
        case .plainNote:
            return "Note"
        }
    }

    static func documentSaveStatus(isEditable: Bool, isDirty: Bool) -> String {
        if !isEditable { return "Read only" }
        return isDirty ? "Unsaved" : "Saved"
    }

    static func documentStatusSystemImage(isEditable: Bool, isDirty: Bool) -> String {
        if !isEditable { return "lock.fill" }
        return isDirty ? "circle.fill" : "checkmark.circle.fill"
    }

    static func canRenameSidebarItem(relPath: String) -> Bool {
        TitleResolver.canRename(relPath: relPath)
    }

    static func sidebarTitle(relPath: String, body: String?) -> String {
        TitleResolver.displayTitle(relPath: relPath, body: body)
    }

    static func sidebarSubtitle(relPath: String) -> String? {
        let filename = (relPath as NSString).lastPathComponent
        return relPath == filename ? nil : relPath
    }

    static func sidebarAccessibilityLabel(title: String, subtitle: String?) -> String {
        guard let subtitle, !subtitle.isEmpty, subtitle != title else { return title }
        return "\(title), \(subtitle)"
    }

    static func editorAccessibilityLabel(isEditable: Bool) -> String {
        isEditable ? "Markdown editor" : "Read-only Markdown viewer"
    }

    static func searchResultTitle(relPath: String, body: String?) -> String {
        sidebarTitle(relPath: relPath, body: body)
    }

    static func searchResultSubtitle(relPath: String) -> String? {
        sidebarSubtitle(relPath: relPath)
    }
}
