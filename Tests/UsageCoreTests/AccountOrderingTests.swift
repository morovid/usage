import Foundation
import Testing
@testable import UsageCore

private func accounts() -> [Account] {
    ["A", "B", "C", "D"].map { Account(provider: .anthropic, email: $0) }
}

@Test func accountMovesInBothDirectionsAndToEnd() {
    let list = accounts()
    #expect(AccountOrdering.moving(list, from: [0], to: 4).map(\.email) == ["B", "C", "D", "A"])
    #expect(AccountOrdering.moving(list, from: [3], to: 0).map(\.email) == ["D", "A", "B", "C"])
    #expect(AccountOrdering.moving(list, from: [1], to: 3).map(\.email) == ["A", "C", "B", "D"])
    #expect(AccountOrdering.moving(list, from: [1, 3], to: 0).map(\.email) == ["B", "D", "A", "C"])
}

@Test func invalidAndNoOpAccountMovesAreUnchanged() {
    let list = accounts()
    for (offsets, destination): (IndexSet, Int) in [([], 0), ([4], 0), ([0], -1), ([0], 5), ([1], 1), ([1], 2)] {
        #expect(AccountOrdering.moving(list, from: offsets, to: destination) == list)
    }
    #expect(AccountOrdering.moving([], from: [0], to: 0).isEmpty)
}

@Test func orderedAccountsKeepIdentityAndPersistInOrder() throws {
    let list = accounts()
    let reordered = AccountOrdering.moving(list, from: [2], to: 0)
    #expect(Set(reordered.map(\.id)) == Set(list.map(\.id)))
    let decoded = try JSONDecoder().decode([Account].self, from: JSONEncoder().encode(reordered))
    #expect(decoded == reordered)
    #expect(decoded.first?.id == list[2].id)
}
