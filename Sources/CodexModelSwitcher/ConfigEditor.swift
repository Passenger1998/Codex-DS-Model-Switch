import Foundation

func resolvedCodexDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    if let overridePath = environment["CODEX_SWITCHER_CODEX_HOME"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !overridePath.isEmpty {
        return URL(fileURLWithPath: overridePath, isDirectory: true).standardizedFileURL
    }

    return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
}

func resolvedClaudeDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    if let overridePath = environment["CODEX_SWITCHER_CLAUDE_HOME"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !overridePath.isEmpty {
        return URL(fileURLWithPath: overridePath, isDirectory: true).standardizedFileURL
    }

    return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
}

enum CodexMode: String {
    case chatGPT = "chatgpt"
    case deepSeek = "deepseek"

    var displayName: String {
        switch self {
        case .chatGPT:
            return "ChatGPT"
        case .deepSeek:
            return "DeepSeek V4 Pro"
        }
    }
}

enum ClaudeMode: String, CaseIterable {
    case official = "default"
    case deepSeekPro = "deepseek-pro"
    case deepSeekFlash = "deepseek-flash"

    var displayName: String {
        switch self {
        case .official:
            return "Claude 官方"
        case .deepSeekPro:
            return "DeepSeek V4 Pro"
        case .deepSeekFlash:
            return "DeepSeek V4 Flash"
        }
    }

    var cliArgument: String { rawValue }
}

enum ToolKind: String, CaseIterable {
    case codex = "codex"
    case claudeCode = "claude"

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        }
    }
}

struct ProviderStatus {
    let values: [String: String]

    init(output: String) {
        values = output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }

    var currentMode: CodexMode? {
        guard let state = values["current_state"] else { return nil }
        return CodexMode(rawValue: state)
    }

    var displayName: String {
        values["state_label"] ?? currentMode?.displayName ?? "未知"
    }

    var isConsistent: Bool {
        values["state_consistent"] == "yes" && currentMode != nil
    }
}

struct ClaudeStatus {
    let values: [String: String]

    init(output: String) {
        values = output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }

    var currentMode: ClaudeMode? {
        guard let state = values["current_state"] else { return nil }
        return ClaudeMode(rawValue: state)
    }

    var displayName: String {
        values["state_label"] ?? currentMode?.displayName ?? "未知"
    }

    var isConsistent: Bool {
        values["state_consistent"] == "yes" && currentMode != nil
    }

    var inconsistencyReason: String? {
        let reason = values["inconsistency_reason"] ?? ""
        return reason.isEmpty ? nil : reason
    }

    var desktopInstalled: Bool {
        values["desktop_installed"] == "yes"
    }

    var desktopVersion: String? {
        let version = values["desktop_version"] ?? ""
        return version.isEmpty ? nil : version
    }

    var claudeCodeInstalled: Bool {
        values["claude_code_installed"] == "yes"
    }

    var claudeCodeVersion: String? {
        let version = values["claude_code_version"] ?? ""
        return version.isEmpty ? nil : version
    }

    var cliInstalled: Bool {
        values["cli_installed"] == "yes"
    }

    var cliPath: String? {
        let path = values["cli_path"] ?? ""
        return path.isEmpty ? nil : path
    }

    var authPresent: Bool {
        values["auth"] == "keychain-helper"
    }

    var desktopProvider: String? {
        let provider = values["desktop_provider"] ?? ""
        return provider.isEmpty ? nil : provider
    }

    var desktopDefaultModel: String? {
        let model = values["desktop_default_model"] ?? ""
        return model.isEmpty ? nil : model
    }

    var deploymentMode: String? {
        let mode = values["deployment_mode"] ?? ""
        return mode.isEmpty ? nil : mode
    }

    var helperReady: Bool {
        values["helper_ready"] == "yes"
    }
}

struct ProviderCommandResult {
    let output: String
}

enum ProviderCommandError: LocalizedError {
    case executableMissing(path: String)
    case launchFailed(message: String)
    case commandFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .executableMissing(path):
            return "未找到模型切换命令：\n\(path)\n\n请确认已安装并具有执行权限。"
        case let .launchFailed(message):
            return "无法启动模型切换命令：\n\(message)"
        case let .commandFailed(status, message):
            return "模型切换失败（退出码 \(status)）：\n\(message)"
        }
    }
}

final class ProviderCommandRunner {
    private let fileManager: FileManager
    let executableURL: URL

    init(executableURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.executableURL = executableURL
    }

    func preflight() throws {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw ProviderCommandError.executableMissing(path: executableURL.path)
        }
    }

    func run(argument: String) throws -> ProviderCommandResult {
        try run(arguments: [argument])
    }

    func run(arguments: [String]) throws -> ProviderCommandResult {
        try preflight()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let combinedOutput = Pipe()
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput

        do {
            try process.run()
        } catch {
            throw ProviderCommandError.launchFailed(message: error.localizedDescription)
        }

        let data = combinedOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw ProviderCommandError.commandFailed(
                status: process.terminationStatus,
                message: output.isEmpty ? "未返回错误详情。" : output
            )
        }

        return ProviderCommandResult(output: output)
    }
}

final class CodexProviderCommand {
    private let runner: ProviderCommandRunner

    init(
        codexDirectory: URL,
        executableURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let url = executableURL
            ?? codexDirectory.appendingPathComponent("bin/codex-provider")
        self.runner = ProviderCommandRunner(executableURL: url, fileManager: fileManager)
    }

    var executableURL: URL { runner.executableURL }

    func preflight() throws {
        try runner.preflight()
    }

    func switchMode(to mode: CodexMode) throws -> ProviderCommandResult {
        try runner.run(argument: mode.rawValue)
    }

    func status() throws -> ProviderCommandResult {
        try runner.run(argument: "status")
    }
}

final class ClaudeProviderCommand {
    private let runner: ProviderCommandRunner

    init(
        codexDirectory: URL = resolvedCodexDirectory(),
        executableURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let url = executableURL
            ?? codexDirectory.appendingPathComponent("bin/claude-provider")
        self.runner = ProviderCommandRunner(executableURL: url, fileManager: fileManager)
    }

    var executableURL: URL { runner.executableURL }

    func preflight() throws {
        try runner.preflight()
    }

    func switchMode(to mode: ClaudeMode) throws -> ProviderCommandResult {
        try runner.run(argument: mode.cliArgument)
    }

    func status() throws -> ProviderCommandResult {
        try runner.run(argument: "status")
    }
}
