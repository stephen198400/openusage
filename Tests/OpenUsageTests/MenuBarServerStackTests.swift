import XCTest
@testable import OpenUsage

/// Servers stack two per menu-bar slot (one line each); model providers keep their own slot.
final class MenuBarServerStackTests: XCTestCase {
    private func group(_ id: String, _ name: String = "x") -> MenuBarContent.Group {
        MenuBarContent.Group(
            providerID: id, displayName: name, icon: .providerMark("server"),
            metrics: [MenuBarContent.Metric(id: "\(id).traffic", label: "Traffic", value: "10%",
                                            fraction: 0.1, isBounded: true, hasData: true)]
        )
    }

    private func shape(_ content: MenuBarContent) -> [String] {
        content.segments.map {
            switch $0 {
            case .provider(let g): g.providerID
            case .serverStack(let gs): gs.map(\.providerID).joined(separator: "+")
            }
        }
    }

    func testLoneServerKeepsItsOwnSlot() {
        let content = MenuBarContent(groups: [group("claude"), group("server@aa")], bars: [])
        XCTAssertEqual(shape(content), ["claude", "server@aa"])
    }

    func testServersStackInPairsWhereTheFirstServerSits() {
        let content = MenuBarContent(
            groups: [group("claude"), group("server@aa"), group("codex"), group("server@bb"), group("server@cc")],
            bars: []
        )
        XCTAssertEqual(shape(content), ["claude", "server@aa+server@bb", "server@cc", "codex"])
    }
}
