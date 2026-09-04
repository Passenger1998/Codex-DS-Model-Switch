import Darwin
import Foundation
import Security

enum CredentialProfileScope: String, CaseIterable {
    case codex
    case claude

    var service: String {
        switch self {
        case .codex: return "codex-deepseek-api-key"
        case .claude: return "claude-code-deepseek-api-key"
        }
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

struct CredentialProfile: Codable, Equatable {
    let id: String
    let displayName: String
}

struct CredentialProfileState: Codable, Equatable {
    var version: Int = 1
    var profiles: [CredentialProfile] = []
    var activeProfileId: String?
}

enum CredentialProfileError: LocalizedError {
    case invalidMetadata(String)
    case invalidName(String)
    case duplicateName(String)
    case profileNotFound(String)
    case missingKey(String)
    case keychain(OSStatus)
    case activeProfileCannotBeDeleted(String)
    case lockBusy
    case io(String)

    var errorDescription: String? {
        switch self {
        case let .invalidMetadata(reason): return "Credential Profile 元数据无效：\(reason)"
        case let .invalidName(reason): return "Credential Profile 名称无效：\(reason)"
        case let .duplicateName(name): return "Credential Profile 名称已存在：\(name)"
        case let .profileNotFound(reference): return "Credential Profile 不存在：\(reference)"
        case let .missingKey(name): return "Credential Profile \(name) 的 Keychain 条目缺失"
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain 操作失败：\(detail)"
        case let .activeProfileCannotBeDeleted(name):
            return "\(name) 正在被 DeepSeek 使用。请先切换到官方模式或其他 Credential Profile。"
        case .lockBusy: return "另一个 Credential Profile 或 Provider 事务正在运行"
        case let .io(reason): return "Credential Profile 存储失败：\(reason)"
        }
    }
}

protocol CredentialKeychainAccess {
    func contains(service: String, account: String) -> Bool
    func ensureLegacyAccount(service: String, targetAccount: String) throws -> Bool
    func store(_ secret: String, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

struct MacCredentialKeychain: CredentialKeychainAccess {
    func contains(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func ensureLegacyAccount(service: String, targetAccount: String) throws -> Bool {
        if contains(service: service, account: targetAccount) { return true }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if copyStatus == errSecItemNotFound { return false }
        guard copyStatus == errSecSuccess else {
            throw CredentialProfileError.keychain(copyStatus)
        }
        guard let attributes = result as? [CFString: Any],
              let data = attributes[kSecValueData] as? Data,
              !data.isEmpty else {
            throw CredentialProfileError.keychain(errSecDecode)
        }
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: targetAccount,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem,
              contains(service: service, account: targetAccount) else {
            throw CredentialProfileError.keychain(addStatus)
        }
        // Deliberately retain the source legacy item after verifying the copy.
        return true
    }

    func store(_ secret: String, service: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialProfileError.keychain(updateStatus)
        }
        let item: [CFString: Any] = query.merging([
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialProfileError.keychain(addStatus)
        }
    }

    func remove(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialProfileError.keychain(status)
        }
    }
}

final class CredentialProfileStore {
    static let legacyProfileID = "deepseek"
    static let legacyProfileName = "Default"

    let scope: CredentialProfileScope
    let homeDirectory: URL
    let metadataURL: URL
    private let keychain: CredentialKeychainAccess
    private let fileManager: FileManager

    init(
        scope: CredentialProfileScope,
        homeDirectory: URL,
        keychain: CredentialKeychainAccess = MacCredentialKeychain(),
        fileManager: FileManager = .default
    ) {
        self.scope = scope
        self.homeDirectory = homeDirectory
        self.metadataURL = homeDirectory.appendingPathComponent("deepseek-credential-profiles.json")
        self.keychain = keychain
        self.fileManager = fileManager
    }

    func ensureLegacyMigration() throws {
        try withLock {
            let state = try loadState()
            let hasLegacyProfile = state.profiles.contains { $0.id == Self.legacyProfileID }
            guard state.profiles.isEmpty || (hasLegacyProfile && state.profiles.count == 1) else { return }
            guard try keychain.ensureLegacyAccount(
                    service: scope.service,
                    targetAccount: Self.legacyProfileID
                  ) else { return }
            guard state.profiles.isEmpty else { return }
            let migrated = CredentialProfileState(
                profiles: [CredentialProfile(id: Self.legacyProfileID, displayName: Self.legacyProfileName)],
                activeProfileId: Self.legacyProfileID
            )
            try writeState(migrated)
        }
    }

    func state() throws -> CredentialProfileState {
        try ensureLegacyMigration()
        return try loadState()
    }

    func profiles() throws -> [CredentialProfile] {
        try state().profiles
    }

    func activeProfile() throws -> CredentialProfile? {
        let current = try state()
        guard let activeID = current.activeProfileId else { return nil }
        return current.profiles.first { $0.id == activeID }
    }

    func profile(reference: String) throws -> CredentialProfile {
        let current = try state()
        if let exact = current.profiles.first(where: { $0.id == reference }) { return exact }
        let matches = current.profiles.filter {
            $0.displayName.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard matches.count == 1, let profile = matches.first else {
            throw CredentialProfileError.profileNotFound(reference)
        }
        return profile
    }

    func keyExists(for profile: CredentialProfile) -> Bool {
        keychain.contains(service: scope.service, account: profile.id)
    }

    @discardableResult
    func create(displayName: String, apiKey: String) throws -> CredentialProfile {
        let name = try validatedName(displayName)
        let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw CredentialProfileError.invalidName("API Key 不能为空") }
        return try withLock {
            let originalData = try? Data(contentsOf: metadataURL)
            var current = try loadEffectiveState()
            guard !current.profiles.contains(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw CredentialProfileError.duplicateName(name)
            }
            let profile = CredentialProfile(id: UUID().uuidString.lowercased(), displayName: name)
            try keychain.store(secret, service: scope.service, account: profile.id)
            do {
                current.profiles.append(profile)
                try writeState(current)
                let verified = try loadState()
                guard verified.profiles.contains(profile), keychain.contains(service: scope.service, account: profile.id) else {
                    throw CredentialProfileError.io("写后验证失败")
                }
            } catch {
                try? keychain.remove(service: scope.service, account: profile.id)
                if let originalData {
                    try? atomicWrite(originalData, to: metadataURL)
                } else {
                    try? atomicRemove(metadataURL)
                }
                throw error
            }
            return profile
        }
    }

    func replaceKey(for profile: CredentialProfile, apiKey: String) throws {
        let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw CredentialProfileError.invalidName("API Key 不能为空") }
        try withLock {
            let current = try loadEffectiveState()
            guard current.profiles.contains(profile) else {
                throw CredentialProfileError.profileNotFound(profile.id)
            }
            try keychain.store(secret, service: scope.service, account: profile.id)
        }
    }

    func remove(_ profile: CredentialProfile, currentlyUsed: () -> Bool) throws {
        try withLock {
            if currentlyUsed() {
                throw CredentialProfileError.activeProfileCannotBeDeleted(profile.displayName)
            }
            let originalData = try? Data(contentsOf: metadataURL)
            var current = try loadEffectiveState()
            guard let index = current.profiles.firstIndex(of: profile) else {
                throw CredentialProfileError.profileNotFound(profile.id)
            }
            current.profiles.remove(at: index)
            if current.activeProfileId == profile.id {
                current.activeProfileId = current.profiles.first?.id
            }
            try writeState(current)
            do {
                try keychain.remove(service: scope.service, account: profile.id)
            } catch {
                if let originalData {
                    try? atomicWrite(originalData, to: metadataURL)
                } else {
                    try? atomicRemove(metadataURL)
                }
                throw error
            }
        }
    }

    private func validatedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CredentialProfileError.invalidName("请输入 1–80 个可见字符")
        }
        return name
    }

    private func loadEffectiveState() throws -> CredentialProfileState {
        let current = try loadState()
        if current.profiles.isEmpty,
           keychain.contains(service: scope.service, account: Self.legacyProfileID) {
            return CredentialProfileState(
                profiles: [CredentialProfile(id: Self.legacyProfileID, displayName: Self.legacyProfileName)],
                activeProfileId: Self.legacyProfileID
            )
        }
        return current
    }

    private func loadState() throws -> CredentialProfileState {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return CredentialProfileState()
        }
        do {
            let decoded = try JSONDecoder().decode(
                CredentialProfileState.self,
                from: Data(contentsOf: metadataURL)
            )
            try validate(decoded)
            return decoded
        } catch let error as CredentialProfileError {
            throw error
        } catch {
            throw CredentialProfileError.invalidMetadata(error.localizedDescription)
        }
    }

    private func validate(_ state: CredentialProfileState) throws {
        guard state.version == 1 else { throw CredentialProfileError.invalidMetadata("版本不受支持") }
        var ids = Set<String>()
        var names = Set<String>()
        for profile in state.profiles {
            guard profile.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
                throw CredentialProfileError.invalidMetadata("Profile ID 无效")
            }
            _ = try validatedName(profile.displayName)
            guard ids.insert(profile.id).inserted,
                  names.insert(profile.displayName.lowercased()).inserted else {
                throw CredentialProfileError.invalidMetadata("Profile ID 或名称重复")
            }
        }
        if let active = state.activeProfileId,
           active.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) == nil {
            throw CredentialProfileError.invalidMetadata("当前 Profile ID 无效")
        }
    }

    private func writeState(_ state: CredentialProfileState) throws {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try atomicWrite(data, to: metadataURL)
        guard try Data(contentsOf: metadataURL) == data else {
            throw CredentialProfileError.io("写后字节验证失败")
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CredentialProfileError.io("无法创建临时文件")
            }
            do {
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                guard rename(temporary.path, url.path) == 0 else {
                    throw CredentialProfileError.io(String(cString: strerror(errno)))
                }
                try fsyncDirectory(url.deletingLastPathComponent())
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        } catch let error as CredentialProfileError {
            throw error
        } catch {
            throw CredentialProfileError.io(error.localizedDescription)
        }
    }

    private func atomicRemove(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let tombstone = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).deleted-\(UUID().uuidString)")
        guard rename(url.path, tombstone.path) == 0 else {
            throw CredentialProfileError.io(String(cString: strerror(errno)))
        }
        try fileManager.removeItem(at: tombstone)
        try fsyncDirectory(url.deletingLastPathComponent())
    }

    private func fsyncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CredentialProfileError.io(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CredentialProfileError.io(String(cString: strerror(errno))) }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        let lockURL = homeDirectory.appendingPathComponent(".provider-switch.lock", isDirectory: true)
        do {
            try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
        } catch {
            throw CredentialProfileError.lockBusy
        }
        defer { try? fileManager.removeItem(at: lockURL) }
        return try body()
    }
}
