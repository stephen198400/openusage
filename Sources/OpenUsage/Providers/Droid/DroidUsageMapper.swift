import Foundation

/// Maps `/api/billing/limits` (what droid itself reads for its usage warnings) into Factory's rolling
/// Standard-usage windows: 5-hour (Session), Weekly and Monthly, each a used percent with its window end.
/// A window that hasn't started yet reports `windowEnd: null`.
enum DroidUsageMapper {
    static let windows: [(key: String, label: String, periodMs: Int)] = [
        ("fiveHour", "Session", MetricPeriod.sessionMs),
        ("weekly", "Weekly", MetricPeriod.weekMs),
        ("monthly", "Monthly", MetricPeriod.monthMs)
    ]

    static func map(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body),
              let limits = root["limits"] as? [String: Any],
              let standard = limits["standard"] as? [String: Any] else {
            throw DroidUsageError.invalidResponse
        }
        let lines = windows.compactMap { window -> MetricLine? in
            guard let bucket = standard[window.key] as? [String: Any],
                  let used = ProviderParse.number(bucket["usedPercent"]) else { return nil }
            return .progress(label: window.label, used: ProviderParse.clampPercent(used), limit: 100, format: .percent,
                             resetsAt: (bucket["windowEnd"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                             periodDurationMs: window.periodMs)
        }
        guard !lines.isEmpty else { throw DroidUsageError.invalidResponse }
        return lines
    }
}
