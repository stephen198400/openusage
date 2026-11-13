import CryptoKit
import Foundation
import Security

/// A droid login decrypted from its v2 store. `document` is the full decrypted JSON, kept so a token
/// refresh can write back every other field (active org, whoami, …) untouched.
struct DroidAuth: Sendable, Equatable {
    enum Source: String, Sendable {
        /// `auth.v2.loginkeychain`, keyed by a login-keychain item droid saves through `security`.
        case loginKeychain
        /// `auth.v2.file`, keyed by `auth.v2.key` on disk (`FACTORY_DISABLE_KEYRING=1`, or keychain fallback).
        case keyfile
    }

    var source: Source
    var envelopePath: String
    var key: Data
    var document: Data
    var accessToken: String
    var refreshToken: String
    var organizationID: String?
}

enum DroidAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidAuth
    case expired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Droid not logged in. Run `droid` to sign in."
        case .invalidAuth: "Droid login couldn't be read. Run `droid` to sign in again."
        case .expired: "Droid session expired. Run `droid` to sign in again."
        }
    }
}

/// Reads droid's v2 credential store (`~/.factory`). droid encrypts its WorkOS tokens with AES-256-GCM
/// as `base64(iv16):base64(tag16):base64(ciphertext)`; on macOS the key lives in the login keychain
/// (service `Factory CLI`), with a key file on disk as the fallback store. droid tries the keychain
/// store first, so this does too.
struct DroidAuthStore: Sendable {
    static let loginKeychainPath = "~/.factory/auth.v2.loginkeychain"
    static let keyfilePath = "~/.factory/auth.v2.file"
    static let keyfileKeyPath = "~/.factory/auth.v2.key"
    static let keychainService = "Factory CLI"
    static let loginKeychainAccount = "auth-encryption-key-security-cli"

    var files: TextFileAccessing
    var keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    /// Local-only probe: a droid credential file exists. Never touches the keychain.
    func hasCredentialFiles() -> Bool {
        files.exists(Self.loginKeychainPath) || (files.exists(Self.keyfilePath) && files.exists(Self.keyfileKeyPath))
    }

    /// The current login, `nil` when droid has never signed in. Throws `invalidAuth` when a store
    /// exists but none of them decrypts into a usable login.
    func load() throws -> DroidAuth? {
        var sawStore = false
        if let envelope = try files.readTextIfPresent(Self.loginKeychainPath) {
            sawStore = true
            if let key = keychainKey(), let auth = decode(envelope, key: key, source: .loginKeychain, path: Self.loginKeychainPath) {
                return auth
            }
        }
        if let envelope = try files.readTextIfPresent(Self.keyfilePath) {
            sawStore = true
            if let keyText = try files.readTextIfPresent(Self.keyfileKeyPath),
               let key = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
               let auth = decode(envelope, key: key, source: .keyfile, path: Self.keyfilePath) {
                return auth
            }
            AppLog.warn(.auth, "droid: auth.v2.file present but its key is missing or wrong")
        }
        if sawStore { throw DroidAuthError.invalidAuth }
        return nil
    }

    /// Writes rotated tokens back into the store they came from, re-encrypted with the same key, so
    /// droid keeps working with the refresh token WorkOS just rotated.
    func save(_ auth: DroidAuth, accessToken: String, refreshToken: String) throws -> DroidAuth {
        guard var object = (try? JSONSerialization.jsonObject(with: auth.document)) as? [String: Any] else {
            throw DroidAuthError.invalidAuth
        }
        object["access_token"] = accessToken
        object["refresh_token"] = refreshToken
        let document = try JSONSerialization.data(withJSONObject: object)
        try files.writeText(auth.envelopePath, try Self.seal(document, key: auth.key))
        var updated = auth
        updated.document = document
        updated.accessToken = accessToken
        updated.refreshToken = refreshToken
        return updated
    }

    private func keychainKey() -> Data? {
        do {
            guard let text = try keychain.readGenericPassword(service: Self.keychainService, account: Self.loginKeychainAccount) else {
                return nil
            }
            return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            AppLog.warn(.auth, "droid: keychain key unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func decode(_ envelope: String, key: Data, source: DroidAuth.Source, path: String) -> DroidAuth? {
        guard let document = try? Self.open(envelope, key: key) else {
            AppLog.warn(.auth, "droid: \(source.rawValue) store failed to decrypt")
            return nil
        }
        guard let object = ProviderParse.jsonObject(document),
              let access = (object["access_token"] as? String)?.nilIfEmpty,
              let refresh = (object["refresh_token"] as? String)?.nilIfEmpty else {
            AppLog.warn(.auth, "droid: \(source.rawValue) store has no tokens")
            return nil
        }
        return DroidAuth(
            source: source, envelopePath: path, key: key, document: document,
            accessToken: access, refreshToken: refresh,
            organizationID: (object["active_organization_id"] as? String)?.nilIfEmpty
        )
    }

    static func open(_ envelope: String, key: Data) throws -> Data {
        let parts = envelope.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard key.count == 32, parts.count == 3,
              let iv = Data(base64Encoded: String(parts[0])), iv.count == 16,
              let tag = Data(base64Encoded: String(parts[1])), tag.count == 16,
              let ciphertext = Data(base64Encoded: String(parts[2])) else {
            throw DroidAuthError.invalidAuth
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    static func seal(_ plaintext: Data, key: Data) throws -> String {
        var iv = Data(count: 16)
        let status = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw DroidAuthError.invalidAuth }
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
        return "\(iv.base64EncodedString()):\(box.tag.base64EncodedString()):\(box.ciphertext.base64EncodedString())"
    }
}
