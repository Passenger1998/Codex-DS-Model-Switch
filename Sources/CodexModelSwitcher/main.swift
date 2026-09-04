import AppKit
import Darwin
import Foundation

func printToStandardError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

let codexCommand = CodexProviderCommand(codexDirectory: resolvedCodexDirectory())
let bundledClaudeProvider = Bundle.main.url(
    forResource: "claude-provider",
    withExtension: nil
)
let claudeCommand = ClaudeProviderCommand(executableURL: bundledClaudeProvider)
let codexCredentialStore = CredentialProfileStore(
    scope: .codex,
    homeDirectory: resolvedCodexDirectory()
)
let claudeCredentialStore = CredentialProfileStore(
    scope: .claude,
    homeDirectory: resolvedClaudeDirectory()
)
// Upgrade legacy single-key users before providers derive their real state.
// Migration copies only inside Keychain and retains the old item.
try? codexCredentialStore.ensureLegacyMigration()
try? claudeCredentialStore.ensureLegacyMigration()
let codexAppRestarter = CodexAppRestarter()
let claudeAppRestarter = CodexAppRestarter(bundleIdentifier: "com.anthropic.claudefordesktop")
let commandLineArguments = Array(CommandLine.arguments.dropFirst())

// MARK: - CLI

private func usage() -> String {
    """
    Usage: CodexModelSwitcher <command>

      status                           显示 Codex 与 Claude Code 的当前状态
      codex chatgpt                    切换到 Codex · ChatGPT
      codex deepseek [--credential <Profile>]
                                       切换到 Codex · DeepSeek V4 Pro
      claude default                   切换到 Claude Code · Claude 官方
      claude deepseek-pro [--credential <Profile>]
      claude deepseek-flash [--credential <Profile>]
                                       切换 Claude Code DeepSeek 模型与凭据
      credentials list <codex|claude>  列出 Credential Profiles
      credentials add <codex|claude> <name>
                                       新建 Profile（API Key 从安全输入读取）
      credentials update <codex|claude> <Profile>
                                       替换 Profile 的 API Key
      credentials remove <codex|claude> <Profile>
                                       删除 Profile

    兼容旧用法：chatgpt / deepseek 等价于 codex chatgpt / codex deepseek
    """
}

private func credentialScope(_ raw: String) -> CredentialProfileScope? {
    CredentialProfileScope(rawValue: raw)
}

private func credentialStore(for scope: CredentialProfileScope) -> CredentialProfileStore {
    scope == .codex ? codexCredentialStore : claudeCredentialStore
}

private func readSecureCredential(prompt: String) throws -> String {
    FileHandle.standardError.write(Data(prompt.utf8))
    var settings = termios()
    let isTerminal = isatty(STDIN_FILENO) == 1 && tcgetattr(STDIN_FILENO, &settings) == 0
    let original = settings
    if isTerminal {
        settings.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings) == 0 else {
            throw CredentialProfileError.io("无法关闭终端回显，已取消 API Key 输入")
        }
    }
    defer {
        if isTerminal {
            var restored = original
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored)
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
    guard let value = readLine(), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CredentialProfileError.invalidName("API Key 不能为空")
    }
    return value
}

private func credentialIsCurrentlyUsed(
    scope: CredentialProfileScope,
    profile: CredentialProfile
) -> Bool {
    do {
        switch scope {
        case .codex:
            let status = ProviderStatus(output: try codexCommand.status().output)
            return status.values["provider"] == "deepseek"
                && status.credentialProfileID == profile.id
        case .claude:
            let status = ClaudeStatus(output: try claudeCommand.status().output)
            return status.deploymentMode == "3p"
                && status.credentialProfileID == profile.id
        }
    } catch {
        return true
    }
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
        if commandLineArguments.first == "credentials" {
            guard commandLineArguments.count >= 3,
                  let scope = credentialScope(commandLineArguments[2]) else {
                printToStandardError(usage())
                exit(2)
            }
            let store = credentialStore(for: scope)
            switch commandLineArguments[1] {
            case "list" where commandLineArguments.count == 3:
                let state = try store.state()
                for profile in state.profiles {
                    let active = profile.id == state.activeProfileId ? "active" : "inactive"
                    let key = store.keyExists(for: profile) ? "key=present" : "key=missing"
                    print("\(profile.id)\t\(profile.displayName)\t\(active)\t\(key)")
                }
                exit(0)
            case "add" where commandLineArguments.count == 4:
                let secret = try readSecureCredential(prompt: "DeepSeek API Key: ")
                let profile = try store.create(displayName: commandLineArguments[3], apiKey: secret)
                print("Credential Profile 已创建：\(profile.displayName) (\(profile.id))")
                exit(0)
            case "update" where commandLineArguments.count == 4:
                let profile = try store.profile(reference: commandLineArguments[3])
                let secret = try readSecureCredential(prompt: "New DeepSeek API Key: ")
                try store.replaceKey(for: profile, apiKey: secret)
                print("Credential Profile API Key 已替换：\(profile.displayName)")
                exit(0)
            case "remove" where commandLineArguments.count == 4:
                let profile = try store.profile(reference: commandLineArguments[3])
                try store.remove(
                    profile,
                    currentlyUsed: { credentialIsCurrentlyUsed(scope: scope, profile: profile) }
                )
                print("Credential Profile 已删除：\(profile.displayName)")
                exit(0)
            default:
                printToStandardError(usage())
                exit(2)
            }
        } else if commandLineArguments.count == 1 {
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
        } else if commandLineArguments.count == 2 || commandLineArguments.count == 4 {
            let credential: String?
            if commandLineArguments.count == 4 {
                guard commandLineArguments[2] == "--credential" else {
                    printToStandardError(usage())
                    exit(2)
                }
                credential = commandLineArguments[3]
            } else {
                credential = nil
            }
            switch commandLineArguments[0] {
            case "codex":
                guard let codexMode = CodexMode(rawValue: commandLineArguments[1]) else {
                    printToStandardError(usage())
                    exit(2)
                }
                guard credential == nil || codexMode == .deepSeek else {
                    printToStandardError(usage())
                    exit(2)
                }
                result = try codexCommand.switchMode(to: codexMode, credentialProfileID: credential)
            case "claude":
                guard let claudeMode = ClaudeMode(rawValue: commandLineArguments[1]) else {
                    printToStandardError(usage())
                    exit(2)
                }
                guard credential == nil || claudeMode != .official else {
                    printToStandardError(usage())
                    exit(2)
                }
                result = try claudeCommand.switchMode(to: claudeMode, credentialProfileID: credential)
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
    private let credentialPopup: NSPopUpButton
    private let addCredentialButton: NSButton
    private let replaceCredentialButton: NSButton
    private let deleteCredentialButton: NSButton
    private let statusLabel: NSTextField
    private let codexCommand: CodexProviderCommand
    private let claudeCommand: ClaudeProviderCommand
    private let codexRestarter: CodexAppRestarter
    private let claudeRestarter: CodexAppRestarter
    private let codexCredentialStore: CredentialProfileStore
    private let claudeCredentialStore: CredentialProfileStore
    private var codexStatus: ProviderStatus
    private var claudeStatus: ClaudeStatus
    private let claudeAvailable: Bool
    private var visibleCredentialProfiles: [CredentialProfile] = []
    private var credentialLoadError: String?

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
        codexCredentialStore: CredentialProfileStore,
        claudeCredentialStore: CredentialProfileStore,
        codexStatus: ProviderStatus,
        claudeStatus: ClaudeStatus,
        claudeAvailable: Bool
    ) {
        self.codexCommand = codexCommand
        self.claudeCommand = claudeCommand
        self.codexRestarter = codexRestarter
        self.claudeRestarter = claudeRestarter
        self.codexCredentialStore = codexCredentialStore
        self.claudeCredentialStore = claudeCredentialStore
        self.codexStatus = codexStatus
        self.claudeStatus = claudeStatus
        self.claudeAvailable = claudeAvailable

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex & Claude Code 模型切换器"

        toolPopup = NSPopUpButton()
        toolPopup.addItems(withTitles: ToolKind.allCases.map(\.displayName))

        modelPopup = NSPopUpButton()

        credentialPopup = NSPopUpButton()
        credentialPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        addCredentialButton = NSButton(title: "新建…", target: nil, action: nil)
        replaceCredentialButton = NSButton(title: "替换 Key…", target: nil, action: nil)
        deleteCredentialButton = NSButton(title: "删除", target: nil, action: nil)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 380

        super.init()

        toolPopup.target = self
        toolPopup.action = #selector(toolChanged(_:))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        addCredentialButton.target = self
        addCredentialButton.action = #selector(addCredential(_:))
        replaceCredentialButton.target = self
        replaceCredentialButton.action = #selector(replaceCredential(_:))
        deleteCredentialButton.target = self
        deleteCredentialButton.action = #selector(deleteCredential(_:))

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        content.addArrangedSubview(makeRow(label: "工具", control: toolPopup))
        content.addArrangedSubview(makeRow(label: "模型", control: modelPopup))
        let credentialControls = NSStackView(views: [
            credentialPopup,
            addCredentialButton,
            replaceCredentialButton,
            deleteCredentialButton,
        ])
        credentialControls.orientation = .horizontal
        credentialControls.alignment = .centerY
        credentialControls.spacing = 6
        content.addArrangedSubview(makeRow(label: "API Key", control: credentialControls))

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
        refreshCredentialPopup()
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

    private var selectedCredentialStore: CredentialProfileStore {
        selectedTool == .codex ? codexCredentialStore : claudeCredentialStore
    }

    private var selectedCredentialProfile: CredentialProfile? {
        let index = credentialPopup.indexOfSelectedItem
        guard index >= 0, index < visibleCredentialProfiles.count else { return nil }
        return visibleCredentialProfiles[index]
    }

    private var selectedModeUsesDeepSeek: Bool {
        switch selectedTool {
        case .codex: return selectedCodexMode() == .deepSeek
        case .claudeCode: return selectedClaudeMode() != .official
        }
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

    private func currentCredentialProfileID() -> String? {
        switch selectedTool {
        case .codex: return codexStatus.credentialProfileID
        case .claudeCode: return claudeStatus.credentialProfileID
        }
    }

    private func refreshCredentialPopup(preferredProfileID: String? = nil) {
        credentialPopup.removeAllItems()
        visibleCredentialProfiles = []
        credentialLoadError = nil

        guard selectedModeUsesDeepSeek else {
            credentialPopup.addItem(withTitle: "不适用（官方 Provider）")
            credentialPopup.isEnabled = false
            addCredentialButton.isEnabled = false
            replaceCredentialButton.isEnabled = false
            deleteCredentialButton.isEnabled = false
            return
        }

        addCredentialButton.isEnabled = true
        do {
            visibleCredentialProfiles = try selectedCredentialStore.profiles()
            if visibleCredentialProfiles.isEmpty {
                credentialPopup.addItem(withTitle: "尚无 Credential Profile")
                credentialPopup.isEnabled = false
                replaceCredentialButton.isEnabled = false
                deleteCredentialButton.isEnabled = false
                return
            }
            credentialPopup.addItems(withTitles: visibleCredentialProfiles.map(\.displayName))
            credentialPopup.isEnabled = true
            replaceCredentialButton.isEnabled = true
            deleteCredentialButton.isEnabled = true
            let wanted = preferredProfileID ?? currentCredentialProfileID()
            if let wanted,
               let index = visibleCredentialProfiles.firstIndex(where: { $0.id == wanted }) {
                credentialPopup.selectItem(at: index)
            } else {
                credentialPopup.selectItem(at: 0)
            }
        } catch {
            credentialLoadError = error.localizedDescription
            credentialPopup.addItem(withTitle: "无法读取 Credential Profiles")
            credentialPopup.isEnabled = false
            replaceCredentialButton.isEnabled = false
            deleteCredentialButton.isEnabled = false
        }
    }

    private func refreshStatusLabel() {
        switch selectedTool {
        case .codex:
            var lines = ["Codex · \(codexStatus.displayName)"]
            if !codexStatus.isConsistent {
                let reason = codexStatus.inconsistencyReason ?? "未知原因"
                lines[0] += "（配置不一致：\(reason)）"
            }
            if codexStatus.currentMode == .deepSeek || codexStatus.values["provider"] == "deepseek" {
                let name = codexStatus.credentialProfileName ?? codexStatus.credentialProfileID ?? "未选择"
                let keyState = codexStatus.credentialKeyPresent ? "Keychain 已就绪" : "Keychain 缺失"
                lines.append("Credential Profile：\(name)（\(keyState)）")
            }
            if let credentialLoadError {
                lines.append("凭据元数据错误：\(credentialLoadError)")
            }
            statusLabel.stringValue = lines.joined(separator: "\n")
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
            if claudeStatus.desktopProvider == "gateway" {
                let providerText = claudeStatus.desktopProvider == "gateway"
                    ? "Desktop Provider：DeepSeek Gateway（3P 配置库已接入）"
                    : "Desktop Provider：未从 Claude-3p 活动配置识别到 DeepSeek Gateway"
                lines.append(providerText)
                let name = claudeStatus.credentialProfileName ?? claudeStatus.credentialProfileID ?? "未选择"
                let keyState = claudeStatus.credentialKeyPresent ? "Keychain 已就绪" : "Keychain 缺失"
                lines.append("Credential Profile：\(name)（\(keyState)）")
            }
            if !claudeStatus.authPresent && claudeStatus.currentMode != .official {
                lines.append("缺少 Keychain 凭据 claude-code-deepseek-api-key")
            }
            if !claudeStatus.helperReady && claudeStatus.currentMode != .official {
                lines.append("缺少或无法执行 ~/.claude/deepseek-keychain-helper")
            }
            if let credentialLoadError {
                lines.append("凭据元数据错误：\(credentialLoadError)")
            }
            statusLabel.stringValue = lines.joined(separator: "\n")
        }
    }

    @objc private func toolChanged(_ sender: NSPopUpButton) {
        refreshModelPopup()
        refreshCredentialPopup()
        refreshStatusLabel()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        refreshCredentialPopup()
        refreshStatusLabel()
    }

    private func selectedCodexMode() -> CodexMode {
        codexModels[modelPopup.indexOfSelectedItem].0
    }

    private func selectedClaudeMode() -> ClaudeMode {
        claudeModels[modelPopup.indexOfSelectedItem].0
    }

    private func promptForCredential(
        title: String,
        includeName: Bool
    ) -> (name: String?, key: String)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = "API Key 只会写入 macOS Keychain，不会保存在配置或日志中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let inputView = CredentialInputView(includeName: includeName)
        alert.accessoryView = inputView
        alert.window.initialFirstResponder = inputView.initialInput
        defer { inputView.keyField.stringValue = "" }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (inputView.nameField?.stringValue, inputView.keyField.stringValue)
    }

    private func reloadProviderStatuses() {
        if let output = try? codexCommand.status().output {
            codexStatus = ProviderStatus(output: output)
        }
        if let output = try? claudeCommand.status().output {
            claudeStatus = ClaudeStatus(output: output)
        }
    }

    @objc private func addCredential(_ sender: NSButton) {
        guard let input = promptForCredential(title: "新建 Credential Profile", includeName: true),
              let name = input.name else { return }
        do {
            let profile = try selectedCredentialStore.create(displayName: name, apiKey: input.key)
            reloadProviderStatuses()
            refreshCredentialPopup(preferredProfileID: profile.id)
            refreshStatusLabel()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func replaceCredential(_ sender: NSButton) {
        guard let profile = selectedCredentialProfile,
              let input = promptForCredential(
                title: "替换 \(profile.displayName) 的 API Key",
                includeName: false
              ) else { return }
        do {
            try selectedCredentialStore.replaceKey(for: profile, apiKey: input.key)
            reloadProviderStatuses()
            refreshCredentialPopup(preferredProfileID: profile.id)
            refreshStatusLabel()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func deleteCredential(_ sender: NSButton) {
        guard let profile = selectedCredentialProfile else { return }
        let toolScope: CredentialProfileScope = selectedTool == .codex ? .codex : .claude
        if credentialIsCurrentlyUsed(scope: toolScope, profile: profile) {
            showError(
                CredentialProfileError.activeProfileCannotBeDeleted(profile.displayName)
                    .localizedDescription
            )
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除 Credential Profile“\(profile.displayName)”？"
        alert.informativeText = "这会删除该 Profile 的 Keychain 条目，不可恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try selectedCredentialStore.remove(
                profile,
                currentlyUsed: { credentialIsCurrentlyUsed(scope: toolScope, profile: profile) }
            )
            reloadProviderStatuses()
            refreshCredentialPopup()
            refreshStatusLabel()
        } catch {
            showError(error.localizedDescription)
        }
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
            let credentialID: String?
            if target == .deepSeek {
                guard let profile = selectedCredentialProfile else {
                    showError("请先新建并选择 Credential Profile。")
                    return
                }
                credentialID = profile.id
            } else {
                credentialID = nil
            }
            let result = try codexCommand.switchMode(
                to: target,
                credentialProfileID: credentialID
            )
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
            let credentialID: String?
            if target != .official {
                guard let profile = selectedCredentialProfile else {
                    showError("请先新建并选择 Credential Profile。")
                    return
                }
                credentialID = profile.id
            } else {
                credentialID = nil
            }
            let result = try claudeCommand.switchMode(
                to: target,
                credentialProfileID: credentialID
            )
            do {
                let restartResult = try claudeRestarter.restart()
                let modelNote = target == .official
                    ? "Claude Desktop 已恢复官方 Provider。"
                    : "DeepSeek 已接入：请求经 api.deepseek.com/anthropic 直达 DeepSeek。"
                        + "\(target.displayName) 已作为 Claude-3p 活动配置的首个模型："
                        + "DeepSeek V4 Pro → Opus tier，DeepSeek V4 Flash → Sonnet tier。"
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
    codexCredentialStore: codexCredentialStore,
    claudeCredentialStore: claudeCredentialStore,
    codexStatus: currentCodexStatus,
    claudeStatus: currentClaudeStatus,
    claudeAvailable: claudeAvailable
)
controller.show()

app.run()
