import Foundation

enum PooSize: String, Codable, CaseIterable, Identifiable {
    case s = "S", m = "M", l = "L", xl = "XL"
    var id: String { rawValue }
}

enum PooKind: String, Codable, CaseIterable, Identifiable {
    case yellow, pink, green, purple, cream, brown
    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var title: String {
        switch self {
        case .yellow: return "芒果黄"
        case .pink: return "樱花粉"
        case .green: return "抹茶绿"
        case .purple: return "葡萄紫"
        case .cream: return "奶油白"
        case .brown: return "经典棕"
        }
    }
}

struct CheckIn: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var day: String
    var createdAt: Date
    var updatedAt: Date
    var kind: PooKind
    var size: PooSize
}

enum DayKey {
    // Store the civil date, so travelling does not move an existing sticker to another day.
    static func make(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }
    static func monthDays(_ date: Date, calendar: Calendar = .current) -> [Date?] {
        guard let start = calendar.dateInterval(of: .month, for: date)?.start,
              let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let padding = (calendar.component(.weekday, from: start) + 5) % 7
        return Array(repeating: nil, count: padding) + range.map {
            calendar.date(byAdding: .day, value: $0 - 1, to: start)
        }
    }
    static func week(_ date: Date, calendar: Calendar = .current) -> [Date] {
        let offset = (calendar.component(.weekday, from: date) + 5) % 7
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: date) }
    }
}

struct RecordBook: Codable {
    var version = 1
    var records: [CheckIn] = []
    mutating func save(day: Date, kind: PooKind, size: PooSize, now: Date = Date(), calendar: Calendar = .current) throws {
        let key = DayKey.make(day, calendar: calendar)
        guard key <= DayKey.make(now, calendar: calendar) else { throw RecordError.futureDate }
        if let i = records.firstIndex(where: { $0.day == key }) {
            records[i].kind = kind
            records[i].size = size
            records[i].updatedAt = now
        } else {
            records.append(CheckIn(day: key, createdAt: now, updatedAt: now, kind: kind, size: size))
        }
        records.sort { $0.day > $1.day }
    }
    mutating func delete(day: String) { records.removeAll { $0.day == day } }
    func record(on date: Date, calendar: Calendar = .current) -> CheckIn? {
        records.first { $0.day == DayKey.make(date, calendar: calendar) }
    }
    func streak(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(records.map(\.day))
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(DayKey.make(cursor, calendar: calendar)) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var result = 0
        while days.contains(DayKey.make(cursor, calendar: calendar)) {
            result += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return result
    }
}

enum RecordError: LocalizedError {
    case futureDate, invalidFile
    var errorDescription: String? {
        switch self {
        case .futureDate: return "还不能记录未来的日期。"
        case .invalidFile: return "记录文件无法读取。原文件已保留，请先导出备份再联系支持。"
        }
    }
}

struct RecordRepository {
    let url: URL
    func load() throws -> RecordBook {
        guard FileManager.default.fileExists(atPath: url.path) else { return RecordBook() }
        let book = try JSONDecoder().decode(RecordBook.self, from: Data(contentsOf: url))
        guard book.version == 1, Set(book.records.map(\.day)).count == book.records.count,
              book.records.allSatisfy({ DayKey.date($0.day) != nil }) else { throw RecordError.invalidFile }
        return book
    }
    func write(_ book: RecordBook) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(book).write(to: url, options: .atomic)
    }
}
