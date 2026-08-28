import AppKit
import Foundation

func printToStandardError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

let codexCommand = CodexProviderCommand(codexDirectory: resolvedCodexDirectory())
let claudeCommand = ClaudeProviderCommand()
let codexAppRestarter = CodexAppRestarter()
let claudeAppRestarter = CodexAppRestarter(bundleIdentifier: "com.anthropic.claudefordesktop")
let commandLineArguments = Array(CommandLine.arguments.dropFirst())

// MARK: - CLI

private func usage() -> String {
    """
    Usage: CodexModelSwitcher <command>

      status                           显示 Codex 与 Claude Code 的当前状态
      codex chatgpt                    切换到 Codex · ChatGPT
      codex deepseek                   切换到 Codex · DeepSeek V4 Pro
      claude default                   切换到 Claude Code · Claude 官方
      claude deepseek-pro              切换到 Claude Code · DeepSeek V4 Pro
      claude deepseek-flash            切换到 Claude Code · DeepSeek V4 Flash

    兼容旧用法：chatgpt / deepseek 等价于 codex chatgpt / codex deepseek
    """
}

private func combinedStatus(
    codex: CodexProviderCommand,
    claude: ClaudeProviderCommand
) throws -> ProviderCommandResult {
    let codexOutput: String
    do {
        codexOutput = try codex.status().output
    } catch {
        codexOutput = "codex-provider 不可用：\(error.localizedDescription)"
    }

    let claudeOutput: String
    do {
        claudeOutput = try claude.status().output
    } catch {
        claudeOutput = "claude-provider 不可用：\(error.localizedDescription)"
    }

    let output = "== Codex ==\n\(codexOutput)\n\n== Claude Code ==\n\(claudeOutput)"
    return ProviderCommandResult(output: output)
}

if !commandLineArguments.isEmpty {
    do {
        let result: ProviderCommandResult
        if commandLineArguments.count == 1 {
            switch commandLineArguments[0] {
            case "status":
                result = try combinedStatus(codex: codexCommand, claude: claudeCommand)
            case "chatgpt":
                result = try codexCommand.switchMode(to: .chatGPT)
            case "deepseek":
                result = try codexCommand.switchMode(to: .deepSeek)
            default:
                printToStandardError(usage())
                exit(2)
            }
        } else if commandLineArguments.count == 2 {
            switch commandLineArguments[0] {
            case "codex":
                guard let codexMode = CodexMode(rawValue: commandLineArguments[1]) else {
                    printToStandardError(usage())
                    exit(2)
                }
                result = try codexCommand.switchMode(to: codexMode)
            case "claude":
                guard let claudeMode = ClaudeMode(rawValue: commandLineArguments[1]) else {
                    printToStandardError(usage())
                    exit(2)
                }
                result = try claudeCommand.switchMode(to: claudeMode)
            default:
                printToStandardError(usage())
                exit(2)
            }
        } else {
            printToStandardError(usage())
            exit(2)
        }
        print(result.output)
        exit(0)
    } catch {
        printToStandardError(error.localizedDescription)
        exit(1)
    }
}

// MARK: - GUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class SwitcherWindowController: NSObject {
    private let window: NSWindow
    private let toolPopup: NSPopUpButton
    private let modelPopup: NSPopUpButton
    private let statusLabel: NSTextField
    private let codexCommand: CodexProviderCommand
    private let claudeCommand: ClaudeProviderCommand
    private let codexRestarter: CodexAppRestarter
    private let claudeRestarter: CodexAppRestarter
    private let codexStatus: ProviderStatus
    private let claudeStatus: ClaudeStatus
    private let claudeAvailable: Bool

    private var codexModels: [(CodexMode, String)] = [
        (.chatGPT, CodexMode.chatGPT.displayName),
        (.deepSeek, CodexMode.deepSeek.displayName),
    ]
    private var claudeModels: [(ClaudeMode, String)] = ClaudeMode.allCases.map {
        ($0, $0.displayName)
    }

    init(
        codexCommand: CodexProviderCommand,
        claudeCommand: ClaudeProviderCommand,
        codexRestarter: CodexAppRestarter,
        claudeRestarter: CodexAppRestarter,
        codexStatus: ProviderStatus,
        claudeStatus: ClaudeStatus,
        claudeAvailable: Bool
    ) {
        self.codexCommand = codexCommand
        self.claudeCommand = claudeCommand
        self.codexRestarter = codexRestarter
        self.claudeRestarter = claudeRestarter
        self.codexStatus = codexStatus
        self.claudeStatus = claudeStatus
        self.claudeAvailable = claudeAvailable

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex & Claude Code 模型切换器"

        toolPopup = NSPopUpButton()
        toolPopup.addItems(withTitles: ToolKind.allCases.map(\.displayName))

        modelPopup = NSPopUpButton()

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 380

        super.init()

        toolPopup.target = self
        toolPopup.action = #selector(toolChanged(_:))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        content.addArrangedSubview(makeRow(label: "工具", control: toolPopup))
        content.addArrangedSubview(makeRow(label: "模型", control: modelPopup))

        let statusHeader = NSTextField(labelWithString: "当前状态：")
        statusHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        content.addArrangedSubview(statusHeader)
        content.addArrangedSubview(statusLabel)

        let switchButton = NSButton(title: "切换", target: nil, action: nil)
        switchButton.target = self
        switchButton.action = #selector(performSwitch(_:))
        switchButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: nil, action: nil)
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [switchButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        content.addArrangedSubview(buttonRow)

        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()

        // Reflect the real configuration in the initial selection.
        toolPopup.selectItem(at: 0)
        refreshModelPopup()
        refreshStatusLabel()
    }

    private func makeRow(label: String, control: NSView) -> NSStackView {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = NSStackView(views: [text, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private var selectedTool: ToolKind {
        ToolKind.allCases[toolPopup.indexOfSelectedItem]
    }

    private func refreshModelPopup() {
        modelPopup.removeAllItems()
        switch selectedTool {
        case .codex:
            modelPopup.addItems(withTitles: codexModels.map(\.1))
            switch codexStatus.currentMode {
            case .chatGPT: modelPopup.selectItem(at: 0)
            case .deepSeek: modelPopup.selectItem(at: 1)
            case nil: modelPopup.selectItem(at: 0)
            }
        case .claudeCode:
            modelPopup.addItems(withTitles: claudeModels.map(\.1))
            let index = ClaudeMode.allCases.firstIndex(of: claudeStatus.currentMode ?? .official) ?? 0
            modelPopup.selectItem(at: index)
        }
    }

    private func refreshStatusLabel() {
        switch selectedTool {
        case .codex:
            var text = "Codex · \(codexStatus.displayName)"
            if !codexStatus.isConsistent {
                text += "（配置不一致）"
            }
            statusLabel.stringValue = text
        case .claudeCode:
            var text = "Claude Code · \(claudeStatus.displayName)"
            if !claudeStatus.isConsistent {
                if let reason = claudeStatus.inconsistencyReason {
                    text += "（配置不一致：\(reason)）"
                } else {
                    text += "（配置不一致）"
                }
            }
            if !claudeAvailable {
                text += "（claude-provider 未安装，请运行 ./install.sh）"
            }
            var lines = [text]
            if claudeStatus.desktopInstalled {
                lines.append("Claude Desktop \(claudeStatus.desktopVersion ?? "")（内置 Claude Code \(claudeStatus.claudeCodeInstalled ? (claudeStatus.claudeCodeVersion ?? "已安装") : "不可用")）")
            } else {
                lines.append("Claude Desktop 未安装")
            }
            if claudeStatus.cliInstalled {
                lines.append("独立 Claude CLI：\(claudeStatus.cliPath ?? "已安装")")
            } else {
                lines.append("独立 Claude CLI：未安装（不影响 Desktop 内置 Claude Code）")
            }
            if claudeStatus.currentMode == .deepSeekPro || claudeStatus.currentMode == .deepSeekFlash {
                let providerText = claudeStatus.desktopProvider == "gateway"
                    ? "Desktop Provider：DeepSeek 网关（已接入）"
                    : "Desktop Provider：未接入 DeepSeek 网关（可选；内置 Claude Code 已通过 settings.json 工作）"
                lines.append(providerText)
            }
            if !claudeStatus.authPresent && claudeStatus.currentMode != .official {
                lines.append("缺少 Keychain 凭据 claude-code-deepseek-api-key")
            }
            statusLabel.stringValue = lines.joined(separator: "\n")
        }
    }

    @objc private func toolChanged(_ sender: NSPopUpButton) {
        refreshModelPopup()
        refreshStatusLabel()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        refreshStatusLabel()
    }

    private func selectedCodexMode() -> CodexMode {
        codexModels[modelPopup.indexOfSelectedItem].0
    }

    private func selectedClaudeMode() -> ClaudeMode {
        claudeModels[modelPopup.indexOfSelectedItem].0
    }

    @objc private func cancel(_ sender: NSButton) {
        NSApp.terminate(nil)
    }

    @objc private func performSwitch(_ sender: NSButton) {
        switch selectedTool {
        case .codex:
            switchCodex()
        case .claudeCode:
            switchClaude()
        }
    }

    private func switchCodex() {
        let target = selectedCodexMode()
        do {
            let result = try codexCommand.switchMode(to: target)
            do {
                let restartResult = try codexRestarter.restart()
                showSuccess(
                    title: "已切换到 Codex · \(target.displayName)",
                    details: result.output,
                    extra: restartResult.terminatedRunningApplication
                        ? "Codex 已自动退出并重新打开。"
                        : "Codex 原未运行，现已自动打开。"
                )
            } catch {
                showError(
                    "配置已成功切换到 \(target.displayName)，但 Codex 自动重启失败：\n\n"
                        + "\(error.localizedDescription)\n\n请手动退出并重新打开 Codex。"
                )
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func switchClaude() {
        let target = selectedClaudeMode()
        do {
            let result = try claudeCommand.switchMode(to: target)
            do {
                let restartResult = try claudeRestarter.restart()
                let modelNote = target == .official
                    ? "Claude Desktop 已恢复官方 Provider。"
                    : "DeepSeek 已接入：请求经 api.deepseek.com/anthropic 直达 DeepSeek。"
                        + "\(target.displayName) 已设为默认；请在 Claude Desktop 的模型选择器中确认选择"
                        + "（DeepSeek V4 Pro → Opus 档、DeepSeek V4 Flash → Sonnet/Haiku 档）。"
                showSuccess(
                    title: "已切换到 Claude Code · \(target.displayName)",
                    details: result.output,
                    extra: restartResult.terminatedRunningApplication
                        ? "Claude Desktop 已自动退出并重新打开。\(modelNote)"
                        : "Claude Desktop 原未运行，现已打开。\(modelNote)"
                )
            } catch {
                showError(
                    "配置已成功切换到 \(target.displayName)，但 Claude Desktop 自动重启失败：\n\n"
                        + "\(error.localizedDescription)\n\n请手动退出并重新打开 Claude Desktop 后生效。"
                )
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showSuccess(title: String, details: String, extra: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = "\(extra)\n\n\(details)"
        alert.addButton(withTitle: "好")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Codex & Claude Code 模型切换器"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }
}

// Preflight Codex (required) and read the real state of both tools.
do {
    try codexCommand.preflight()
} catch {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Codex 模型切换器"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "好")
    alert.runModal()
    exit(1)
}

let currentCodexStatus: ProviderStatus
do {
    currentCodexStatus = ProviderStatus(output: try codexCommand.status().output)
} catch {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Codex 模型切换器"
    alert.informativeText = "无法读取 Codex 当前实际状态：\n\n\(error.localizedDescription)"
    alert.addButton(withTitle: "好")
    alert.runModal()
    exit(1)
}

var currentClaudeStatus = ClaudeStatus(output: "")
var claudeAvailable = false
do {
    let output = try claudeCommand.status().output
    currentClaudeStatus = ClaudeStatus(output: output)
    claudeAvailable = true
} catch {
    currentClaudeStatus = ClaudeStatus(output: "")
    claudeAvailable = false
}

let controller = SwitcherWindowController(
    codexCommand: codexCommand,
    claudeCommand: claudeCommand,
    codexRestarter: codexAppRestarter,
    claudeRestarter: claudeAppRestarter,
    codexStatus: currentCodexStatus,
    claudeStatus: currentClaudeStatus,
    claudeAvailable: claudeAvailable
)
controller.show()

app.run()
