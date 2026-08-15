import Foundation

enum CodexMode: String {
    case chatGPT
    case deepSeek

    var displayName: String {
        switch self {
        case .chatGPT:
            return "ChatGPT"
        case .deepSeek:
            return "DeepSeek V4 Pro"
        }
    }
}

struct ConfigSwitchResult {
    let mode: CodexMode
    let backupURL: URL?
    let changed: Bool
}

enum ConfigEditorError: LocalizedError {
    case configMissing(path: String)
    case unreadableConfig(message: String)
    case invalidUTF8
    case deepSeekProviderMissing
    case duplicateTopLevelKey(String)
    case backupFailed(message: String)
    case writeFailed(message: String)
    case unrelatedConfigurationChanged
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case let .configMissing(path):
            return "未找到 Codex 配置文件：\n\(path)"
        case let .unreadableConfig(message):
            return "无法读取 Codex 配置：\n\(message)"
        case .invalidUTF8:
            return "Codex 配置不是有效的 UTF-8 文本，未进行修改。"
        case .deepSeekProviderMissing:
            return "配置缺失：未找到 [model_providers.deepseek]。\n\n为保护现有 API Key，切换器不会自动创建或覆盖 DeepSeek provider。"
        case let .duplicateTopLevelKey(key):
            return "Codex 配置中存在重复的顶层字段 \(key)，未进行修改。"
        case let .backupFailed(message):
            return "修改前备份 config.toml 失败，未进行切换：\n\(message)"
        case let .writeFailed(message):
            return "写入 config.toml 失败：\n\(message)"
        case .unrelatedConfigurationChanged:
            return "安全校验发现本次操作可能影响目标字段以外的配置，已停止且未写入。"
        case .verificationFailed:
            return "写入后的配置校验失败。原配置备份已保留，请检查 config.toml。"
        }
    }
}

final class CodexConfigEditor {
    private struct Line {
        var content: String
        let ending: String

        var fullText: String { content + ending }
    }

    private struct ScanState {
        enum MultilineString: Equatable {
            case basic
            case literal
        }

        var multilineString: MultilineString?
        var squareBracketDepth = 0
        var curlyBracketDepth = 0

        var isAtStatementStart: Bool {
            multilineString == nil && squareBracketDepth == 0 && curlyBracketDepth == 0
        }
    }

    private struct Analysis {
        let lines: [Line]
        let targetLineIndexes: [String: Int]
        let firstTableLineIndex: Int?
        let hasDeepSeekProvider: Bool
    }

    private let fileManager: FileManager
    let codexDirectory: URL

    private let desiredDeepSeekValues: [(key: String, value: String)] = [
        ("model", "deepseek-v4-pro"),
        ("model_provider", "deepseek"),
        ("preferred_auth_method", "apikey"),
        ("forced_login_method", "api"),
        ("model_catalog_json", "~/.codex/models.json"),
    ]

    private var targetKeys: Set<String> {
        Set(desiredDeepSeekValues.map(\.key))
    }

    init(codexDirectory: URL, fileManager: FileManager = .default) {
        self.codexDirectory = codexDirectory
        self.fileManager = fileManager
    }

    var configURL: URL {
        codexDirectory.appendingPathComponent("config.toml")
    }

    func preflight(mode: CodexMode) throws {
        let text = try readConfiguration()
        let analysis = try analyze(text)
        if mode == .deepSeek && !analysis.hasDeepSeekProvider {
            throw ConfigEditorError.deepSeekProviderMissing
        }
    }

    @discardableResult
    func switchMode(to mode: CodexMode) throws -> ConfigSwitchResult {
        let originalText = try readConfiguration()
        let analysis = try analyze(originalText)

        if mode == .deepSeek && !analysis.hasDeepSeekProvider {
            throw ConfigEditorError.deepSeekProviderMissing
        }

        let updatedText = makeUpdatedText(from: analysis, mode: mode)
        guard updatedText != originalText else {
            return ConfigSwitchResult(mode: mode, backupURL: nil, changed: false)
        }

        let expectedAnalysis = try analyze(updatedText)
        guard textExcludingTargetLines(analysis) == textExcludingTargetLines(expectedAnalysis),
              (!analysis.hasDeepSeekProvider || expectedAnalysis.hasDeepSeekProvider),
              configurationMatches(mode: mode, analysis: expectedAnalysis)
        else {
            throw ConfigEditorError.unrelatedConfigurationChanged
        }

        let backupURL = try backupConfiguration()
        try writeConfigurationAtomically(updatedText)

        let persistedText = try readConfiguration()
        let persistedAnalysis = try analyze(persistedText)
        let providerWasPreserved = !analysis.hasDeepSeekProvider || persistedAnalysis.hasDeepSeekProvider
        guard persistedText == updatedText,
              providerWasPreserved,
              configurationMatches(mode: mode, analysis: persistedAnalysis)
        else {
            throw ConfigEditorError.verificationFailed
        }

        return ConfigSwitchResult(mode: mode, backupURL: backupURL, changed: true)
    }

    private func readConfiguration() throws -> String {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw ConfigEditorError.configMissing(path: configURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ConfigEditorError.unreadableConfig(message: error.localizedDescription)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigEditorError.invalidUTF8
        }
        return text
    }

    private func analyze(_ text: String) throws -> Analysis {
        let lines = splitLinesPreservingEndings(text)
        var state = ScanState()
        var targetLineIndexes: [String: Int] = [:]
        var firstTableLineIndex: Int?
        var hasDeepSeekProvider = false

        for (index, line) in lines.enumerated() {
            let startsStatement = state.isAtStatementStart
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)

            if startsStatement, trimmed.hasPrefix("[") {
                if firstTableLineIndex == nil {
                    firstTableLineIndex = index
                }
                if isDeepSeekProviderHeader(trimmed) {
                    hasDeepSeekProvider = true
                }
                continue
            }

            if startsStatement,
               firstTableLineIndex == nil,
               let key = targetKey(in: line.content)
            {
                if targetLineIndexes[key] != nil {
                    throw ConfigEditorError.duplicateTopLevelKey(key)
                }
                targetLineIndexes[key] = index
            }

            scanValueFragment(line.content, state: &state)
        }

        return Analysis(
            lines: lines,
            targetLineIndexes: targetLineIndexes,
            firstTableLineIndex: firstTableLineIndex,
            hasDeepSeekProvider: hasDeepSeekProvider
        )
    }

    private func makeUpdatedText(from analysis: Analysis, mode: CodexMode) -> String {
        var lines = analysis.lines

        switch mode {
        case .chatGPT:
            let indexesToRemove = Set(analysis.targetLineIndexes.values)
            return lines.enumerated()
                .filter { !indexesToRemove.contains($0.offset) }
                .map(\.element.fullText)
                .joined()

        case .deepSeek:
            for item in desiredDeepSeekValues {
                if let index = analysis.targetLineIndexes[item.key] {
                    lines[index].content = canonicalLine(key: item.key, value: item.value)
                }
            }

            let missing = desiredDeepSeekValues.filter { analysis.targetLineIndexes[$0.key] == nil }
            guard !missing.isEmpty else {
                return lines.map(\.fullText).joined()
            }

            let newline = preferredNewline(in: lines)
            let insertionIndex = analysis.firstTableLineIndex ?? lines.count
            let insertionLines = missing.map {
                Line(content: canonicalLine(key: $0.key, value: $0.value), ending: newline)
            }

            if insertionIndex == lines.count,
               let last = lines.last,
               last.ending.isEmpty,
               !last.content.isEmpty
            {
                lines[lines.count - 1] = Line(content: last.content, ending: newline)
            }

            lines.insert(contentsOf: insertionLines, at: insertionIndex)
            return lines.map(\.fullText).joined()
        }
    }

    private func configurationMatches(mode: CodexMode, analysis: Analysis) -> Bool {
        switch mode {
        case .chatGPT:
            return analysis.targetLineIndexes.isEmpty
        case .deepSeek:
            guard analysis.hasDeepSeekProvider,
                  analysis.targetLineIndexes.count == desiredDeepSeekValues.count
            else {
                return false
            }
            for item in desiredDeepSeekValues {
                guard let index = analysis.targetLineIndexes[item.key],
                      analysis.lines[index].content == canonicalLine(key: item.key, value: item.value)
                else {
                    return false
                }
            }
            return true
        }
    }

    private func textExcludingTargetLines(_ analysis: Analysis) -> String {
        let targetIndexes = Set(analysis.targetLineIndexes.values)
        return analysis.lines.enumerated()
            .filter { !targetIndexes.contains($0.offset) }
            .map(\.element.fullText)
            .joined()
    }

    private func backupConfiguration() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let timestamp = formatter.string(from: Date())
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let backupURL = codexDirectory.appendingPathComponent(
            "config.toml.switcher-backup-\(timestamp)-\(uniqueSuffix)"
        )

        do {
            try fileManager.copyItem(at: configURL, to: backupURL)
            return backupURL
        } catch {
            throw ConfigEditorError.backupFailed(message: error.localizedDescription)
        }
    }

    private func writeConfigurationAtomically(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw ConfigEditorError.invalidUTF8
        }

        let attributes = try? fileManager.attributesOfItem(atPath: configURL.path)
        let temporaryURL = codexDirectory.appendingPathComponent(
            ".config.toml.model-switcher-\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporaryURL, options: [.atomic])
            if let permissions = attributes?[.posixPermissions] {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: temporaryURL.path
                )
            }
            _ = try fileManager.replaceItemAt(
                configURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ConfigEditorError.writeFailed(message: error.localizedDescription)
        }
    }

    private func canonicalLine(key: String, value: String) -> String {
        "\(key) = \"\(value)\""
    }

    private func targetKey(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        for key in targetKeys {
            guard trimmed.hasPrefix(key) else { continue }
            let remainder = trimmed.dropFirst(key.count).drop(while: { $0 == " " || $0 == "\t" })
            if remainder.first == "=" {
                return key
            }
        }
        return nil
    }

    private func isDeepSeekProviderHeader(_ trimmedLine: String) -> Bool {
        guard trimmedLine.hasPrefix("["),
              let closingBracket = trimmedLine.firstIndex(of: "]")
        else {
            return false
        }

        let afterOpening = trimmedLine.index(after: trimmedLine.startIndex)
        guard afterOpening <= closingBracket else { return false }
        let rawPath = trimmedLine[afterOpening..<closingBracket]
        let normalizedPath = rawPath.filter { $0 != " " && $0 != "\t" }
        let tail = trimmedLine[trimmedLine.index(after: closingBracket)...]
            .trimmingCharacters(in: .whitespaces)

        return normalizedPath == "model_providers.deepseek"
            && (tail.isEmpty || tail.hasPrefix("#"))
    }

    private func preferredNewline(in lines: [Line]) -> String {
        lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
    }

    private func splitLinesPreservingEndings(_ text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        var result: [Line] = []
        let bytes = Array(text.utf8)
        var start = 0

        for index in bytes.indices where bytes[index] == 0x0A {
            let usesCRLF = index > start && bytes[index - 1] == 0x0D
            let contentEnd = usesCRLF ? index - 1 : index
            result.append(Line(
                content: String(decoding: bytes[start..<contentEnd], as: UTF8.self),
                ending: usesCRLF ? "\r\n" : "\n"
            ))
            start = index + 1
        }

        if start < bytes.count {
            result.append(Line(content: String(decoding: bytes[start...], as: UTF8.self), ending: ""))
        }
        return result
    }

    private func scanValueFragment(_ fragment: String, state: inout ScanState) {
        var index = fragment.startIndex
        var basicString = false
        var literalString = false

        func hasPrefix(_ value: String, at position: String.Index) -> Bool {
            fragment[position...].hasPrefix(value)
        }

        while index < fragment.endIndex {
            if state.multilineString == .basic {
                if hasPrefix("\"\"\"", at: index) {
                    state.multilineString = nil
                    index = fragment.index(index, offsetBy: 3)
                } else if fragment[index] == "\\" {
                    index = fragment.index(after: index)
                    if index < fragment.endIndex {
                        index = fragment.index(after: index)
                    }
                } else {
                    index = fragment.index(after: index)
                }
                continue
            }

            if state.multilineString == .literal {
                if hasPrefix("'''", at: index) {
                    state.multilineString = nil
                    index = fragment.index(index, offsetBy: 3)
                } else {
                    index = fragment.index(after: index)
                }
                continue
            }

            if basicString {
                if fragment[index] == "\\" {
                    index = fragment.index(after: index)
                    if index < fragment.endIndex {
                        index = fragment.index(after: index)
                    }
                } else {
                    if fragment[index] == "\"" {
                        basicString = false
                    }
                    index = fragment.index(after: index)
                }
                continue
            }

            if literalString {
                if fragment[index] == "'" {
                    literalString = false
                }
                index = fragment.index(after: index)
                continue
            }

            if fragment[index] == "#" {
                return
            }
            if hasPrefix("\"\"\"", at: index) {
                state.multilineString = .basic
                index = fragment.index(index, offsetBy: 3)
                continue
            }
            if hasPrefix("'''", at: index) {
                state.multilineString = .literal
                index = fragment.index(index, offsetBy: 3)
                continue
            }

            switch fragment[index] {
            case "\"":
                basicString = true
            case "'":
                literalString = true
            case "[":
                state.squareBracketDepth += 1
            case "]":
                state.squareBracketDepth = max(0, state.squareBracketDepth - 1)
            case "{":
                state.curlyBracketDepth += 1
            case "}":
                state.curlyBracketDepth = max(0, state.curlyBracketDepth - 1)
            default:
                break
            }
            index = fragment.index(after: index)
        }
    }
}
