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
            return "未找到安全切换命令：\n\(path)\n\n请确认 ~/.codex/bin/codex-provider 已安装且可执行。"
        case let .launchFailed(message):
            return "无法启动模型切换命令：\n\(message)"
        case let .commandFailed(status, message):
            return "模型切换失败（退出码 \(status)）：\n\(message)"
        }
    }
}

final class CodexProviderCommand {
    private let fileManager: FileManager
    let executableURL: URL

    init(
        codexDirectory: URL,
        executableURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.executableURL = executableURL
            ?? codexDirectory.appendingPathComponent("bin/codex-provider")
    }

    func preflight() throws {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw ProviderCommandError.executableMissing(path: executableURL.path)
        }
    }

    func switchMode(to mode: CodexMode) throws -> ProviderCommandResult {
        try run(argument: mode.rawValue)
    }

    func status() throws -> ProviderCommandResult {
        try run(argument: "status")
    }

    private func run(argument: String) throws -> ProviderCommandResult {
        try preflight()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [argument]

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
