import Foundation
@main struct CloudModelTests {
    static func main() throws {
        let now = Date()
        let a = CheckIn(day: "2026-01-01", createdAt: now, updatedAt: now, kind: .yellow, size: .m)
        let b = CheckIn(day: "2026-01-01", createdAt: now, updatedAt: now, kind: .pink, size: .s)
        let c = CheckIn(day: "2026-01-02", createdAt: now, updatedAt: now, kind: .green, size: .l)
        assert(RecordMerge.conflicts([a,c], [b]) == 1)
        assert(RecordMerge.importGuest([a,c], into: [b], preferGuest: true).last?.kind == .yellow)
        assert(RecordMerge.importGuest([a,c], into: [b], preferGuest: false).last?.kind == .pink)
        assert(RecordMerge.importGuest([a,c], into: [b], preferGuest: false).count == 2)
        let old = Data("{\"version\":1,\"records\":[]}".utf8)
        let book = try JSONDecoder().decode(RecordBook.self, from: old)
        assert(book.cloudRevision == nil && book.pendingChanges == nil)
        print("PASS: guest merge choices, duplicate dates and legacy record migration")
    }
}
