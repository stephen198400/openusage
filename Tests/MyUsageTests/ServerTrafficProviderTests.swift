import XCTest
@testable import MyUsage

final class ServerTrafficMapperTests: XCTestCase {
    private let tokyo = 9 * 3600

    private func date(_ text: String) -> Date {
        MyUsageISO8601.date(from: text)!
    }

    func testPeriodStartsOnTheResetDayInServerTime() {
        // 2026-11-04 17:00 Tokyo, resetting on the 17th → Oct 17 00:00 to Nov 17 00:00 Tokyo.
        let period = ServerTrafficMapper.period(containing: date("2026-11-04T08:00:00Z"), resetDay: 17,
                                                utcOffsetSeconds: tokyo)
        XCTAssertEqual(period.start, date("2026-10-16T15:00:00Z"))
        XCTAssertEqual(period.end, date("2026-11-16T15:00:00Z"))

        // On the reset day itself (00:30 Tokyo on Nov 17) the new period has begun.
        let onReset = ServerTrafficMapper.period(containing: date("2026-11-16T15:30:00Z"), resetDay: 17,
                                                 utcOffsetSeconds: tokyo)
        XCTAssertEqual(onReset.start, date("2026-11-16T15:00:00Z"))
        XCTAssertEqual(onReset.end, date("2026-12-16T15:00:00Z"))
    }

    func testResetDayPastMonthEndFallsOnTheLastDay() {
        let period = ServerTrafficMapper.period(containing: date("2027-02-10T00:00:00Z"), resetDay: 31,
                                                utcOffsetSeconds: 0)
        XCTAssertEqual(period.start, date("2027-01-31T00:00:00Z"))
        XCTAssertEqual(period.end, date("2027-02-28T00:00:00Z"))
    }

    func testSumsBothDirectionsInsideThePeriodOnly() throws {
        let gb = ServerTrafficMapper.bytesPerGB
        let payload = ServerTrafficPayload(
            schema: ServerTrafficPayload.schema, interface: "eth0", updatedAt: "2026-11-04T07:55:00Z",
            utcOffsetSeconds: tokyo,
            days: [
                .init(date: "2026-10-16", rx: 50 * gb, tx: 50 * gb),  // before the Oct 17 reset
                .init(date: "2026-10-17", rx: 100 * gb, tx: 100 * gb),
                .init(date: "2026-11-04", rx: 150 * gb, tx: 50 * gb)
            ]
        )
        let config = ServerTrafficConfig(name: "gomami", url: "https://x.test/t.json", token: "t",
                                         quotaGB: 500, resetDay: 17)

        let mapped = ServerTrafficMapper.lines(payload, config: config, now: date("2026-11-04T08:00:00Z"))

        guard case .progress(let label, let used, let limit, .percent, let resetsAt, _, _) = mapped.lines[0] else {
            return XCTFail("expected a percent meter")
        }
        XCTAssertEqual(label, "Traffic")
        XCTAssertEqual(used, 80, accuracy: 0.001)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(resetsAt, date("2026-11-16T15:00:00Z"))
        guard case .progress(_, let usedGB, let quota, .count(suffix: "GB"), _, _, _) = mapped.lines[1] else {
            return XCTFail("expected a GB meter")
        }
        XCTAssertEqual(usedGB, 400)
        XCTAssertEqual(quota, 500)
        XCTAssertNil(mapped.warning)
    }

    func testCountModeAndCarryOverMatchTheHostPanel() {
        // Hostycare bills outbound only; 406 GB had been counted before the probe was installed.
        let gb = ServerTrafficMapper.bytesPerGB
        let payload = ServerTrafficPayload(
            schema: ServerTrafficPayload.schema, interface: "eth0", updatedAt: "2026-11-04T07:55:00Z",
            utcOffsetSeconds: tokyo, days: [.init(date: "2026-11-04", rx: 2 * gb, tx: 1 * gb)]
        )
        let now = date("2026-11-04T08:00:00Z")
        var config = ServerTrafficConfig(name: "", url: "https://x.test", token: "t", quotaGB: 500, resetDay: 17,
                                         countMode: .outbound, carryOverGB: 406, carryOverSetAt: now)
        func dataUsed(at time: Date) -> Double? {
            guard case .progress(_, let used, _, _, _, _, _) = ServerTrafficMapper.lines(payload, config: config, now: time).lines[1] else { return nil }
            return used
        }
        XCTAssertEqual(dataUsed(at: now), 407)
        config.countMode = .larger
        XCTAssertEqual(dataUsed(at: now), 408)
        // After the Nov 17 reset the carry-over no longer applies (and Nov 4 is outside the period).
        XCTAssertEqual(dataUsed(at: date("2026-11-20T00:00:00Z")), 0)
    }

    func testWarnsWhenProbeDataIsStale() {
        let payload = ServerTrafficPayload(schema: ServerTrafficPayload.schema, interface: "eth0",
                                           updatedAt: "2026-11-04T06:00:00Z", utcOffsetSeconds: 0, days: [])
        let config = ServerTrafficConfig(name: "", url: "https://x.test", token: "t", quotaGB: 500, resetDay: 1)
        let mapped = ServerTrafficMapper.lines(payload, config: config, now: date("2026-11-04T08:00:00Z"))
        XCTAssertNotNil(mapped.warning)
    }

    func testRejectsUnknownSchema() {
        let body = Data(#"{"schema":"other/1","interface":"eth0","updatedAt":"x","utcOffsetSeconds":0,"days":[]}"#.utf8)
        XCTAssertThrowsError(try ServerTrafficMapper.parse(body))
    }
}

final class ServerTrafficConfigStoreTests: XCTestCase {
    private let valid = ServerTrafficConfig(name: " gomami ", url: "https://h.test:4443/openusage/traffic.json",
                                            token: " abc \n", quotaGB: 500, resetDay: 17)

    func testOlderConfigWithoutCountModeDefaultsToTotal() throws {
        let files = FakeFiles([ServerTrafficConfigStore.configPath:
            #"{"name":"a","url":"https://h.test","token":"t","quotaGB":500,"resetDay":17}"#])
        XCTAssertEqual(ServerTrafficConfigStore(files: files).loadAll().first?.countMode, .total)
    }

    func testSaveTrimsAndRoundTrips() throws {
        let files = FakeFiles()
        let store = ServerTrafficConfigStore(files: files)
        var valid = valid
        valid.countMode = .outbound
        valid.carryOverGB = 406.16
        valid.carryOverSetAt = MyUsageISO8601.date(from: "2026-11-04T08:40:00Z")
        try store.save(valid)
        let loaded = try XCTUnwrap(store.load(cardID: "server"))
        XCTAssertEqual(loaded.name, "gomami")
        XCTAssertEqual(loaded.token, "abc")
        XCTAssertEqual(loaded.resetDay, 17)
        XCTAssertEqual(loaded.countMode, .outbound)
        XCTAssertEqual(loaded.carryOverGB, 406.16)
        XCTAssertEqual(loaded.carryOverSetAt, valid.carryOverSetAt)
    }

    func testLegacySingleServerFileReadsAsTheServerCard() {
        let files = FakeFiles([ServerTrafficConfigStore.configPath:
            #"{"name":"gomami","url":"https://a.test/t.json","token":"t","quotaGB":500,"resetDay":17}"#])
        let servers = ServerTrafficConfigStore(files: files).loadAll()
        XCTAssertEqual(servers.map(\.id), ["server"])
    }

    func testAddingServersGivesStableCardIDsAndEditsInPlace() throws {
        let files = FakeFiles()
        let store = ServerTrafficConfigStore(files: files)
        let first = try store.save(valid)
        var second = valid
        second.name = "dmit"
        second.url = "https://b.test:8443/openusage/traffic.json"
        let added = try store.save(second)
        XCTAssertEqual(first.id, "server")
        XCTAssertEqual(added.id, ProviderAccountID.make(family: "server", identityKey: second.url))

        // Editing the second server's URL keeps its card id.
        var edited = added
        edited.url = "https://c.test/openusage/traffic.json"
        try store.save(edited)
        XCTAssertEqual(store.loadAll().map(\.id), ["server", added.id])
        XCTAssertEqual(store.load(cardID: added.id!)?.url, edited.url)

        // Adding the same URL twice is refused; removing one keeps the other.
        var duplicate = valid
        duplicate.id = nil
        XCTAssertThrowsError(try store.save(duplicate)) { XCTAssertEqual($0 as? ServerTrafficError, .duplicateServer) }
        try store.delete(cardID: "server")
        XCTAssertEqual(store.loadAll().map(\.id), [added.id])
    }

    func testSaveRejectsInvalidInput() {
        let store = ServerTrafficConfigStore(files: FakeFiles())
        var config = valid
        config.url = "http://h.test/traffic.json"
        XCTAssertThrowsError(try store.save(config)) { XCTAssertEqual($0 as? ServerTrafficError, .invalidURL) }
        config = valid
        config.resetDay = 32
        XCTAssertThrowsError(try store.save(config)) { XCTAssertEqual($0 as? ServerTrafficError, .invalidResetDay) }
        config = valid
        config.quotaGB = 0
        XCTAssertThrowsError(try store.save(config)) { XCTAssertEqual($0 as? ServerTrafficError, .invalidQuota) }
        config = valid
        config.token = "  "
        XCTAssertThrowsError(try store.save(config)) { XCTAssertEqual($0 as? ServerTrafficError, .missingToken) }
        config = valid
        config.carryOverGB = -1
        XCTAssertThrowsError(try store.save(config)) { XCTAssertEqual($0 as? ServerTrafficError, .invalidQuota) }
    }
}

@MainActor
final class ServerTrafficProviderTests: XCTestCase {
    private func provider(status: Int, body: String, config: Bool = true) throws -> (ServerTrafficProvider, FakeHTTPClient) {
        let files = FakeFiles()
        let store = ServerTrafficConfigStore(files: files)
        if config {
            try store.save(ServerTrafficConfig(name: "gomami", url: "https://h.test/openusage/traffic.json",
                                               token: "secret", quotaGB: 500, resetDay: 17))
        }
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8)))
        let now = MyUsageISO8601.date(from: "2026-11-04T08:00:00Z")!
        return (ServerTrafficProvider(configStore: store, http: http, now: { now }), http)
    }

    func testSendsBearerTokenAndMapsTraffic() async throws {
        let body = #"{"schema":"openusage.server-traffic/1","interface":"eth0","updatedAt":"2026-11-04T07:55:00Z","utcOffsetSeconds":32400,"days":[{"date":"2026-11-04","rx":107374182400,"tx":0}]}"#
        let (runtime, http) = try provider(status: 200, body: body)
        let snapshot = await runtime.refresh()
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer secret")
        guard case .progress(_, let used, _, _, _, _, _) = snapshot.lines.first else { return XCTFail() }
        XCTAssertEqual(used, 20, accuracy: 0.001)
    }

    func testRejectedTokenIsAnError() async throws {
        let (runtime, _) = try provider(status: 401, body: "")
        let snapshot = await runtime.refresh()
        XCTAssertTrue(snapshot.lines.contains { if case .badge(MetricLine.errorBadgeLabel, _, _, _) = $0 { true } else { false } })
    }

    func testUnconfiguredIsAnErrorAndHasNoCredentials() async throws {
        let (runtime, http) = try provider(status: 200, body: "", config: false)
        let hasCredentials = await runtime.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
        _ = await runtime.refresh()
        XCTAssertTrue(http.requests.isEmpty)
    }
}
