import Foundation
import Security

/// Where MyUsage keeps the logins it made itself (Settings → Accounts → Sign In). One Keychain item
/// per provider, owned by this app, so reading it never prompts and never touches another tool's
/// login. The value is the provider's own credential JSON (see `ClaudeSignIn` / `CodexSignIn`).
protocol SignInVault: Sendable {
    func read(_ provider: SignInProvider) throws -> String?
    func write(_ provider: SignInProvider, value: String) throws
    func delete(_ provider: SignInProvider) throws
}

enum SignInProvider: String, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

enum SignInVaultError: LocalizedError, Equatable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(detail)"
        }
    }
}

struct KeychainSignInVault: SignInVault {
    static let service = "MyUsage Sign-In"

    func read(_ provider: SignInProvider) throws -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SignInVaultError.keychain(status) }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ provider: SignInProvider, value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SignInVaultError.keychain(update) }
        var add = baseQuery(provider)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "MyUsage \(provider.displayName) Sign-In"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SignInVaultError.keychain(status) }
    }

    func delete(_ provider: SignInProvider) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SignInVaultError.keychain(status)
        }
    }

    private func baseQuery(_ provider: SignInProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue
        ]
    }
}

extension SignInVault {
    /// Providers with a stored MyUsage sign-in. A Keychain read failure is logged and counts as signed
    /// out, so the provider falls back to the local logins it read before.
    func signedInProviders() -> Set<SignInProvider> {
        Set(SignInProvider.allCases.filter { provider in
            do {
                return try read(provider) != nil
            } catch {
                AppLog.error(LogTag.auth(provider.rawValue), "reading the MyUsage sign-in failed: \(error.localizedDescription)")
                return false
            }
        })
    }
}
