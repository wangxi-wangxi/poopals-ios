import SwiftUI
import UserNotifications

@MainActor
final class CheckInStore: ObservableObject {
    @Published private(set) var book = RecordBook()
    @Published var errorMessage: String?
    @Published private(set) var writable = true
    private(set) var repository: RecordRepository
    private(set) var ownerID: String?
    private var guestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Poopals/records.json")
    }
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        repository = RecordRepository(url: directory.appendingPathComponent("Poopals/records.json"))
        do { book = try repository.load() }
        catch { writable = false; errorMessage = RecordError.invalidFile.localizedDescription }
    }
    @discardableResult
    func save(day: Date, kind: PooKind, size: PooSize) -> Bool {
        guard writable else { errorMessage = RecordError.invalidFile.localizedDescription; return false }
        do {
            var next = book
            try next.save(day: day, kind: kind, size: size)
            next.pendingChanges = ownerID != nil
            try repository.write(next)
            book = next
            return true
        } catch { errorMessage = "保存失败：\(error.localizedDescription)"; return false }
    }
    func delete(day: String) {
        guard writable else { return }
        do {
            var next = book
            next.delete(day: day)
            next.pendingChanges = ownerID != nil
            try repository.write(next)
            book = next
        } catch { errorMessage = "删除失败：\(error.localizedDescription)" }
    }
    func activate(userID: String) throws {
        guard UUID(uuidString: userID) != nil else { throw RecordError.invalidFile }
        let next = RecordRepository(url: guestURL.deletingLastPathComponent().appendingPathComponent("account-\(userID).json"))
        let loaded = try next.load()
        repository = next; ownerID = userID; book = loaded; writable = true
    }
    func acceptCloud(_ snapshot: CloudSnapshot, dirty: Bool = false) throws {
        var next = RecordBook()
        next.records = snapshot.records.sorted { $0.day > $1.day }
        next.cloudRevision = snapshot.revision; next.pendingChanges = dirty
        try repository.write(next); book = next
    }
    func updateRevision(_ revision: Int) throws {
        var next = book; next.cloudRevision = revision; next.pendingChanges = true
        try repository.write(next); book = next
    }
    func guestRecords() throws -> [CheckIn] { try RecordRepository(url: guestURL).load().records }
    func backupBeforeMerge() throws {
        let url = repository.url.deletingPathExtension().appendingPathExtension("recovery.json")
        try RecordRepository(url: url).write(book)
    }
    func leaveAccount(delete: Bool) throws {
        let guest = RecordRepository(url: guestURL)
        let loaded = try? guest.load()
        if delete {
            for path in [repository.url, repository.url.deletingPathExtension().appendingPathExtension("recovery.json")] {
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
        }
        repository = guest; ownerID = nil; book = loaded ?? RecordBook(); writable = loaded != nil
        if loaded == nil { errorMessage = RecordError.invalidFile.localizedDescription }
    }

}

@MainActor
final class ReminderService: ObservableObject {
    @Published var enabled = false
    @Published var time: Date = Calendar.current.date(from: DateComponents(hour: 20, minute: 0)) ?? Date()
    @Published var message: String?
    @Published var busy = false
    private let center = UNUserNotificationCenter.current()
    private let identifier = "poopals.daily"
    init() { Task { await refresh() } }
    func refresh() async {
        let requests = await center.pendingNotificationRequests()
        let settings = await center.notificationSettings()
        let request = requests.first { $0.identifier == identifier }
        enabled = request != nil && settings.authorizationStatus != .denied
        if let trigger = request?.trigger as? UNCalendarNotificationTrigger,
           let date = Calendar.current.date(from: trigger.dateComponents) { time = date }
    }
    func apply(enabled desired: Bool, time selected: Date) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if !desired {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            enabled = false
            return
        }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                message = "通知权限未开启，可在 iPhone 设置中允许噗噗搭子发送通知。"
                enabled = false
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "留下一只今天的噗噗"
            content.body = "每天一个小记录，看看你的噗噗日历吧。"
            content.sound = .default
            let components = Calendar.current.dateComponents([.hour, .minute], from: selected)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            enabled = true
            time = selected
        } catch { message = "提醒设置失败：\(error.localizedDescription)" }
    }
}
