import Foundation

enum ClaudeProviderTests {
    static let fileManager = FileManager.default

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure.failed(message)
        }
    }

    static func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-model-switcher-claude-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func testClaudeStatusParsing() throws {
        let official = ClaudeStatus(output: """
        current_state=default
        state_label=Claude 官方
        state_consistent=yes
        desktop_installed=yes
        desktop_version=1.34493.1
        claude_code_installed=yes
        claude_code_version=2.1.237
        cli_installed=no
        auth=keychain-helper
        """)
        let pro = ClaudeStatus(output: """
        current_state=deepseek-pro
        state_label=DeepSeek V4 Pro
        state_consistent=yes
        desktop_installed=yes
        claude_code_installed=yes
        desktop_provider=gateway
        desktop_default_model=claude-opus-5
        deployment_mode=3p
        helper_ready=yes
        auth=keychain-helper
        credential_profile_id=profile-b
        credential_profile_name=Work
        credential_profile_key=present
        """)
        let inconsistent = ClaudeStatus(output: """
        current_state=inconsistent
        state_label=配置不一致
        state_consistent=no
        inconsistency_reason=base_url 指向 DeepSeek 但 model 未知
        desktop_installed=no
        claude_code_installed=no
        cli_installed=no
        auth=MISSING
        """)

        try expect(official.currentMode == .official, "Claude 官方状态解析错误")
        try expect(official.displayName == "Claude 官方", "Claude 官方显示名错误")
        try expect(official.isConsistent, "Claude 官方应标记为一致")
        try expect(official.desktopInstalled, "desktopInstalled 应为 true")
        try expect(official.desktopVersion == "1.34493.1", "desktopVersion 解析错误")
        try expect(official.claudeCodeInstalled, "claudeCodeInstalled 应为 true")
        try expect(official.claudeCodeVersion == "2.1.237", "claudeCodeVersion 解析错误")
        try expect(!official.cliInstalled, "cliInstalled 应为 false")
        try expect(official.authPresent, "authPresent 应为 true")

        try expect(pro.currentMode == .deepSeekPro, "DeepSeek Pro 状态解析错误")
        try expect(pro.displayName == "DeepSeek V4 Pro", "DeepSeek Pro 显示名错误")
        try expect(pro.desktopProvider == "gateway", "desktopProvider 解析错误")
        try expect(pro.desktopDefaultModel == "claude-opus-5", "desktopDefaultModel 解析错误")
        try expect(pro.deploymentMode == "3p", "deploymentMode 解析错误")
        try expect(pro.helperReady, "helperReady 应为 true")
        try expect(pro.credentialProfileID == "profile-b", "Claude Credential Profile ID 解析错误")
        try expect(pro.credentialProfileName == "Work", "Claude Credential Profile 名称解析错误")
        try expect(pro.credentialKeyPresent, "Claude Credential Profile Key 应存在")

        try expect(inconsistent.currentMode == nil, "不一致状态不应映射为可选模式")
        try expect(!inconsistent.isConsistent, "不一致状态应被识别")
        try expect(inconsistent.inconsistencyReason != nil, "不一致状态应带原因")
        try expect(!inconsistent.desktopInstalled, "未安装 Desktop 时应为 false")
        try expect(!inconsistent.claudeCodeInstalled, "无内置 Claude Code 时应为 false")
        try expect(!inconsistent.cliInstalled, "无独立 CLI 时应为 false")
        try expect(!inconsistent.authPresent, "无凭据时应为 false")
    }

    static func testClaudeCommandArgumentsAndOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("claude-provider")
        try writeExecutable("#!/bin/sh\nprintf 'args=%s\\n' \"$*\"\n", to: executable)
        let command = ClaudeProviderCommand(
            codexDirectory: directory,
            executableURL: executable
        )

        let defaultResult = try command.switchMode(to: .official)
        let proResult = try command.switchMode(to: .deepSeekPro, credentialProfileID: "profile-a")
        let flashResult = try command.switchMode(to: .deepSeekFlash, credentialProfileID: "profile-b")
        let statusResult = try command.status()

        try expect(defaultResult.output == "args=default", "Claude 官方参数传递错误")
        try expect(proResult.output == "args=deepseek-pro --credential profile-a", "DeepSeek Pro 参数传递错误")
        try expect(flashResult.output == "args=deepseek-flash --credential profile-b", "DeepSeek Flash 参数传递错误")
        try expect(statusResult.output == "args=status", "status 参数传递错误")
    }

    static func testClaudeDirectoryOverride() throws {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let defaultDirectory = resolvedClaudeDirectory(environment: [:], homeDirectory: homeDirectory)
        let overriddenDirectory = resolvedClaudeDirectory(
            environment: ["CODEX_SWITCHER_CLAUDE_HOME": "/tmp/isolated-claude-home"],
            homeDirectory: homeDirectory
        )
        try expect(defaultDirectory.path == "/Users/example/.claude", "默认应使用用户 ~/.claude")
        try expect(overriddenDirectory.path == "/tmp/isolated-claude-home", "测试目录覆盖未生效")
    }

    static func testToolAndModeDisplayNames() throws {
        try expect(ToolKind.codex.displayName == "Codex", "Codex 工具显示名错误")
        try expect(ToolKind.claudeCode.displayName == "Claude Code", "Claude Code 工具显示名错误")
        try expect(ClaudeMode.official.displayName == "Claude 官方", "Claude 官方显示名错误")
        try expect(ClaudeMode.deepSeekFlash.displayName == "DeepSeek V4 Flash", "Flash 显示名错误")
    }

    static func run() throws {
        try testClaudeStatusParsing()
        try testClaudeCommandArgumentsAndOutput()
        try testClaudeDirectoryOverride()
        try testToolAndModeDisplayNames()
        print("ClaudeProviderTests: PASS")
    }
}
