import XCTest
@testable import MyUsage

final class MemorySignInVault: SignInVault, @unchecked Sendable {
    var values: [SignInProvider: String]
    var writes: [(SignInProvider, String)] = []

    init(_ values: [SignInProvider: String] = [:]) {
        self.values = values
    }

    func read(_ provider: SignInProvider) throws -> String? { values[provider] }

    func write(_ provider: SignInProvider, value: String) throws {
        values[provider] = value
        writes.append((provider, value))
    }

    func delete(_ provider: SignInProvider) throws { values[provider] = nil }
}

final class AuthorizationCodeTests: XCTestCase {
    func testCallbackURLWithMatchingStateYieldsCode() throws {
        let code = try authorizationCode(
            from: .pasted("http://localhost:1455/auth/callback?code=abc&state=s1"), expectedState: "s1"
        )
        XCTAssertEqual(code, "abc")
    }

    func testMismatchedStateIsRejected() {
        XCTAssertThrowsError(try authorizationCode(from: .pasted("abc#other"), expectedState: "s1")) {
            XCTAssertEqual($0 as? LoginError, .invalidState)
        }
    }

    func testCodeHashStateAndBareCodeAreAccepted() throws {
        XCTAssertEqual(try authorizationCode(from: .pasted(" abc#s1 \n"), expectedState: "s1"), "abc")
        XCTAssertEqual(try authorizationCode(from: .pasted("abc"), expectedState: "s1"), "abc")
    }

    func testEmptyPasteIsRejected() {
        XCTAssertThrowsError(try authorizationCode(from: .pasted("#s1"), expectedState: "s1")) {
            XCTAssertEqual($0 as? LoginError, .invalidCode)
        }
    }
}

@MainActor
final class ClaudeSignInStoreTests: XCTestCase {
    private let signedIn = #"{"claudeAiOauth":{"accessToken":"signin-token","refreshToken":"signin-refresh","expiresAt":1000,"scopes":["user:profile","user:inference"]},"myusageEmail":"me@example.com"}"#

    func testSignInIsTheOnlyCandidateEvenWithClaudeCodeLoggedIn() {
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] = #"{"claudeAiOauth":{"accessToken":"cli-token"}}"#
        let store = ClaudeAuthStore(
            files: FakeFiles(["~/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token"}}"#]),
            keychain: keychain,
            signInVault: MemorySignInVault([.claude: signedIn])
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["signin-token"])
        XCTAssertEqual(candidates.first?.source, .signIn)
    }

    func testSignedOutVaultYieldsNoCandidates() {
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] = #"{"claudeAiOauth":{"accessToken":"cli-token"}}"#
        let store = ClaudeAuthStore(files: FakeFiles(), keychain: keychain, signInVault: MemorySignInVault())

        XCTAssertTrue(store.loadCredentialCandidates().isEmpty)
    }

    func testRotationIsSavedBackToTheVaultKeepingTheEmail() throws {
        let vault = MemorySignInVault([.claude: signedIn])
        let store = ClaudeAuthStore(files: FakeFiles(), keychain: FakeKeychain(), signInVault: vault)
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)
        let generation = store.credentialGeneration()
        state.oauth.accessToken = "rotated"
        state.oauth.refreshToken = "rotated-refresh"

        XCTAssertTrue(try store.save(state, ifUnchanged: generation))

        let saved = try XCTUnwrap(vault.values[.claude])
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(saved)?.claudeAiOauth?.accessToken, "rotated")
        XCTAssertEqual(SignInStore.label(for: .claude, credential: saved), "me@example.com")
    }

    func testRefreshAsksOnlyForTheScopesTheSignInWasGranted() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"access_token":"new","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
        ))
        let vault = MemorySignInVault([.claude: signedIn])
        let store = ClaudeAuthStore(files: FakeFiles(), keychain: FakeKeychain(), signInVault: vault)
        let provider = ClaudeProvider(authStore: store, usageClient: ClaudeUsageClient(httpClient: http))
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)

        let refreshed = try await provider.refreshAccessToken(
            state: &state, refreshToken: "signin-refresh", expectedGeneration: store.credentialGeneration()
        )

        XCTAssertEqual(refreshed.accessToken, "new")
        XCTAssertTrue(refreshed.persisted)
        let body = try XCTUnwrap(http.requests.first?.body)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["scope"] as? String, "user:profile user:inference")
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(vault.values[.claude]!)?.claudeAiOauth?.refreshToken, "new-refresh")
    }

    func testRefusedRenewalAsksToSignInAgainInSettings() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8)
        ))
        let store = ClaudeAuthStore(files: FakeFiles(), keychain: FakeKeychain(), signInVault: MemorySignInVault([.claude: signedIn]))
        let provider = ClaudeProvider(authStore: store, usageClient: ClaudeUsageClient(httpClient: http))
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)

        do {
            _ = try await provider.refreshAccessToken(
                state: &state, refreshToken: "signin-refresh", expectedGeneration: store.credentialGeneration()
            )
            XCTFail("expected signInRequired")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .signInRequired)
        }
    }

    func testCredentialJSONIsReadableAsAClaudeLogin() throws {
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(
            #"{"access_token":"a","refresh_token":"r","expires_in":60}"#.utf8
        ))
        let text = try ClaudeSignIn.credentialJSON(token: token, email: nil, now: Date(timeIntervalSince1970: 100))

        let oauth = try XCTUnwrap(ClaudeAuthStore.parseCredentials(text)?.claudeAiOauth)
        XCTAssertEqual(oauth.accessToken, "a")
        XCTAssertEqual(oauth.refreshToken, "r")
        XCTAssertEqual(oauth.expiresAt, 160_000)
        XCTAssertEqual(oauth.scopes, ["user:profile", "user:inference"])
        XCTAssertEqual(SignInStore.label(for: .claude, credential: text), "Claude Account")
    }
}

@MainActor
final class CodexSignInStoreTests: XCTestCase {
    private func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    func testCredentialJSONCarriesAccountIDAndEmail() throws {
        let access = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]])
        let id = jwt(["email": "me@example.com"])
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(
            #"{"access_token":"\#(access)","refresh_token":"r","id_token":"\#(id)"}"#.utf8
        ))

        let text = try CodexSignIn.credentialJSON(token: token, now: Date())

        let auth = try XCTUnwrap(CodexAuthStore.parseAuth(text))
        XCTAssertEqual(auth.tokens?.accountID, "acct-1")
        XCTAssertEqual(auth.tokens?.refreshToken, "r")
        XCTAssertEqual(SignInStore.label(for: .codex, credential: text), "me@example.com")
    }

    func testSignInLoadsAndSavesThroughTheVault() throws {
        let vault = MemorySignInVault([.codex: #"{"tokens":{"access_token":"a","refresh_token":"r"}}"#])
        let store = CodexAuthStore(files: FakeFiles(), keychain: FakeKeychain(), signInVault: vault)
        let loaded = try XCTUnwrap(store.loadSignInAuth())
        var rotated = loaded
        rotated.auth.tokens?.accessToken = "b"

        try store.save(rotated, replacing: loaded)

        XCTAssertEqual(store.loadSignInAuth()?.auth.tokens?.accessToken, "b")
    }

    func testSaveRefusesToOverwriteALoginThatChangedMeanwhile() throws {
        let vault = MemorySignInVault([.codex: #"{"tokens":{"access_token":"a"}}"#])
        let store = CodexAuthStore(files: FakeFiles(), keychain: FakeKeychain(), signInVault: vault)
        let loaded = try XCTUnwrap(store.loadSignInAuth())
        vault.values[.codex] = #"{"tokens":{"access_token":"newer"}}"#

        XCTAssertThrowsError(try store.save(loaded, replacing: loaded)) {
            XCTAssertEqual($0 as? CodexAuthError, .tokenConflict)
        }
    }

    func testSignedInCardIgnoresTheCodexCLILogin() async {
        let store = CodexAuthStore(
            files: FakeFiles(["~/.codex/auth.json": #"{"tokens":{"access_token":"cli"}}"#]),
            keychain: FakeKeychain(),
            signInVault: MemorySignInVault()
        )
        let snapshot = await CodexProvider.isolated(authStore: store).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        guard case .badge(_, let text, _, _)? = snapshot.lines.first else { return XCTFail("expected an error badge") }
        XCTAssertEqual(text, CodexAuthError.signInRequired.localizedDescription)
    }
}
