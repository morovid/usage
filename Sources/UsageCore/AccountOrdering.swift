import Foundation

public enum AccountOrdering {
    /// Destination is an insertion boundary in the original list (SwiftUI onMove semantics).
    public static func moving(_ accounts: [Account], from offsets: IndexSet, to destination: Int) -> [Account] {
        guard !offsets.isEmpty, destination >= 0, destination <= accounts.count,
              offsets.allSatisfy({ accounts.indices.contains($0) }) else { return accounts }
        let moved = offsets.map { accounts[$0] }
        var remaining = accounts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: insertion)
        return remaining
    }
}
