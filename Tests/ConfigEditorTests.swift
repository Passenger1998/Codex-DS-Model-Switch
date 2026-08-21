import Foundation

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
        try writeExecutable("#!/bin/sh\nprintf 'mode=%s\\n' \"$1\"\n", to: executable)
        let command = CodexProviderCommand(
            codexDirectory: directory,
            executableURL: executable
        )

        let deepSeekHighResult = try command.switchMode(to: .deepSeekHigh)
        let deepSeekMaxResult = try command.switchMode(to: .deepSeekMax)
        let chatGPTResult = try command.switchMode(to: .chatGPT)
        let statusResult = try command.status()

        try expect(deepSeekHighResult.output == "mode=deepseek-high",
                   "DeepSeek High 参数传递错误")
        try expect(deepSeekMaxResult.output == "mode=deepseek-max",
                   "DeepSeek Max 参数传递错误")
        try expect(chatGPTResult.output == "mode=chatgpt",
                   "ChatGPT 参数传递错误")
        try expect(statusResult.output == "mode=status",
                   "status 参数传递错误")
    }

    static func testActualStatusParsing() throws {
        let high = ProviderStatus(output: """
        current_state=deepseek-high
        state_label=DeepSeek V4 Pro · High
        state_consistent=yes
        """)
        let max = ProviderStatus(output: """
        current_state=deepseek-max
        state_label=DeepSeek V4 Pro · Max
        state_consistent=yes
        """)
        let inconsistent = ProviderStatus(output: """
        current_state=inconsistent
        state_label=配置不一致
        state_consistent=no
        """)

        try expect(high.currentMode == .deepSeekHigh, "High 实际状态解析错误")
        try expect(high.displayName == "DeepSeek V4 Pro · High", "High 显示状态错误")
        try expect(high.isConsistent, "High 应标记为一致")
        try expect(max.currentMode == .deepSeekMax, "Max 实际状态解析错误")
        try expect(max.isConsistent, "Max 应标记为一致")
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
        try testRunningCodexIsTerminatedAndRelaunched()
        try testHungCodexUsesForceTerminateFallback()
        try testStoppedCodexIsOpened()
        print("ConfigEditorTests: PASS")
    }
}
