import SwiftUI
import UserNotifications

@MainActor
final class CheckInStore: ObservableObject {
    @Published private(set) var book = RecordBook()
    @Published var errorMessage: String?
    @Published private(set) var writable = true
    let repository: RecordRepository
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
            try repository.write(next)
            book = next
        } catch { errorMessage = "删除失败：\(error.localizedDescription)" }
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
