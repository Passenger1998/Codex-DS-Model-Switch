import Foundation
import Security

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

@main
struct ConfigEditorTests {
    static let fileManager = FileManager.default

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure.failed(message)
        }
    }

    static func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-model-switcher-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func testCommandArgumentsAndOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex-provider")
        try writeExecutable("#!/bin/sh\nprintf 'args=%s\\n' \"$*\"\n", to: executable)
        let command = CodexProviderCommand(
            codexDirectory: directory,
            executableURL: executable
        )

        let deepSeekResult = try command.switchMode(to: .deepSeek, credentialProfileID: "profile-a")
        let chatGPTResult = try command.switchMode(to: .chatGPT)
        let statusResult = try command.status()

        try expect(deepSeekResult.output == "args=deepseek --credential profile-a",
                   "DeepSeek 参数传递错误")
        try expect(chatGPTResult.output == "args=chatgpt",
                   "ChatGPT 参数传递错误")
        try expect(statusResult.output == "args=status",
                   "status 参数传递错误")
    }

    static func testActualStatusParsing() throws {
        let deepSeek = ProviderStatus(output: """
        current_state=deepseek
        state_label=DeepSeek V4 Pro
        state_consistent=yes
        credential_profile_id=profile-a
        credential_profile_name=Personal
        credential_profile_key=present
        """)
        let inconsistent = ProviderStatus(output: """
        current_state=inconsistent
        state_label=配置不一致
        state_consistent=no
        """)

        try expect(deepSeek.currentMode == .deepSeek, "DeepSeek 实际状态解析错误")
        try expect(deepSeek.displayName == "DeepSeek V4 Pro", "DeepSeek 显示状态错误")
        try expect(deepSeek.isConsistent, "DeepSeek 应标记为一致")
        try expect(deepSeek.credentialProfileID == "profile-a", "Credential Profile ID 解析错误")
        try expect(deepSeek.credentialProfileName == "Personal", "Credential Profile 名称解析错误")
        try expect(deepSeek.credentialKeyPresent, "Credential Profile Key 应存在")
        try expect(inconsistent.currentMode == nil, "不一致状态不应映射为可选模式")
        try expect(!inconsistent.isConsistent, "不一致状态应被识别")
    }

    static func testCodexDirectoryOverride() throws {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let defaultDirectory = resolvedCodexDirectory(
            environment: [:],
            homeDirectory: homeDirectory
        )
        let overriddenDirectory = resolvedCodexDirectory(
            environment: ["CODEX_SWITCHER_CODEX_HOME": "/tmp/isolated-codex-home"],
            homeDirectory: homeDirectory
        )

        try expect(defaultDirectory.path == "/Users/example/.codex",
                   "默认应使用用户 ~/.codex")
        try expect(overriddenDirectory.path == "/tmp/isolated-codex-home",
                   "测试目录覆盖未生效")
    }

    static func testMissingExecutableGuard() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing")
        let command = CodexProviderCommand(
            codexDirectory: directory,
            executableURL: missing
        )

        do {
            try command.preflight()
            throw TestFailure.failed("缺少安全切换命令时不应通过预检")
        } catch ProviderCommandError.executableMissing {
            // Expected.
        }
    }

    static func testCommandFailureIsSurfaced() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex-provider")
        try writeExecutable("#!/bin/sh\nprintf 'safe failure' >&2\nexit 7\n", to: executable)
        let command = CodexProviderCommand(
            codexDirectory: directory,
            executableURL: executable
        )

        do {
            _ = try command.status()
            throw TestFailure.failed("底层切换命令失败时 App 不应报告成功")
        } catch let ProviderCommandError.commandFailed(status, message) {
            try expect(status == 7, "错误退出码未保留")
            try expect(message == "safe failure", "错误详情未保留")
        }
    }

    final class FakeKeychain: CredentialKeychainAccess {
        var values: [String: String] = [:]
        var failStore = false
        var failRemove = false

        private func key(_ service: String, _ account: String) -> String {
            "\(service)|\(account)"
        }

        func contains(service: String, account: String) -> Bool {
            values[key(service, account)] != nil
        }

        func ensureLegacyAccount(service: String, targetAccount: String) throws -> Bool {
            if contains(service: service, account: targetAccount) { return true }
            guard let legacy = values.first(where: { $0.key.hasPrefix("\(service)|") })?.value else {
                return false
            }
            values[key(service, targetAccount)] = legacy
            return true
        }

        func store(_ secret: String, service: String, account: String) throws {
            if failStore { throw CredentialProfileError.keychain(errSecAuthFailed) }
            values[key(service, account)] = secret
        }

        func remove(service: String, account: String) throws {
            if failRemove { throw CredentialProfileError.keychain(errSecAuthFailed) }
            values.removeValue(forKey: key(service, account))
        }
    }

    static func testCredentialProfileCreationEnumerationAndSecretIsolation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let keychain = FakeKeychain()
        let store = CredentialProfileStore(
            scope: .codex,
            homeDirectory: directory,
            keychain: keychain
        )
        let personal = try store.create(displayName: "Personal", apiKey: "fixture-secret-personal")
        let work = try store.create(displayName: "Work", apiKey: "fixture-secret-work")
        let profiles = try store.profiles()
        try expect(profiles == [personal, work], "多 Profile 创建或枚举错误")
        try expect(personal.id != work.id, "Profile 必须使用独立稳定 ID")
        let metadata = try String(contentsOf: store.metadataURL, encoding: .utf8)
        try expect(!metadata.contains("fixture-secret"), "Profile 元数据不得包含 API Key")
        try expect(store.keyExists(for: personal), "Personal Keychain 条目应存在")
        try expect(store.keyExists(for: work), "Work Keychain 条目应存在")
    }

    static func testCredentialKeychainFailureDoesNotMutateMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let keychain = FakeKeychain()
        let store = CredentialProfileStore(
            scope: .claude,
            homeDirectory: directory,
            keychain: keychain
        )
        _ = try store.create(displayName: "Personal", apiKey: "fixture-one")
        let before = try Data(contentsOf: store.metadataURL)
        keychain.failStore = true
        do {
            _ = try store.create(displayName: "Work", apiKey: "fixture-two")
            throw TestFailure.failed("Keychain 写入失败时不应创建 Profile")
        } catch CredentialProfileError.keychain {
            // Expected.
        }
        let after = try Data(contentsOf: store.metadataURL)
        try expect(after == before,
                   "Keychain 写入失败后 Profile 元数据应保持不变")
    }

    static func testLegacyMigrationAndActiveDeletionGuard() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let keychain = FakeKeychain()
        keychain.values["codex-deepseek-api-key|old-account"] = "legacy-fixture-secret"
        let store = CredentialProfileStore(
            scope: .codex,
            homeDirectory: directory,
            keychain: keychain
        )
        try store.ensureLegacyMigration()
        let migrated = try store.state()
        try expect(migrated.profiles == [CredentialProfile(id: "deepseek", displayName: "Default")],
                   "旧版单 Key 应映射为 Default Profile")
        try expect(migrated.activeProfileId == "deepseek", "Default Profile 应保持活动")
        guard let active = migrated.profiles.first else {
            throw TestFailure.failed("缺少迁移后 Profile")
        }
        do {
            try store.remove(active, currentlyUsed: { true })
            throw TestFailure.failed("不应删除正在使用的 Profile")
        } catch CredentialProfileError.activeProfileCannotBeDeleted {
            // Expected.
        }
        try expect(keychain.contains(service: "codex-deepseek-api-key", account: "deepseek"),
                   "旧 service-only Key 应复制到 Default Profile account")
        try expect(keychain.contains(service: "codex-deepseek-api-key", account: "old-account"),
                   "迁移和拦截删除不得破坏旧 Key")
    }

    static func testCredentialDeleteFailureRollsMetadataBack() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let keychain = FakeKeychain()
        let store = CredentialProfileStore(
            scope: .claude,
            homeDirectory: directory,
            keychain: keychain
        )
        let profile = try store.create(displayName: "Backup", apiKey: "fixture-backup")
        let before = try Data(contentsOf: store.metadataURL)
        keychain.failRemove = true
        do {
            try store.remove(profile, currentlyUsed: { false })
            throw TestFailure.failed("Keychain 删除失败时不应完成 Profile 删除")
        } catch CredentialProfileError.keychain {
            // Expected.
        }
        let after = try Data(contentsOf: store.metadataURL)
        try expect(after == before, "Keychain 删除失败后元数据应回滚")
    }

    final class FakeApplication: CodexApplicationProcess {
        let bundleURL: URL?
        var isTerminated = false
        var ignoresGracefulTermination = false
        private(set) var terminateCallCount = 0
        private(set) var forceTerminateCallCount = 0

        init(bundleURL: URL?) {
            self.bundleURL = bundleURL
        }

        func terminate() -> Bool {
            terminateCallCount += 1
            if !ignoresGracefulTermination {
                isTerminated = true
            }
            return !ignoresGracefulTermination
        }

        func forceTerminate() -> Bool {
            forceTerminateCallCount += 1
            isTerminated = true
            return true
        }
    }

    final class FakeApplicationEnvironment: CodexApplicationEnvironment {
        var applications: [FakeApplication]
        var installedApplicationURL: URL?
        var shouldOpen = true
        private(set) var openedURL: URL?

        init(applications: [FakeApplication], installedApplicationURL: URL?) {
            self.applications = applications
            self.installedApplicationURL = installedApplicationURL
        }

        func runningApplications(withBundleIdentifier bundleIdentifier: String) -> [CodexApplicationProcess] {
            applications.filter { !$0.isTerminated }
        }

        func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL? {
            installedApplicationURL
        }

        func openApplication(at applicationURL: URL) -> Bool {
            guard shouldOpen else {
                return false
            }

            openedURL = applicationURL
            applications.append(FakeApplication(bundleURL: applicationURL))
            return true
        }
    }

    final class FakeClock {
        var date = Date(timeIntervalSince1970: 0)

        func now() -> Date {
            date
        }

        func sleep(_ duration: TimeInterval) {
            date.addTimeInterval(duration)
        }
    }

    static func makeRestarter(
        environment: FakeApplicationEnvironment,
        clock: FakeClock
    ) -> CodexAppRestarter {
        CodexAppRestarter(
            environment: environment,
            now: clock.now,
            sleep: clock.sleep,
            gracefulTimeout: 0.2,
            forceTimeout: 0.2,
            launchTimeout: 0.2,
            pollInterval: 0.1
        )
    }

    static func testRunningCodexIsTerminatedAndRelaunched() throws {
        let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let runningApplication = FakeApplication(bundleURL: applicationURL)
        let environment = FakeApplicationEnvironment(
            applications: [runningApplication],
            installedApplicationURL: applicationURL
        )
        let clock = FakeClock()

        let result = try makeRestarter(environment: environment, clock: clock).restart()

        try expect(result.terminatedRunningApplication, "运行中的 Codex 应被识别")
        try expect(runningApplication.terminateCallCount == 1, "应先正常退出 Codex")
        try expect(runningApplication.forceTerminateCallCount == 0, "正常退出成功后不应强制退出")
        try expect(environment.openedURL == applicationURL, "应重新打开原 Codex 应用")
    }

    static func testHungCodexUsesForceTerminateFallback() throws {
        let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let runningApplication = FakeApplication(bundleURL: applicationURL)
        runningApplication.ignoresGracefulTermination = true
        let environment = FakeApplicationEnvironment(
            applications: [runningApplication],
            installedApplicationURL: applicationURL
        )
        let clock = FakeClock()

        _ = try makeRestarter(environment: environment, clock: clock).restart()

        try expect(runningApplication.terminateCallCount == 1, "应尝试正常退出")
        try expect(runningApplication.forceTerminateCallCount == 1, "正常退出超时后应强制退出")
        try expect(environment.openedURL == applicationURL, "强制退出后仍应重新打开 Codex")
    }

    static func testStoppedCodexIsOpened() throws {
        let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let environment = FakeApplicationEnvironment(
            applications: [],
            installedApplicationURL: applicationURL
        )
        let clock = FakeClock()

        let result = try makeRestarter(environment: environment, clock: clock).restart()

        try expect(!result.terminatedRunningApplication, "未运行时不应报告已退出 Codex")
        try expect(environment.openedURL == applicationURL, "Codex 未运行时应直接打开")
    }

    static func main() throws {
        try testCommandArgumentsAndOutput()
        try testActualStatusParsing()
        try testCodexDirectoryOverride()
        try testMissingExecutableGuard()
        try testCommandFailureIsSurfaced()
        try testCredentialProfileCreationEnumerationAndSecretIsolation()
        try testCredentialKeychainFailureDoesNotMutateMetadata()
        try testLegacyMigrationAndActiveDeletionGuard()
        try testCredentialDeleteFailureRollsMetadataBack()
        try testRunningCodexIsTerminatedAndRelaunched()
        try testHungCodexUsesForceTerminateFallback()
        try testStoppedCodexIsOpened()
        print("ConfigEditorTests: PASS")
        try ClaudeProviderTests.run()
        try CredentialInputViewTests.run()
    }
}
