import AppKit
import Foundation
import Observation

/// Drives Settings → Accounts: signs in to a provider inside MyUsage, stores the login in
/// `SignInVault`, and restarts the app so the provider's card is rebuilt around it (cards are
/// assembled once at launch, see `ProviderCatalog`).
@MainActor
@Observable
final class SignInStore {
    enum Phase: Equatable {
        case idle
        case starting
        case waiting(LoginPrompt)
        case failed(String)
    }

    private(set) var phases: [SignInProvider: Phase] = [:]
    private(set) var labels: [SignInProvider: String] = [:]

    @ObservationIgnored private let vault: any SignInVault
    @ObservationIgnored private let makeSignIn: (SignInProvider) -> any ProviderSignIn
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let relaunch: () -> Void
    @ObservationIgnored private var tasks: [SignInProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var pasteContinuations: [SignInProvider: AsyncStream<String>.Continuation] = [:]

    init(
        vault: any SignInVault = KeychainSignInVault(),
        makeSignIn: @escaping (SignInProvider) -> any ProviderSignIn = SignInStore.defaultSignIn,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        relaunch: @escaping () -> Void = AppRelauncher.relaunch
    ) {
        self.vault = vault
        self.makeSignIn = makeSignIn
        self.openURL = openURL
        self.relaunch = relaunch
        reloadLabels()
    }

    nonisolated static func defaultSignIn(_ provider: SignInProvider) -> any ProviderSignIn {
        switch provider {
        case .claude: ClaudeSignIn()
        case .codex: CodexSignIn()
        }
    }

    func phase(_ provider: SignInProvider) -> Phase { phases[provider] ?? .idle }

    func isSignedIn(_ provider: SignInProvider) -> Bool { labels[provider] != nil }

    func signIn(_ provider: SignInProvider) {
        cancel(provider)
        let (codes, continuation) = AsyncStream<String>.makeStream()
        pasteContinuations[provider] = continuation
        phases[provider] = .starting
        let signIn = makeSignIn(provider)
        let vault = vault
        tasks[provider] = Task { [weak self] in
            let show: @Sendable (LoginPrompt) async -> Void = { [weak self] prompt in
                await self?.show(prompt, for: provider)
            }
            do {
                let result = try await signIn.signIn(prompt: show, pastedCode: codes)
                try await Task.detached { try vault.write(provider, value: result.credential) }.value
                AppLog.info(LogTag.auth(provider.rawValue), "MyUsage sign-in saved; restarting")
                self?.finish(provider)
                self?.relaunch()
            } catch is CancellationError {
                self?.finish(provider)
            } catch LoginError.cancelled {
                self?.finish(provider)
            } catch {
                AppLog.error(LogTag.auth(provider.rawValue), "sign-in failed: \(error.localizedDescription)")
                self?.finish(provider, error: error.localizedDescription)
            }
        }
    }

    /// Hands a code copied from the browser to the waiting sign-in.
    func submitPastedCode(_ code: String, for provider: SignInProvider) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pasteContinuations[provider]?.yield(trimmed)
    }

    func cancel(_ provider: SignInProvider) {
        tasks[provider]?.cancel()
        pasteContinuations[provider]?.finish()
        finish(provider)
    }

    func signOut(_ provider: SignInProvider) {
        do {
            try vault.delete(provider)
            AppLog.info(LogTag.auth(provider.rawValue), "MyUsage sign-in removed; restarting")
            relaunch()
        } catch {
            AppLog.error(LogTag.auth(provider.rawValue), "sign-out failed: \(error.localizedDescription)")
            phases[provider] = .failed(error.localizedDescription)
        }
    }

    private func show(_ prompt: LoginPrompt, for provider: SignInProvider) {
        phases[provider] = .waiting(prompt)
        switch prompt {
        case .browser(let url, _): openURL(url)
        case .deviceCode(_, let url): openURL(url)
        }
    }

    private func finish(_ provider: SignInProvider, error: String? = nil) {
        tasks[provider] = nil
        pasteContinuations[provider] = nil
        phases[provider] = error.map(Phase.failed) ?? .idle
    }

    private func reloadLabels() {
        for provider in SignInProvider.allCases {
            do {
                guard let text = try vault.read(provider) else { continue }
                labels[provider] = Self.label(for: provider, credential: text)
            } catch {
                AppLog.error(LogTag.auth(provider.rawValue), "reading the MyUsage sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func label(for provider: SignInProvider, credential: String) -> String {
        switch provider {
        case .claude:
            let email = ProviderParse.jsonObject(Data(credential.utf8))?["myusageEmail"] as? String
            return email ?? "Claude Account"
        case .codex:
            return CodexSignIn.email(inCredential: credential) ?? "ChatGPT Account"
        }
    }
}

enum AppRelauncher {
    /// Starts a fresh copy once this one has quit, so the single-instance guard lets it run.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        do {
            try process.run()
        } catch {
            AppLog.error(.config, "relaunch failed: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
