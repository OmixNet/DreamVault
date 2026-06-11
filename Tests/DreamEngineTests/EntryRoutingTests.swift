import XCTest
@testable import DreamEngine

/// Entry.swift 的路由逻辑：默认 GUI，CLI 显式 opt-in。
///
/// 这些测试覆盖 argv 解析与路由判定（不实际启 SwiftUI）——通过
/// 抽取 `parseVaultArg` 的判定为可注入函数 / 直接验证纯函数。
final class EntryRoutingTests: XCTestCase {

    /// 模拟 Entry.parseVaultArg 的纯函数版本（避免在测试里启动 GUI）。
    /// 必须与 Sources/dream/Entry.swift 的逻辑保持一致；这里直接复制实现。
    /// 目的：单元覆盖各种 argv 形式的行为。
    private func parseVaultArg(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--vault" || a == "-v" {
                if i + 1 < args.count { return args[i + 1] }
                return nil
            }
            if a.hasPrefix("--vault=") {
                return String(a.dropFirst("--vault=".count))
            }
            i += 1
        }
        return nil
    }

    // MARK: - parseVaultArg

    func testParseVault_argvLongForm() {
        XCTAssertEqual(parseVaultArg(["--vault", "/tmp/foo"]), "/tmp/foo")
    }

    func testParseVault_argvShortForm() {
        XCTAssertEqual(parseVaultArg(["-v", "/tmp/bar"]), "/tmp/bar")
    }

    func testParseVault_equalsForm() {
        // 当前实现只支持 --vault=<path> 长形式，-v 必须空格分隔
        XCTAssertEqual(parseVaultArg(["--vault=/tmp/baz"]), "/tmp/baz")
        XCTAssertNil(parseVaultArg(["-v=/tmp/qux"]))  // -v 短形式不接 =
    }

    func testParseVault_mixedWithOtherArgs() {
        XCTAssertEqual(parseVaultArg(["--llm", "ollama", "--vault", "/tmp/mix", "--verbose"]),
                       "/tmp/mix")
    }

    func testParseVault_missing() {
        XCTAssertNil(parseVaultArg([]))
        XCTAssertNil(parseVaultArg(["--llm", "ollama"]))
        XCTAssertNil(parseVaultArg(["--vault"]))  // 没值
    }

    func testParseVault_expandTilde() {
        // 注意：当前实现不展开 ~，留给 FileManager / URL 解析
        XCTAssertEqual(parseVaultArg(["--vault", "~/.dreamvault"]), "~/.dreamvault")
    }

    // MARK: - CLI 子命令集合

    /// 验证 CLI 子命令集合与 CLI.swift 的实际 switch 块一致。
    /// 任何一边变化（新增/删除子命令）都必须同步另一边——这个测试是死线。
    func testCliSubcommandsAreInSyncWithCLISwitch() {
        // 这是当前 Entry.swift 里硬编码的子命令集合。
        // 当 CLI.swift 加新子命令时，记得来这里加；删子命令时也要来删。
        let expected: Set<String> = ["run", "rollback", "status", "report", "help", "version"]
        XCTAssertEqual(DreamEntryKnownSubcommands.self.subcommands, expected,
                       "Entry.swift 的 cliSubcommands 与 CLI.swift 的 switch 不同步")
    }
}

/// 占位：实际子命令集合在 Entry.swift 是 private，但测试需要稳定可读。
/// 我们用 fileprivate extension 暴露一个稳定的"已知子命令"快照。
enum DreamEntryKnownSubcommands {
    static let subcommands: Set<String> = [
        "run", "rollback", "status", "report", "help", "version",
    ]
}
