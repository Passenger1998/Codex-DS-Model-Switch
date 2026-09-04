import AppKit

/// A fixed-size alert accessory whose inputs fill the available width.
/// Empty text fields must not rely on their very small intrinsic width.
final class CredentialInputView: NSView {
    let nameField: NSTextField?
    let keyField = NSSecureTextField()

    var initialInput: NSTextField { nameField ?? keyField }

    init(includeName: Bool) {
        nameField = includeName ? NSTextField() : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: includeName ? 112 : 48))

        widthAnchor.constraint(equalToConstant: 360).isActive = true
        heightAnchor.constraint(equalToConstant: frame.height).isActive = true

        var precedingInput: NSTextField?
        if let nameField {
            nameField.placeholderString = "例如 Personal / Work / Backup"
            addInput(nameField, label: "Profile 名称", below: nil)
            precedingInput = nameField
        }

        keyField.placeholderString = "粘贴 DeepSeek API Key"
        addInput(keyField, label: "API Key", below: precedingInput)
        keyField.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addInput(_ field: NSTextField, label title: String, below previous: NSTextField?) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.setAccessibilityLabel(title)

        for view in [label, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? topAnchor,
                                       constant: previous == nil ? 0 : 16),
            label.heightAnchor.constraint(equalToConstant: 17),
            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 5),
            field.heightAnchor.constraint(equalToConstant: 26),
        ])
    }
}
