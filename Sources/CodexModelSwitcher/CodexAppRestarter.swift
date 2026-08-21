import AppKit
import Foundation

protocol CodexApplicationProcess: AnyObject {
    var bundleURL: URL? { get }
    var isTerminated: Bool { get }

    @discardableResult
    func terminate() -> Bool

    @discardableResult
    func forceTerminate() -> Bool
}

extension NSRunningApplication: CodexApplicationProcess {}

protocol CodexApplicationEnvironment {
    func runningApplications(withBundleIdentifier bundleIdentifier: String) -> [CodexApplicationProcess]
    func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL?
    func openApplication(at applicationURL: URL) -> Bool
}

struct SystemCodexApplicationEnvironment: CodexApplicationEnvironment {
    func runningApplications(withBundleIdentifier bundleIdentifier: String) -> [CodexApplicationProcess] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(at applicationURL: URL) -> Bool {
        NSWorkspace.shared.open(applicationURL)
    }
}

struct CodexRestartResult {
    let terminatedRunningApplication: Bool
}

enum CodexRestartError: LocalizedError {
    case applicationMissing(bundleIdentifier: String)
    case terminationTimedOut
    case relaunchFailed(path: String)
    case relaunchTimedOut

    var errorDescription: String? {
        switch self {
        case let .applicationMissing(bundleIdentifier):
            return "未找到 Codex 桌面应用（Bundle ID: \(bundleIdentifier)）。"
        case .terminationTimedOut:
            return "Codex 未能在限定时间内退出。"
        case let .relaunchFailed(path):
            return "无法重新打开 Codex：\n\(path)"
        case .relaunchTimedOut:
            return "已发出打开 Codex 的请求，但未检测到应用启动。"
        }
    }
}

final class CodexAppRestarter {
    private let bundleIdentifier: String
    private let environment: CodexApplicationEnvironment
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let gracefulTimeout: TimeInterval
    private let forceTimeout: TimeInterval
    private let launchTimeout: TimeInterval
    private let pollInterval: TimeInterval

    init(
        bundleIdentifier: String = "com.openai.codex",
        environment: CodexApplicationEnvironment = SystemCodexApplicationEnvironment(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep,
        gracefulTimeout: TimeInterval = 8,
        forceTimeout: TimeInterval = 4,
        launchTimeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.1
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.environment = environment
        self.now = now
        self.sleep = sleep
        self.gracefulTimeout = gracefulTimeout
        self.forceTimeout = forceTimeout
        self.launchTimeout = launchTimeout
        self.pollInterval = pollInterval
    }

    func restart() throws -> CodexRestartResult {
        let runningApplications = activeApplications()
        let applicationURL = runningApplications.compactMap(\.bundleURL).first
            ?? environment.applicationURL(withBundleIdentifier: bundleIdentifier)

        guard let applicationURL else {
            throw CodexRestartError.applicationMissing(bundleIdentifier: bundleIdentifier)
        }

        if !runningApplications.isEmpty {
            for application in runningApplications {
                _ = application.terminate()
            }

            if !waitUntil(timeout: gracefulTimeout, condition: { self.activeApplications().isEmpty }) {
                for application in activeApplications() {
                    _ = application.forceTerminate()
                }

                guard waitUntil(timeout: forceTimeout, condition: { self.activeApplications().isEmpty }) else {
                    throw CodexRestartError.terminationTimedOut
                }
            }
        }

        guard environment.openApplication(at: applicationURL) else {
            throw CodexRestartError.relaunchFailed(path: applicationURL.path)
        }

        guard waitUntil(timeout: launchTimeout, condition: { !self.activeApplications().isEmpty }) else {
            throw CodexRestartError.relaunchTimedOut
        }

        return CodexRestartResult(terminatedRunningApplication: !runningApplications.isEmpty)
    }

    private func activeApplications() -> [CodexApplicationProcess] {
        environment.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = now().addingTimeInterval(timeout)

        while true {
            if condition() {
                return true
            }

            let remaining = deadline.timeIntervalSince(now())
            if remaining <= 0 {
                return false
            }

            sleep(min(pollInterval, remaining))
        }
    }
}
