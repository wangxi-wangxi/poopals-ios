import Foundation

@main
struct CoreTests {
    static func main() throws {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ key: String) -> Date { DayKey.date(key, calendar: c)! }
        let now = date("2026-10-03")
        var book = RecordBook()
        for key in ["2026-09-30", "2026-10-01", "2026-10-02"] {
            try book.save(day: date(key), kind: .yellow, size: .m, now: now, calendar: c)
        }
        assert(book.streak(now: now, calendar: c) == 3, "Yesterday-based streak across month")
        try book.save(day: now, kind: .pink, size: .s, now: now, calendar: c)
        assert(book.streak(now: now, calendar: c) == 4)
        let initial = book.record(on: now, calendar: c)!
        try book.save(day: now, kind: .purple, size: .xl, now: now.addingTimeInterval(90), calendar: c)
        assert(book.records.count == 4 && book.record(on: now, calendar: c)!.id == initial.id)
        assert(book.record(on: now, calendar: c)!.createdAt == initial.createdAt)
        assert(book.record(on: now, calendar: c)!.size == .xl)
        do {
            try book.save(day: date("2026-10-04"), kind: .green, size: .m, now: now, calendar: c)
            fatalError("Future date must be rejected")
        } catch RecordError.futureDate { }
        book.delete(day: "2026-10-02")
        assert(book.streak(now: now, calendar: c) == 1)
        let september = DayKey.monthDays(date("2026-09-26"), calendar: c)
        assert(september.count == 31 && september[0] == nil)
        assert(c.component(.weekday, from: september[1]!) == 3)
        assert(DayKey.monthDays(date("2028-02-10"), calendar: c).compactMap { $0 }.count == 29)
        assert(DayKey.monthDays(date("2026-02-10"), calendar: c).compactMap { $0 }.count == 28)
        assert(c.component(.weekday, from: DayKey.week(now, calendar: c)[0]) == 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = RecordRepository(url: root.appendingPathComponent("records.json"))
        assert(tryLoad(repo).records.isEmpty)
        try repo.write(book)
        let loaded = try repo.load()
        assert(loaded.records == book.records)
        try Data("broken".utf8).write(to: repo.url)
        do { _ = try repo.load(); fatalError("Corrupt data must not be silently reset") } catch { }
        let preserved = try String(contentsOf: repo.url, encoding: .utf8)
        assert(preserved == "broken")
        print("PASS: 16 checks — persistence, replacement, deletion, future dates, streaks, month/year/leap layout, corruption preservation")
    }
    static func tryLoad(_ repo: RecordRepository) -> RecordBook { try! repo.load() }
}
