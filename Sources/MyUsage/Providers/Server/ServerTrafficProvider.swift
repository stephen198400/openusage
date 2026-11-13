import Foundation

/// Monthly traffic on one of the user's own servers, read from the token-gated JSON the server probe
/// (`script/server-probe/`) publishes. The server reports bytes; the quota and reset day are the plan's,
/// entered in Customize → Server, so the meter is "share of this month's allowance used". One runtime per
/// configured server; it re-reads its entry on every refresh so edits apply without a relaunch.
@MainActor
final class ServerTrafficProvider: ProviderRuntime {
    let provider: Provider

    let configStore: ServerTrafficConfigStore
    let http: any HTTPClient
    let now: @Sendable () -> Date

    static func makeProvider(id: String = ServerTrafficConfigStore.family, displayName: String = "Server") -> Provider {
        Provider(id: id, displayName: displayName.isEmpty ? "Server" : displayName, icon: .providerMark("server"))
    }

    init(
        provider: Provider = ServerTrafficProvider.makeProvider(),
        configStore: ServerTrafficConfigStore = ServerTrafficConfigStore(),
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.configStore = configStore
        self.http = http
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).traffic", provider: provider, title: "Traffic")
                .exportingLimit("traffic", unit: "percent"),
            .boundedCount(id: "\(provider.id).dataUsed", provider: provider, title: "Data Used",
                          limit: 500, suffix: "GB", periodDurationMs: 30 * 24 * 60 * 60 * 1000)
                .exportingLimit("dataUsed", unit: "GB")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        let id = provider.id
        return await loadOffMainActor { [configStore] in configStore.load(cardID: id) } != nil
    }

    func refresh() async -> ProviderSnapshot {
        let id = provider.id
        guard let config = await loadOffMainActor({ [configStore] in configStore.load(cardID: id) }) else {
            return ProviderSnapshot.error(provider: provider, error: ServerTrafficError.notConfigured)
        }
        if let error = config.validationError {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let url = URL(string: config.url) else {
            return ProviderSnapshot.error(provider: provider, error: ServerTrafficError.invalidURL)
        }

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET",
                url: url,
                headers: ["Authorization": "Bearer \(config.token)", "Accept": "application/json"],
                timeout: 15
            ))
        } catch {
            return ProviderSnapshot.error(provider: provider, error: ServerTrafficError.connectionFailed)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderSnapshot.error(provider: provider, error: ServerTrafficError.unauthorized)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(provider: provider, error: ServerTrafficError.requestFailed(response.statusCode))
        }

        do {
            let payload = try ServerTrafficMapper.parse(response.body)
            let mapped = ServerTrafficMapper.lines(payload, config: config, now: now())
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: mapped.lines, refreshedAt: now(), warning: mapped.warning)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
