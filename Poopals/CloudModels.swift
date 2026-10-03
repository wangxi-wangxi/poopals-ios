import Foundation

struct CloudSnapshot: Codable {
    var revision: Int
    var records: [CheckIn]
}

enum RecordMerge {
    // Only used for explicit guest import. Normal cloud conflicts preserve deletions
    // by letting the user choose an entire snapshot, never blindly unioning it.
    static func importGuest(_ guest: [CheckIn], into cloud: [CheckIn], preferGuest: Bool) -> [CheckIn] {
        var result = Dictionary(uniqueKeysWithValues: cloud.map { ($0.day, $0) })
        for record in guest where preferGuest || result[record.day] == nil { result[record.day] = record }
        return result.values.sorted { $0.day > $1.day }
    }
    static func conflicts(_ guest: [CheckIn], _ cloud: [CheckIn]) -> Int {
        let remote = Dictionary(uniqueKeysWithValues: cloud.map { ($0.day, $0) })
        return guest.filter { item in
            guard let other = remote[item.day] else { return false }
            return item.kind != other.kind || item.size != other.size
        }.count
    }
}
