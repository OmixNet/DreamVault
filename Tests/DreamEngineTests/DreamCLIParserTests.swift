import XCTest
@testable import DreamEngine

/// DreamCLI 参数解析 / GlobalOptions 单元测试
///
/// 重点测纯函数（parse + vaultURL + llmProvider 选择），不调 Process，避免依赖 main。
final class DreamCLIParserTests: XCTestCase {

    // MARK: - GlobalOptions.parse

    func testParseExtractsVaultAndLLM() {
        var args = ["--vault", "/tmp/foo", "--llm", "ollama", "run"]
        let opts = GlobalOptions.parse(from: &args)
        XCTAssertEqual(opts.vault, "/tmp/foo")
        XCTAssertEqual(opts.llm, "ollama")
        XCTAssertTrue(opts.verbose == false)
        XCTAssertEqual(args, ["run"], "parse 后应只留子命令")
    }

    func testParseVerboseFlag() {
        var args = ["-v", "status"]
        let opts = GlobalOptions.parse(from: &args)
        XCTAssertTrue(opts.verbose)
        XCTAssertEqual(args, ["status"])
    }

    func testParseLongVerbose() {
        var args = ["--verbose", "report", "--last", "3"]
        let opts = GlobalOptions.parse(from: &args)
        XCTAssertTrue(opts.verbose)
        XCTAssertEqual(args, ["report", "--last", "3"], "不应误吃 --last 的 3 当成 verbose 参数")
    }

    func testParseNoGlobalFlags() {
        var args = ["run", "--dry-run"]
        let opts = GlobalOptions.parse(from: &args)
        XCTAssertNil(opts.vault)
        XCTAssertNil(opts.llm)
        XCTAssertEqual(args, ["run", "--dry-run"], "没有全局 flag 时 args 应原样")
    }

    func testParseEmptyArgs() {
        var args: [String] = []
        let opts = GlobalOptions.parse(from: &args)
        XCTAssertNil(opts.vault)
        XCTAssertNil(opts.llm)
        XCTAssertFalse(opts.verbose)
    }

    // MARK: - GlobalOptions.vaultURL

    func testVaultURL_ExplicitVaultWins() {
        let opts = GlobalOptions(vault: "/custom/path")
        let url = opts.vaultURL()
        XCTAssertEqual(url.path, "/custom/path")
        // URL 应该是 directory
        XCTAssertTrue(url.hasDirectoryPath)
    }

    func testVaultURL_ExpandsTilde() {
        let opts = GlobalOptions(vault: "~/MyVault")
        let url = opts.vaultURL()
        // ~ 应被展开成 NSHomeDirectory
        XCTAssertFalse(url.path.contains("~"), "tilde 已被展开")
        XCTAssertTrue(url.path.hasSuffix("MyVault"))
    }

    func testVaultURL_DefaultUsesHomeDir() {
        let opts = GlobalOptions()
        // vault=nil 时默认 $HOME/.dreamvault
        let url = opts.vaultURL()
        XCTAssertTrue(url.path.hasSuffix(".dreamvault"))
    }

    // MARK: - GlobalOptions.llmProvider

    func testLLMProvider_ExplicitMock() {
        let opts = GlobalOptions(llm: "mock")
        let p = opts.llmProvider()
        XCTAssertTrue(p is MockLLMProvider, "--llm mock → MockLLMProvider")
    }

    func testLLMProvider_ExplicitOllama() {
        let opts = GlobalOptions(llm: "ollama")
        let p = opts.llmProvider()
        XCTAssertTrue(p is OllamaProvider, "--llm ollama → OllamaProvider")
    }

    func testLLMProvider_UnknownFallsBackToSettingsDefault() {
        // P8 改动：llmProvider() 走 ResolvedConfig 5 层合并。
        // 未知 --llm = CLI 覆盖 = nil，settings.llmChoice 默认是 .ollama → OllamaProvider。
        // 之前的行为（"unknown → mock"）是因为旧实现直接 if-else unknown → mock。
        // 新行为把 unknown 当成"用户没指定"，让下面层（settings）兜底。
        // 这是 P4 引入 ResolvedConfig 的目标：单一解析路径。
        let opts = GlobalOptions(llm: "gpt-9000")
        let p = opts.llmProvider()
        XCTAssertTrue(p is OllamaProvider,
                      "未知 --llm 在 P8 走 ResolvedConfig 5 层合并，settings 默认 .ollama")
    }
}
