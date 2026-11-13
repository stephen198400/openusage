import Foundation

/// Which direction(s) the hosting plan bills. Panels differ: some count both, many only outbound.
enum ServerTrafficCountMode: String, Codable, CaseIterable, Sendable {
    case outbound, inbound, total, larger

    var label: String {
        switch self {
        case .outbound: return "Outbound"
        case .inbound: return "Inbound"
        case .total: return "In + Out"
        case .larger: return "Larger"
        }
    }
}

/// One server the Server provider watches: where its traffic probe lives and the plan's monthly
/// allowance. The server has no way to know its plan, so the quota and reset day come from the user.
struct ServerTrafficConfig: Codable, Hashable, Sendable {
    var name: String
    var url: String
    var token: String
    /// Monthly allowance in GB (1 GB = 1024³ bytes, the unit VPS panels and vnStat use).
    var quotaGB: Double
    /// Day of the month the allowance resets, 1–31; months shorter than this reset on their last day.
    var resetDay: Int
    var countMode: ServerTrafficCountMode = .total
    /// GB the plan had already counted this period before the probe started (read off the provider's
    /// panel). It applies only to the period that contains `carryOverSetAt`, so it lapses at the next reset.
    var carryOverGB: Double?
    var carryOverSetAt: Date?
    /// Dashboard card id; assigned by `ServerTrafficConfigStore` (see there).
    var id: String?

    /// The reason the config can't be used, or nil when it's valid.
    var validationError: ServerTrafficError? {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)),
              parsed.scheme?.lowercased() == "https",
              parsed.host?.isEmpty == false else { return .invalidURL }
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingToken }
        if !(quotaGB > 0) || !quotaGB.isFinite { return .invalidQuota }
        if !(1...31).contains(resetDay) { return .invalidResetDay }
        if let carryOverGB, !(carryOverGB >= 0) || !carryOverGB.isFinite { return .invalidQuota }
        return nil
    }
}

extension ServerTrafficConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        token = try c.decode(String.self, forKey: .token)
        quotaGB = try c.decode(Double.self, forKey: .quotaGB)
        resetDay = try c.decode(Int.self, forKey: .resetDay)
        countMode = try c.decodeIfPresent(ServerTrafficCountMode.self, forKey: .countMode) ?? .total
        carryOverGB = try c.decodeIfPresent(Double.self, forKey: .carryOverGB)
        carryOverSetAt = try c.decodeIfPresent(Date.self, forKey: .carryOverSetAt)
        id = try c.decodeIfPresent(String.self, forKey: .id)
    }
}

/// Reads and writes `~/.config/openusage/server.json`, the same plain config-file pattern the API-key
/// providers use, so the file stays the source of truth and can be edited by hand. The file holds
/// `{"servers": [...]}`; a bare single-server object from the first release still reads as one server.
///
/// Each server is one dashboard card. The first is card `server`, so a single-server setup keeps its
/// layout and stars; later ones are `server@<hash of their URL when added>`, stored in the entry's `id`
/// so editing the URL doesn't orphan the card.
struct ServerTrafficConfigStore: Sendable {
    static let configPath = "~/.config/openusage/server.json"
    static let family = "server"

    var files: TextFileAccessing

    init(files: TextFileAccessing = LocalTextFileAccessor()) {
        self.files = files
    }

    private struct File: Codable {
        var servers: [ServerTrafficConfig]
    }

    /// Every configured server with its card id filled in, in file order.
    func loadAll() -> [ServerTrafficConfig] {
        guard files.exists(Self.configPath),
              let text = try? files.readText(Self.configPath),
              let data = text.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let servers = (try? decoder.decode(File.self, from: data).servers)
            ?? (try? decoder.decode(ServerTrafficConfig.self, from: data)).map { [$0] }
            ?? []
        return servers.enumerated().map { index, server in
            var server = server
            if server.id == nil || server.id?.isEmpty == true {
                server.id = index == 0 ? Self.family : ProviderAccountID.make(family: Self.family, identityKey: server.url)
            }
            return server
        }
    }

    func load(cardID: String) -> ServerTrafficConfig? {
        loadAll().first { $0.id == cardID }
    }

    /// Replace the server whose `id` matches, or append it as a new card (assigning its id).
    @discardableResult
    func save(_ config: ServerTrafficConfig) throws -> ServerTrafficConfig {
        var config = config
        config.name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.url = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        config.token = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = config.validationError { throw error }
        var servers = loadAll()
        if servers.contains(where: { $0.url == config.url && $0.id != config.id }) {
            throw ServerTrafficError.duplicateServer
        }
        if let index = servers.firstIndex(where: { $0.id == config.id }), config.id != nil {
            servers[index] = config
        } else {
            config.id = servers.isEmpty ? Self.family : ProviderAccountID.make(family: Self.family, identityKey: config.url)
            servers.append(config)
        }
        try write(servers)
        return config
    }

    func delete(cardID: String) throws {
        let servers = loadAll().filter { $0.id != cardID }
        if servers.isEmpty {
            guard files.exists(Self.configPath) else { return }
            do { try files.remove(Self.configPath) } catch { throw ServerTrafficError.saveFailed }
        } else {
            try write(servers)
        }
    }

    private func write(_ servers: [ServerTrafficConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let text = String(data: try encoder.encode(File(servers: servers)), encoding: .utf8) else {
            throw ServerTrafficError.saveFailed
        }
        do {
            try files.writeText(Self.configPath, text)
        } catch {
            AppLog.error(.auth, "save server probe config failed: \(error.localizedDescription)")
            throw ServerTrafficError.saveFailed
        }
    }
}

enum ServerTrafficError: Error, LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case missingToken
    case invalidQuota
    case invalidResetDay
    case saveFailed
    case duplicateServer
    case unauthorized
    case connectionFailed
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No server set up. Add one in Customize → Server."
        case .invalidURL: return "Probe URL must be an https:// address."
        case .missingToken: return "Enter the probe token."
        case .invalidQuota: return "Monthly quota must be more than 0 GB."
        case .invalidResetDay: return "Reset day must be between 1 and 31."
        case .saveFailed: return "Couldn't save the server settings."
        case .duplicateServer: return "That probe URL is already added."
        case .unauthorized: return "Probe token rejected. Check /etc/openusage-probe/token on the server."
        case .connectionFailed: return "Couldn't reach the server probe. Check your connection."
        case .requestFailed(let status): return "Server probe request failed (HTTP \(status))."
        case .invalidResponse: return "Server probe returned data MyUsage can't read."
        }
    }
}
