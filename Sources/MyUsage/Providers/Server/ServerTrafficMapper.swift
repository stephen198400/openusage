import Foundation

/// The probe's export (`script/server-probe/install.sh`): vnStat's daily rx/tx rows, dated in the
/// server's local time, plus that time zone's offset so the billing period can be cut on the server's
/// own calendar.
struct ServerTrafficPayload: Decodable, Equatable, Sendable {
    static let schema = "openusage.server-traffic/1"

    struct Day: Decodable, Equatable, Sendable {
        var date: String
        var rx: Double
        var tx: Double
    }

    var schema: String
    var interface: String
    var updatedAt: String
    var utcOffsetSeconds: Int
    var days: [Day]
}

struct ServerTrafficPeriod: Equatable, Sendable {
    var start: Date
    var end: Date
}

enum ServerTrafficMapper {
    static let bytesPerGB = 1024.0 * 1024.0 * 1024.0
    /// The probe re-exports every five minutes; anything this old means the timer or vnStat stopped.
    static let staleAfter: TimeInterval = 30 * 60

    static func parse(_ body: Data) throws -> ServerTrafficPayload {
        guard let payload = try? JSONDecoder().decode(ServerTrafficPayload.self, from: body),
              payload.schema == ServerTrafficPayload.schema,
              TimeZone(secondsFromGMT: payload.utcOffsetSeconds) != nil else {
            throw ServerTrafficError.invalidResponse
        }
        return payload
    }

    /// The billing period containing `now`: from the latest reset day at 00:00 server time to the next
    /// one. A reset day past the end of a short month falls on that month's last day.
    static func period(containing now: Date, resetDay: Int, utcOffsetSeconds: Int) -> ServerTrafficPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        let today = calendar.dateComponents([.year, .month, .day], from: now)

        func resetDate(year: Int, month: Int) -> Date {
            let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            let length = calendar.range(of: .day, in: .month, for: firstOfMonth)!.count
            return calendar.date(from: DateComponents(year: year, month: month, day: min(resetDay, length)))!
        }
        func shifted(_ months: Int) -> (year: Int, month: Int) {
            let date = calendar.date(byAdding: .month, value: months,
                                     to: calendar.date(from: DateComponents(year: today.year, month: today.month, day: 1))!)!
            let parts = calendar.dateComponents([.year, .month], from: date)
            return (parts.year!, parts.month!)
        }

        let thisMonth = resetDate(year: today.year!, month: today.month!)
        if now >= thisMonth {
            let next = shifted(1)
            return ServerTrafficPeriod(start: thisMonth, end: resetDate(year: next.year, month: next.month))
        }
        let previous = shifted(-1)
        return ServerTrafficPeriod(start: resetDate(year: previous.year, month: previous.month), end: thisMonth)
    }

    /// Bytes the plan counts inside `period`, per its billing direction.
    static func usedBytes(_ payload: ServerTrafficPayload, in period: ServerTrafficPeriod,
                          mode: ServerTrafficCountMode) -> Double {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: payload.utcOffsetSeconds)
        formatter.dateFormat = "yyyy-MM-dd"
        var rx = 0.0, tx = 0.0
        for day in payload.days {
            guard let date = formatter.date(from: day.date), date >= period.start, date < period.end else { continue }
            rx += max(0, day.rx)
            tx += max(0, day.tx)
        }
        switch mode {
        case .outbound: return tx
        case .inbound: return rx
        case .total: return rx + tx
        case .larger: return max(rx, tx)
        }
    }

    static func lines(
        _ payload: ServerTrafficPayload,
        config: ServerTrafficConfig,
        now: Date
    ) -> (lines: [MetricLine], warning: String?) {
        let period = period(containing: now, resetDay: config.resetDay, utcOffsetSeconds: payload.utcOffsetSeconds)
        var usedGB = usedBytes(payload, in: period, mode: config.countMode) / bytesPerGB
        if let carryOver = config.carryOverGB, let setAt = config.carryOverSetAt,
           setAt >= period.start, setAt < period.end {
            usedGB += carryOver
        }
        let periodMs = Int(period.end.timeIntervalSince(period.start) * 1000)
        let percent = ProviderParse.clampPercent(usedGB / config.quotaGB * 100)
        let lines: [MetricLine] = [
            .progress(label: "Traffic", used: percent, limit: 100, format: .percent,
                      resetsAt: period.end, periodDurationMs: periodMs),
            .progress(label: "Data Used", used: (usedGB * 10).rounded() / 10, limit: config.quotaGB,
                      format: .count(suffix: "GB"), resetsAt: period.end, periodDurationMs: periodMs)
        ]

        var warning: String?
        if let updated = MyUsageISO8601.date(from: payload.updatedAt),
           now.timeIntervalSince(updated) > staleAfter {
            let minutes = Int(now.timeIntervalSince(updated) / 60)
            warning = "Probe data is \(minutes) min old. Check the openusage-probe timer on the server."
        }
        return (lines, warning)
    }
}
