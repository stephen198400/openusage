import Foundation

enum DroidUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed: "Couldn't reach Factory. Check your connection."
        case .invalidResponse: "Factory usage response was invalid. Try again later."
        case .requestFailed(let status): "Factory usage request failed (HTTP \(status)). Try again later."
        }
    }
}

/// Factory's billing-limits endpoint (droid reads it for its own usage-limit warnings) and the WorkOS
/// token refresh droid itself uses.
struct DroidUsageClient: Sendable {
    static let usageURL = URL(string: "https://api.factory.ai/api/billing/limits")!
    static let refreshURL = URL(string: "https://api.workos.com/user_management/authenticate")!
    static let workOSClientID = "client_01HNM792M5G5G1A2THWPXKFMXB"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "User-Agent": "MyUsage"
            ],
            timeout: 15
        ))
    }

    func refresh(refreshToken: String, organizationID: String?) async throws -> HTTPResponse {
        var body = "grant_type=refresh_token"
            + "&refresh_token=\(refreshToken.urlFormEncoded)"
            + "&client_id=\(Self.workOSClientID.urlFormEncoded)"
        if let organizationID { body += "&organization_id=\(organizationID.urlFormEncoded)" }
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))
    }
}
