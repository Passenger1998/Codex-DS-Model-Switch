import AppKit
import Foundation

func printToStandardError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

let providerCommand = CodexProviderCommand(codexDirectory: resolvedCodexDirectory())
let codexAppRestarter = CodexAppRestarter()
let commandLineArguments = Array(CommandLine.arguments.dropFirst())

if !commandLineArguments.isEmpty {
    guard commandLineArguments.count == 1 else {
        printToStandardError("Usage: CodexModelSwitcher {chatgpt|deepseek-high|deepseek-max|deepseek|status}")
        exit(2)
    }

    do {
        let result: ProviderCommandResult
        switch commandLineArguments[0] {
        case "chatgpt":
            result = try providerCommand.switchMode(to: .chatGPT)
        case "deepseek", "deepseek-high":
            result = try providerCommand.switchMode(to: .deepSeekHigh)
        case "deepseek-max":
            result = try providerCommand.switchMode(to: .deepSeekMax)
        case "status":
            result = try providerCommand.status()
        default:
            printToStandardError("Usage: CodexModelSwitcher {chatgpt|deepseek-high|deepseek-max|deepseek|status}")
            exit(2)
        }
        print(result.output)
        exit(0)
    } catch {
        printToStandardError(error.localizedDescription)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

func showError(_ message: String) {
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Codex 模型切换器"
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
}

func showSuccess(mode: CodexMode, details: String, restartedExistingApplication: Bool) {
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "已切换到 \(mode.displayName)"
    let restartSummary = restartedExistingApplication
        ? "Codex 已自动退出并重新打开。"
        : "Codex 原未运行，现已自动打开。"
    // Older installed versions of codex-provider emitted this now-obsolete line.
    let visibleDetails = details.components(separatedBy: .newlines)
        .filter { $0 != "Existing sessions keep the provider they were created with." }
        .joined(separator: "\n")
    alert.informativeText = "\(restartSummary)之后新建的任务将使用刚选择的 Provider。\n\n\(visibleDetails)"
    alert.addButton(withTitle: "好")
    alert.runModal()
}

func chooseTarget(currentStatus: ProviderStatus) -> CodexMode? {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Codex 模型切换器"
    let consistencyNote = currentStatus.isConsistent ? "" : "（Codex 配置与 proxy 参数不一致）"
    alert.informativeText = "当前实际状态：\(currentStatus.displayName)\(consistencyNote)\n\n选择新任务要使用的状态。切换成功并通过健康检查后会自动退出并重新打开 Codex，正在执行的任务会被中断。每次切换前都会备份 config.toml 和 LaunchAgent。"
    alert.addButton(withTitle: "ChatGPT")
    alert.addButton(withTitle: "DeepSeek V4 Pro · High")
    alert.addButton(withTitle: "DeepSeek V4 Pro · Max")
    alert.addButton(withTitle: "取消")

    switch alert.runModal() {
    case .alertFirstButtonReturn:
        return .chatGPT
    case .alertSecondButtonReturn:
        return .deepSeekHigh
    case .alertThirdButtonReturn:
        return .deepSeekMax
    default:
        return nil
    }
}

do {
    try providerCommand.preflight()
} catch {
    showError(error.localizedDescription)
    exit(1)
}

let currentStatus: ProviderStatus
do {
    currentStatus = ProviderStatus(output: try providerCommand.status().output)
} catch {
    showError("无法读取当前实际状态：\n\n\(error.localizedDescription)")
    exit(1)
}

guard let target = chooseTarget(currentStatus: currentStatus) else {
    exit(0)
}

do {
    let result = try providerCommand.switchMode(to: target)
    do {
        let restartResult = try codexAppRestarter.restart()
        showSuccess(
            mode: target,
            details: result.output,
            restartedExistingApplication: restartResult.terminatedRunningApplication
        )
    } catch {
        showError("配置已成功切换到 \(target.displayName)，但 Codex 自动重启失败：\n\n\(error.localizedDescription)\n\n请手动退出并重新打开 Codex。")
        exit(1)
    }
} catch {
    showError(error.localizedDescription)
    exit(1)
}

exit(0)
