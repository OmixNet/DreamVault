import Foundation

/// 单文件的 git 状态（clean / modified / conflict / staged / untracked）。
///
/// 重新解析 `git status --porcelain` 输出，针对单个文件给三态判定。
/// 调用方应缓存本 vault 整体 status，只在需要时再调本类型。
public struct GitFileStatus: Equatable, Sendable {
    public let relativePath: String
    public let state: State

    public enum State: String, Equatable, Sendable {
        case clean       // 没改
        case modified    // 工作区或 index 有变
        case conflict    // merge 冲突
        case untracked   // 未跟踪
        case staged      // 已 staged 未 commit
    }
}

/// 把 git status --porcelain 输出解析为按文件的状态字典。
/// 处理 v1 porcelain 的 2 字符前缀（" M ", "M ", "MM", "UU", "AA" 等）。
public struct GitStatusParser {

    public init() {}

    /// 解析一整段 `git status --porcelain` 输出。
    /// - Returns: 文件相对路径 → State。空字符串/注释行跳过。
    public func parse(_ porcelain: String) -> [String: GitFileStatus.State] {
        var result: [String: GitFileStatus.State] = [:]
        for rawLine in porcelain.components(separatedBy: "\n") {
            let line = rawLine
            guard line.count >= 4 else { continue }  // 至少 2 状态 + 1 分隔 + 1 路径字符
            // v1: "XY filename" — 固定 2 状态字符 + 1+ 分隔空格 + 路径
            // 状态字符可以是空格 + M / M + 空格 / ?? / !! 等
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            // 跳过状态字段后的 1+ 空格 / tab
            var i = 2
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            guard i < chars.count else { continue }
            var path = String(chars[i...])
            // rename 形式 "old -> new"
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }

            let statusChars = "\(x)\(y)"
            let s = classify(statusChars: statusChars)
            if s != .clean {
                result[path] = s
            }
        }
        return result
    }

    /// 单个文件的状态
    /// - Parameter statusChars: v1 porcelain 的 1-2 字符状态（" M", "M ", "MM", "UU", "??"）
    private func classify(statusChars: String) -> GitFileStatus.State {
        // v1 porcelain: X = index 槽状态, Y = worktree 槽状态
        // 冲突特殊：U 开头 / A 开头（both added）/ D 开头（both deleted）
        if statusChars.contains("U") || statusChars == "AA" || statusChars == "DD" {
            return .conflict
        }
        let x = statusChars.first ?? " "
        let y = statusChars.count >= 2 ? statusChars[statusChars.index(statusChars.startIndex, offsetBy: 1)] : " "

        // ?? = untracked
        if x == "?" && y == "?" { return .untracked }
        // !! = ignored（我们不需要关心）
        if x == "!" && y == "!" { return .clean }

        // 优先级: conflict 之后，先看 X（index/staged），再看 Y（worktree）
        // X 是 A/M/D/R/C → 已经 staged（哪怕 Y 也有改动）
        if "AMDRC".contains(x) { return .staged }
        // X 是空格，Y 是 M/D → 未 stage 的工作区改动
        if x == " " && "MD".contains(y) { return .modified }
        return .clean
    }
}
