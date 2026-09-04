import AppKit

enum CredentialInputViewTests {
    static func testAlertLayout(includeName: Bool) throws {
        let alert = NSAlert()
        alert.messageText = includeName ? "新建 Credential Profile" : "替换 Work 的 API Key"
        alert.informativeText = "API Key 只会写入 macOS Keychain，不会保存在配置或日志中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = CredentialInputView(includeName: includeName)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input.initialInput
        alert.layout()
        alert.window.contentView?.layoutSubtreeIfNeeded()

        try ConfigEditorTests.expect(input.frame.width >= 360, "弹窗输入区域不能被压缩")
        try ConfigEditorTests.expect((input.nameField != nil) == includeName, "替换 Key 时不应显示名称框")
        try ConfigEditorTests.expect(input.keyField.cell is NSSecureTextFieldCell, "API Key 必须使用安全密码输入框")
        let fields = [input.nameField, input.keyField].compactMap { $0 }
        for field in fields {
            try ConfigEditorTests.expect(field.frame.width >= 350, "空输入框必须保持完整宽度")
            try ConfigEditorTests.expect(field.frame.height >= 24, "输入框高度不能被压缩")
            try ConfigEditorTests.expect(input.bounds.contains(field.frame), "输入框不能超出可见区域")
            try ConfigEditorTests.expect(!field.hasAmbiguousLayout, "输入框布局约束必须完整")
            try ConfigEditorTests.expect(field.isEditable, "输入框必须能够编辑")
            try ConfigEditorTests.expect(field.stringValue.isEmpty, "输入框不得回显已有凭据")
        }
    }

    static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try testAlertLayout(includeName: true)
        try testAlertLayout(includeName: false)
        print("CredentialInputViewTests: PASS (create + replace)")
    }
}
