import Foundation

/// Factory's droid CLI: the Standard-usage rolling limits (5-hour, weekly, monthly) shown on Factory's
/// usage page. Reads the login droid already saved in `~/.factory`; see `DroidAuthStore`.
@MainActor
final class DroidProvider: ProviderRuntime {
    let provider = Provider(
        id: "droid",
        displayName: "Droid",
        icon: .providerMark("droid"),
        links: [.init(label: "Dashboard", url: "https://app.factory.ai/settings/billing")]
    )

    let authStore: DroidAuthStore
    let usageClient: DroidUsageClient
    let now: @Sendable () -> Date

    /// Refresh a token this close to expiry before using it, so the first request isn't a wasted 401.
    static let expiryBuffer: TimeInterval = 60

    init(
        authStore: DroidAuthStore = DroidAuthStore(),
        usageClient: DroidUsageClient = DroidUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "droid.session", provider: provider, title: "Session", sessionStartSignal: .missingResetDate)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "droid.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "droid.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasCredentialFiles() }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            guard var auth = try await loadOffMainActor({ [authStore] in try authStore.load() }) else {
                return ProviderSnapshot.error(provider: provider, error: DroidAuthError.notLoggedIn)
            }
            if isExpired(auth.accessToken) {
                auth = try await refreshTokens(auth)
            }
            let current = auth
            var refreshed: DroidAuth?
            let response = try await ProviderAuthRetry.fetch(
                token: current.accessToken,
                attempt: { [usageClient] token in try await usageClient.fetchUsage(accessToken: token) },
                refreshAccessToken: {
                    let next = try await self.refreshTokens(refreshed ?? current)
                    refreshed = next
                    return next.accessToken
                },
                connectionFailed: DroidUsageError.connectionFailed,
                authExpired: DroidAuthError.expired
            )
            try ProviderAuthRetry.requireSuccess(response, authExpired: DroidAuthError.expired,
                                                 requestFailed: DroidUsageError.requestFailed)
            let lines = try DroidUsageMapper.map(response.body)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func isExpired(_ token: String) -> Bool {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return false }
        return Date(timeIntervalSince1970: exp) <= now().addingTimeInterval(Self.expiryBuffer)
    }

    /// WorkOS rotates the refresh token on every use, so the new pair is written back to droid's store
    /// right away — otherwise droid would be left holding a dead refresh token.
    private func refreshTokens(_ auth: DroidAuth) async throws -> DroidAuth {
        let response: HTTPResponse
        do {
            response = try await usageClient.refresh(refreshToken: auth.refreshToken, organizationID: auth.organizationID)
        } catch {
            throw DroidUsageError.connectionFailed
        }
        if [400, 401, 403].contains(response.statusCode) { throw DroidAuthError.expired }
        guard (200..<300).contains(response.statusCode) else { throw DroidUsageError.requestFailed(response.statusCode) }
        guard let body = ProviderParse.jsonObject(response.body),
              let access = (body["access_token"] as? String)?.nilIfEmpty else {
            throw DroidUsageError.invalidResponse
        }
        let refresh = (body["refresh_token"] as? String)?.nilIfEmpty ?? auth.refreshToken
        AppLog.info(.auth, "droid: token refreshed, saving to \(auth.source.rawValue) store")
        return try await loadOffMainActor { [authStore] in try authStore.save(auth, accessToken: access, refreshToken: refresh) }
    }
}
