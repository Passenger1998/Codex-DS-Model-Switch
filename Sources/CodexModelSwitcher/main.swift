import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let chatGPTBundleID = "com.openai.codex"

func homeDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}

func codexDirectory() -> URL {
    homeDirectory().appendingPathComponent(".codex")
}

func chatGPTAppURL() -> URL? {
    let candidates = [
        URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        homeDirectory().appendingPathComponent("Applications/ChatGPT.app"),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

func showError(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "CodexModelSwitcher"
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
}

func chooseTarget() -> CodexMode? {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "CodexModelSwitcher"
    alert.informativeText = "选择要使用的模型。切换前会自动退出 ChatGPT，完成后自动重新打开。"
    alert.addButton(withTitle: "DeepSeek")
    alert.addButton(withTitle: "ChatGPT（恢复默认）")

    switch alert.runModal() {
    case .alertFirstButtonReturn:
        return .deepSeek
    case .alertSecondButtonReturn:
        return .chatGPT
    default:
        return nil
    }
}

func runningChatGPTApps() -> [NSRunningApplication] {
    let byBundleID = NSRunningApplication.runningApplications(withBundleIdentifier: chatGPTBundleID)
    if !byBundleID.isEmpty {
        return byBundleID
    }
    return NSWorkspace.shared.runningApplications.filter { runningApp in
        runningApp.localizedName?.lowercased() == "chatgpt"
    }
}

func quitChatGPT() -> Bool {
    if runningChatGPTApps().isEmpty {
        return true
    }

    for runningApp in runningChatGPTApps() {
        _ = runningApp.terminate()
    }

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if runningChatGPTApps().isEmpty {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    for runningApp in runningChatGPTApps() {
        _ = runningApp.terminate()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    return runningChatGPTApps().isEmpty
}

func reopenChatGPT() -> Bool {
    guard let appURL = chatGPTAppURL() else { return false }
    return NSWorkspace.shared.open(appURL)
}

guard let target = chooseTarget() else {
    exit(0)
}

let editor = CodexConfigEditor(codexDirectory: codexDirectory())
do {
    try editor.preflight(mode: target)
} catch {
    showError(error.localizedDescription)
    exit(1)
}

let appExists = chatGPTAppURL() != nil
if appExists {
    if !quitChatGPT() {
        showError("无法完全退出 ChatGPT。请手动按 ⌘Q 退出后重试。")
        exit(1)
    }
} else {
    showError("未找到 ChatGPT.app，将只切换 Codex 配置，不会重启 ChatGPT。")
}

do {
    _ = try editor.switchMode(to: target)
} catch {
    if appExists {
        _ = reopenChatGPT()
    }
    showError(error.localizedDescription)
    exit(1)
}

if appExists, !reopenChatGPT() {
    showError("配置已切换，但未能自动重新打开 ChatGPT。请手动打开 ChatGPT。")
    exit(1)
}

exit(0)
