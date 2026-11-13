import XCTest
@testable import OpenUsage

@MainActor
final class DroidProviderTests: XCTestCase {
    private let keyB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private var key: Data { Data(base64Encoded: keyB64)! }
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Encrypted by Python's AES-GCM with droid's layout (16-byte IV), so CryptoKit must read droid's files.
    func testOpensNodeCompatibleEnvelope() throws {
        let envelope = "ZGVmZ2hpamtsbW5vcHFycw==:yKRw2rzhvWxUKSo+Taha8A==:o5EiModxVKvtjcLiIrnOX3gQeuy+nYVtt+VnBsaDaKMer6z2QrnBvA=="
        let plain = try DroidAuthStore.open(envelope, key: key)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), #"{"access_token":"a","refresh_token":"r"}"#)
        XCTAssertThrowsError(try DroidAuthStore.open(envelope, key: Data(repeating: 1, count: 32)))
        XCTAssertThrowsError(try DroidAuthStore.open("not:an:envelope", key: key))
    }

    func testMapsRollingWindowsToPercentLines() throws {
        let lines = try DroidUsageMapper.map(Self.usageBody())
        XCTAssertEqual(lines.count, 3)
        guard case .progress(let label, let used, let limit, _, let resetsAt, let period, _) = lines[0] else {
            return XCTFail("expected progress")
        }
        XCTAssertEqual(label, "Session")
        XCTAssertEqual(used, 6)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-11-06T07:57:03.743Z"))
        XCTAssertEqual(period, MetricPeriod.sessionMs)
        // A window that hasn't started yet has no end, so no reset.
        guard case .progress(let monthly, _, _, _, let monthlyReset, _, _) = lines[2] else { return XCTFail() }
        XCTAssertEqual(monthly, "Monthly")
        XCTAssertNil(monthlyReset)

        XCTAssertThrowsError(try DroidUsageMapper.map(Data(#"{"limits":{}}"#.utf8)))
    }

    func testNotLoggedInWithoutStore() async {
        let provider = DroidProvider(authStore: DroidAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
                                     usageClient: DroidUsageClient(http: FakeHTTPClient(response: Self.ok(Data()))), now: { Self.now })
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
    }

    func testReadsLoginKeychainStoreAndFetchesUsage() async throws {
        let files = try store(access: jwt(exp: Self.now.timeIntervalSince1970 + 3600))
        let http = RoutingHTTPClient { _ in Self.ok(Self.usageBody()) }
        let provider = DroidProvider(authStore: DroidAuthStore(files: files, keychain: FakeKeychain(keyB64)),
                                     usageClient: DroidUsageClient(http: http), now: { Self.now })
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.method), ["GET"])
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
    }

    /// An expired token refreshes first, and the rotated pair is written back (re-encrypted) so droid
    /// keeps a working refresh token; other fields in droid's JSON survive.
    func testExpiredTokenRefreshesAndWritesBack() async throws {
        let files = try store(access: jwt(exp: Self.now.timeIntervalSince1970 - 10))
        let http = RoutingHTTPClient { request in
            if request.url == DroidUsageClient.refreshURL {
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                XCTAssertTrue(body.contains("refresh_token=old-refresh"))
                XCTAssertTrue(body.contains("organization_id=org_1"))
                return Self.ok(Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8))
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer new-access")
            return Self.ok(Self.usageBody())
        }
        let provider = DroidProvider(authStore: DroidAuthStore(files: files, keychain: FakeKeychain(keyB64)),
                                     usageClient: DroidUsageClient(http: http), now: { Self.now })
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)

        let saved = try XCTUnwrap(ProviderParse.jsonObject(
            try DroidAuthStore.open(files.files[DroidAuthStore.loginKeychainPath]!, key: key)))
        XCTAssertEqual(saved["access_token"] as? String, "new-access")
        XCTAssertEqual(saved["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(saved["active_organization_id"] as? String, "org_1")
    }

    func testRejectedRefreshReportsExpired() async throws {
        let files = try store(access: jwt(exp: Self.now.timeIntervalSince1970 + 3600))
        let http = RoutingHTTPClient { request in
            request.url == DroidUsageClient.refreshURL
                ? HTTPResponse(statusCode: 400, headers: [:], body: Data())
                : HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = DroidProvider(authStore: DroidAuthStore(files: files, keychain: FakeKeychain(keyB64)),
                                     usageClient: DroidUsageClient(http: http), now: { Self.now })
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testFallsBackToKeyfileStore() async throws {
        let document = Data(#"{"access_token":"\#(jwt(exp: Self.now.timeIntervalSince1970 + 3600))","refresh_token":"r"}"#.utf8)
        let files = FakeFiles([
            DroidAuthStore.keyfilePath: try DroidAuthStore.seal(document, key: key),
            DroidAuthStore.keyfileKeyPath: keyB64 + "\n"
        ])
        let auth = try XCTUnwrap(try DroidAuthStore(files: files, keychain: FakeKeychain()).load())
        XCTAssertEqual(auth.source, .keyfile)
        XCTAssertEqual(auth.refreshToken, "r")
    }

    func testUndecryptableStoreIsInvalidNotLoggedOut() {
        let files = FakeFiles([DroidAuthStore.loginKeychainPath: "garbage"])
        XCTAssertThrowsError(try DroidAuthStore(files: files, keychain: FakeKeychain(keyB64)).load()) {
            XCTAssertEqual($0 as? DroidAuthError, .invalidAuth)
        }
    }

    // MARK: - Helpers

    private func store(access: String) throws -> FakeFiles {
        let document = try JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": "old-refresh",
            "active_organization_id": "org_1", "whoami": ["isEnterprise": false]
        ])
        return FakeFiles([DroidAuthStore.loginKeychainPath: try DroidAuthStore.seal(document, key: key)])
    }

    private func jwt(exp: TimeInterval) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9.\(encoded).sig"
    }

    private nonisolated static func usageBody() -> Data {
        let body: [String: Any] = ["limits": ["standard": [
            "fiveHour": ["usedPercent": 6, "windowEnd": "2026-11-06T07:57:03.743Z"],
            "weekly": ["usedPercent": 27, "windowEnd": "2026-11-07T01:29:01.381Z"],
            "monthly": ["usedPercent": 14, "windowEnd": NSNull()]
        ]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private nonisolated static func ok(_ body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}
