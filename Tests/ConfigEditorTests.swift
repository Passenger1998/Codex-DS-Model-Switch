import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

@main
struct ConfigEditorTests {
    static let fileManager = FileManager.default

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure.failed(message)
        }
    }

    static func makeTemporaryCodexDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-model-switcher-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func backupURLs(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.toml.switcher-backup-") }
    }

    static func rootPrefix(of text: String) -> String {
        var result: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                break
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    static func testSyntheticRoundTrip() throws {
        let directory = try makeTemporaryCodexDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.toml")
        let modelsURL = directory.appendingPathComponent("models.json")
        let deepSeekConfigURL = directory.appendingPathComponent("deepseek.config.toml")
        let modelsSentinel = Data("{\"sentinel\":true}\n".utf8)
        let deepSeekConfigSentinel = Data("sentinel = \"do-not-touch\"\n".utf8)
        let original = [
            "# 用户顶层配置",
            "model = \"old-model\" # 只允许改这个目标字段",
            "model_provider = \"old-provider\"",
            "model_reasoning_effort = \"high\"",
            "instructions = \"\"\"",
            "[这不是表头]",
            "model = \\\"这不是顶层字段\\\"",
            "\"\"\"",
            "",
            "[model_providers.deepseek] # 必须永久保留",
            "name = \"DeepSeek\"",
            "api_key = \"sk-TEST-SECRET-MUST-STAY\"",
            "base_url = \"https://api.deepseek.example\"",
            "",
            "[plugins.sample]",
            "model = \"plugin-model-must-stay\"",
            "model_provider = \"plugin-provider-must-stay\"",
            "preferred_auth_method = \"plugin-auth-must-stay\"",
            "forced_login_method = \"plugin-login-must-stay\"",
            "model_catalog_json = \"plugin-catalog-must-stay\"",
            "",
            "[mcp_servers.sample]",
            "command = \"sample\"",
            "",
            "[projects.\"/private/project\"]",
            "trust_level = \"trusted\"",
            "",
            "[desktop]",
            "notifications = true",
            "",
        ].joined(separator: "\r\n")
        try original.data(using: .utf8)!.write(to: configURL)
        try modelsSentinel.write(to: modelsURL)
        try deepSeekConfigSentinel.write(to: deepSeekConfigURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        let editor = CodexConfigEditor(codexDirectory: directory)
        let deepSeekResult = try editor.switchMode(to: .deepSeek)
        let deepSeekText = try String(contentsOf: configURL, encoding: .utf8)
        let firstBackupText = try String(contentsOf: deepSeekResult.backupURL!, encoding: .utf8)

        try expect(deepSeekResult.changed, "DeepSeek 首次切换应修改配置")
        try expect(deepSeekResult.backupURL != nil, "DeepSeek 切换前应创建备份")
        try expect(firstBackupText == original,
                   "首次备份必须与原配置逐字一致")
        try expect(deepSeekText.contains("model = \"deepseek-v4-pro\"\r\n"), "DeepSeek model 未正确写入")
        try expect(deepSeekText.contains("model_provider = \"deepseek\"\r\n"), "DeepSeek provider 未正确写入")
        try expect(deepSeekText.contains("preferred_auth_method = \"apikey\"\r\n"), "认证偏好未正确写入")
        try expect(deepSeekText.contains("forced_login_method = \"api\"\r\n"), "登录方式未正确写入")
        try expect(deepSeekText.contains("model_catalog_json = \"~/.codex/models.json\"\r\n"), "模型目录未正确写入")
        try expect(deepSeekText.contains("model_reasoning_effort = \"high\""), "reasoning effort 被改动")
        try expect(deepSeekText.contains("api_key = \"sk-TEST-SECRET-MUST-STAY\""), "provider API Key 被改动")
        try expect(deepSeekText.contains("model = \"plugin-model-must-stay\""), "表内同名字段被误改")
        try expect(!deepSeekText.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF 换行未保留")

        let chatGPTResult = try editor.switchMode(to: .chatGPT)
        let chatGPTText = try String(contentsOf: configURL, encoding: .utf8)
        let root = rootPrefix(of: chatGPTText.replacingOccurrences(of: "\r\n", with: "\n"))

        try expect(chatGPTResult.changed, "ChatGPT 切换应删除目标字段")
        try expect(chatGPTResult.backupURL != nil, "ChatGPT 切换前应创建备份")
        try expect(!root.contains("model ="), "ChatGPT 模式仍含顶层 model")
        try expect(!root.contains("model_provider ="), "ChatGPT 模式仍含顶层 model_provider")
        try expect(!root.contains("preferred_auth_method ="), "ChatGPT 模式仍含顶层认证偏好")
        try expect(!root.contains("forced_login_method ="), "ChatGPT 模式仍含顶层登录方式")
        try expect(!root.contains("model_catalog_json ="), "ChatGPT 模式仍含顶层模型目录")
        try expect(chatGPTText.contains("[model_providers.deepseek] # 必须永久保留"), "ChatGPT 切换删除了 provider")
        try expect(chatGPTText.contains("api_key = \"sk-TEST-SECRET-MUST-STAY\""), "ChatGPT 切换改动了 API Key")
        try expect(chatGPTText.contains("model = \"plugin-model-must-stay\""), "ChatGPT 切换误删表内字段")
        try expect(chatGPTText.contains("model_reasoning_effort = \"high\""), "ChatGPT 切换改动 reasoning effort")

        _ = try editor.switchMode(to: .deepSeek)
        let deepSeekAgain = try String(contentsOf: configURL, encoding: .utf8)
        try expect(deepSeekAgain.components(separatedBy: "[model_providers.deepseek]").count == 2,
                   "来回切换后 provider 数量异常")
        try expect(deepSeekAgain.contains("api_key = \"sk-TEST-SECRET-MUST-STAY\""),
                   "来回切换后 API Key 不存在")
        let persistedModels = try Data(contentsOf: modelsURL)
        let persistedDeepSeekConfig = try Data(contentsOf: deepSeekConfigURL)
        try expect(persistedModels == modelsSentinel,
                   "models.json 被意外改动")
        try expect(persistedDeepSeekConfig == deepSeekConfigSentinel,
                   "deepseek.config.toml 被意外改动")
        let roundTripBackupCount = try backupURLs(in: directory).count
        try expect(roundTripBackupCount == 3, "三次实际修改都应有独立备份")

        let unchangedResult = try editor.switchMode(to: .deepSeek)
        try expect(!unchangedResult.changed && unchangedResult.backupURL == nil,
                   "目标状态未变化时不应重复写入或备份")

        let permissions = try fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "原 config.toml 文件权限未保留")
    }

    static func testMissingProviderGuard() throws {
        let directory = try makeTemporaryCodexDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.toml")
        let original = "model_reasoning_effort = \"high\"\n[plugins.sample]\nenabled = true\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        let editor = CodexConfigEditor(codexDirectory: directory)

        do {
            _ = try editor.switchMode(to: .deepSeek)
            throw TestFailure.failed("provider 缺失时 DeepSeek 切换不应成功")
        } catch ConfigEditorError.deepSeekProviderMissing {
            // Expected.
        }

        let unchangedText = try String(contentsOf: configURL, encoding: .utf8)
        let unexpectedBackups = try backupURLs(in: directory)
        try expect(unchangedText == original,
                   "provider 缺失时配置发生了变化")
        try expect(unexpectedBackups.isEmpty,
                   "provider 缺失且未修改时不应创建误导性备份")
    }

    static func testRealConfigCopyIfRequested() throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["CODEX_SWITCHER_TEST_SOURCE_CONFIG"] else {
            return
        }

        let directory = try makeTemporaryCodexDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try fileManager.copyItem(at: URL(fileURLWithPath: sourcePath), to: configURL)

        let editor = CodexConfigEditor(codexDirectory: directory)
        _ = try editor.switchMode(to: .chatGPT)
        let chatGPTBaseline = try Data(contentsOf: configURL)
        _ = try editor.switchMode(to: .deepSeek)
        _ = try editor.switchMode(to: .chatGPT)
        let chatGPTAfterRoundTrip = try Data(contentsOf: configURL)
        let backupCount = try backupURLs(in: directory).count

        try expect(chatGPTAfterRoundTrip == chatGPTBaseline,
                   "真实配置副本来回切换后，无关内容没有逐字保持")
        try expect(backupCount >= 2,
                   "真实配置副本双向切换未创建预期备份")
    }

    static func main() throws {
        try testSyntheticRoundTrip()
        try testMissingProviderGuard()
        try testRealConfigCopyIfRequested()
        print("ConfigEditorTests: PASS")
    }
}
