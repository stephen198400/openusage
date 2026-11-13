import Foundation
import Testing
@testable import MyUsage

struct MyUsageISO8601Tests {
    @Test func parsesZuluISO() {
        let date = MyUsageISO8601.date(from: "2099-01-01T00:00:00.000Z")
        #expect(date != nil)
    }

    @Test func normalizesMicrosecondsWithoutTimezoneLikeClaudeAPI() {
        let date = MyUsageISO8601.date(from: "2099-01-01T00:00:00.123456")
        #expect(date != nil)
        #expect(MyUsageISO8601.string(from: date!) == "2099-01-01T00:00:00.123Z")
    }

    @Test func normalizesSpaceSeparatedUTC() {
        let date = MyUsageISO8601.date(from: "2099-01-01 00:00:00 UTC")
        #expect(date != nil)
    }
}
