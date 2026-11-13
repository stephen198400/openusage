import Foundation

/// A finished in-app login: a label for Settings and the credential JSON written to `SignInVault`.
struct SignInResult: Sendable, Equatable {
    var label: String
    var credential: String
}

protocol ProviderSignIn: Sendable {
    func signIn(
        prompt: @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> SignInResult
}

/// Claude's own OAuth app (the one Claude Code uses), signed in with PKCE and a loopback callback.
/// The page can also end on a `code#state` the user pastes back.
struct ClaudeSignIn: ProviderSignIn {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// `/api/oauth/usage` and `/api/oauth/profile` need `user:profile`; spending a reset also needs
    /// `user:inference`. A refresh must ask for the same set, never more.
    static let scopes = "user:profile user:inference"

    var http: any HTTPClient = URLSessionHTTPClient()
    var now: @Sendable () -> Date = Date.init

    func signIn(
        prompt: @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> SignInResult {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let server = try await LoopbackCallbackServer.start(state: state)
        let code = try await authorizeInBrowser(
            Self.authorizeURL, clientID: Self.clientID, scopes: Self.scopes, state: state, pkce: pkce,
            server: server, extraQuery: [URLQueryItem(name: "code", value: "true")],
            prompt: prompt, pastedCode: pastedCode
        )
        let response = try await LoginHTTP.postJSON(Self.tokenURL, fields: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "state": state,
            "redirect_uri": server.redirectURI,
            "code_verifier": pkce.verifier
        ], using: http)
        let token = try LoginHTTP.decode(OAuthTokenResponse.self, from: response)
        let email = await profileEmail(accessToken: token.accessToken)
        return SignInResult(
            label: email ?? "Claude Account",
            credential: try Self.credentialJSON(token: token, email: email, now: now())
        )
    }

    /// The stored shape matches Claude Code's credentials file, so `ClaudeAuthStore` reads and rotates
    /// it with the same code it uses for Claude Code's own login.
    static func credentialJSON(token: OAuthTokenResponse, email: String?, now: Date) throws -> String {
        var oauth: [String: Any] = [
            "accessToken": token.accessToken,
            "scopes": scopes.split(separator: " ").map(String.init)
        ]
        if let refreshToken = token.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresIn = token.expiresIn {
            oauth["expiresAt"] = (now.timeIntervalSince1970 + expiresIn) * 1000
        }
        var document: [String: Any] = ["claudeAiOauth": oauth]
        if let email { document["myusageEmail"] = email }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func profileEmail(accessToken: String) async -> String? {
        struct Profile: Decodable {
            struct Account: Decodable { var email: String? }
            var account: Account?
        }
        do {
            let response = try await LoginHTTP.get(
                Self.profileURL, bearerToken: accessToken,
                headers: ["anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"],
                using: http
            )
            return try LoginHTTP.decode(Profile.self, from: response).account?.email
        } catch {
            // The token works without it; the label just falls back to a generic name.
            AppLog.warn(LogTag.auth("claude"), "profile read after sign-in failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// ChatGPT's Codex OAuth app with PKCE on the fixed port the Codex CLI uses. When that port is
/// taken (a Codex CLI login is running), falls back to the device-code flow.
struct CodexSignIn: ProviderSignIn {
    static let clientID = CodexUsageClient.clientID
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let scopes = "openid profile email offline_access"

    var http: any HTTPClient = URLSessionHTTPClient()
    var now: @Sendable () -> Date = Date.init

    func signIn(
        prompt: @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> SignInResult {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let server: LoopbackCallbackServer
        do {
            server = try await LoopbackCallbackServer.start(state: state, port: 1455, path: "/auth/callback")
        } catch {
            AppLog.info(LogTag.auth("codex"), "callback port busy; using device sign-in")
            return try await deviceSignIn(prompt: prompt)
        }
        let code = try await authorizeInBrowser(
            Self.authorizeURL, clientID: Self.clientID, scopes: Self.scopes, state: state, pkce: pkce,
            server: server,
            extraQuery: [
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: "pi")
            ],
            prompt: prompt, pastedCode: pastedCode
        )
        return try await exchange(code: code, verifier: pkce.verifier, redirectURI: server.redirectURI)
    }

    private func deviceSignIn(prompt: @Sendable (LoginPrompt) async -> Void) async throws -> SignInResult {
        struct DeviceStart: Decodable {
            let deviceAuthID: String
            let userCode: String
            enum CodingKeys: String, CodingKey {
                case deviceAuthID = "device_auth_id"
                case userCode = "user_code"
            }
        }
        struct DeviceToken: Decodable, Sendable {
            let authorizationCode: String
            let codeVerifier: String
            enum CodingKeys: String, CodingKey {
                case authorizationCode = "authorization_code"
                case codeVerifier = "code_verifier"
            }
        }
        let startURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
        let start = try await LoginHTTP.postJSON(startURL, fields: ["client_id": Self.clientID], using: http)
        let device = try LoginHTTP.decode(DeviceStart.self, from: start)
        await prompt(.deviceCode(userCode: device.userCode, verificationURL: URL(string: "https://auth.openai.com/codex/device")!))
        let interval = ProviderParse.number(ProviderParse.jsonObject(start.body)?["interval"]) ?? 5
        let token: DeviceToken = try await DeviceCodePoller.poll(interval: interval, expiresIn: 900) { [http] in
            let url = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
            let response = try await LoginHTTP.postJSON(url, fields: [
                "device_auth_id": device.deviceAuthID,
                "user_code": device.userCode
            ], using: http)
            if (200..<300).contains(response.statusCode) {
                return .complete(try LoginHTTP.decode(DeviceToken.self, from: response))
            }
            if response.statusCode == 403 || response.statusCode == 404 { return .pending }
            let error = ProviderParse.jsonObject(response.body)?["error"] as? String ?? ""
            if error == "deviceauth_authorization_pending" { return .pending }
            if error == "slow_down" { return .slowDown }
            return .failed(error == "expired_token" ? "Device sign-in expired." : "Device sign-in failed.")
        }
        return try await exchange(
            code: token.authorizationCode,
            verifier: token.codeVerifier,
            redirectURI: "https://auth.openai.com/deviceauth/callback"
        )
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> SignInResult {
        let response = try await LoginHTTP.postForm(Self.tokenURL, fields: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ], using: http)
        let token = try LoginHTTP.decode(OAuthTokenResponse.self, from: response)
        let email = token.idToken.flatMap(ProviderParse.jwtPayload)?["email"] as? String
        return SignInResult(
            label: email ?? "ChatGPT Account",
            credential: try Self.credentialJSON(token: token, now: now())
        )
    }

    /// The stored shape is Codex's own `auth.json`, so `CodexAuthStore` reads and rotates it with the
    /// same code it uses for the Codex CLI's login.
    static func credentialJSON(token: OAuthTokenResponse, now: Date) throws -> String {
        let claims = ProviderParse.jwtPayload(token.accessToken)?["https://api.openai.com/auth"] as? [String: Any]
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                idToken: token.idToken,
                accountID: claims?["chatgpt_account_id"] as? String
            ),
            lastRefresh: MyUsageISO8601.string(from: now),
            apiKey: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(auth), as: UTF8.self)
    }

    /// The email in a stored credential's ID token, for the Settings label.
    static func email(inCredential text: String) -> String? {
        guard let idToken = CodexAuthStore.parseAuth(text)?.tokens?.idToken else { return nil }
        return ProviderParse.jwtPayload(idToken)?["email"] as? String
    }
}
