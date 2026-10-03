import Foundation
@main struct AccountStoreTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CheckInStore(directory: directory)
        assert(store.save(day: Date(), kind: .yellow, size: .m))
        let guest = store.book.records
        let userA = UUID().uuidString, userB = UUID().uuidString
        try store.activate(userID: userA)
        assert(store.book.records.isEmpty)
        assert(store.save(day: Date(), kind: .pink, size: .s))
        assert(store.book.pendingChanges == true)
        try store.activate(userID: userB)
        assert(store.book.records.isEmpty)
        try store.activate(userID: userA)
        assert(store.book.records.first?.kind == .pink)
        try store.leaveAccount(delete: false)
        assert(store.ownerID == nil && store.book.records == guest)
        do { try store.acceptCloud(CloudSnapshot(revision: 0, records: [])); assertionFailure("Guest overwritten") }
        catch { assert(store.book.records == guest) }
        try store.activate(userID: userA)
        try store.leaveAccount(delete: true)
        try store.activate(userID: userA)
        assert(store.book.records.isEmpty)
        try store.leaveAccount(delete: false)
        assert(store.book.records == guest)
        print("PASS: account cache isolation, logout, cloud ownership guard and deletion")
    }
}
