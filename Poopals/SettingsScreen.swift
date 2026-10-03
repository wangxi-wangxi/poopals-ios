import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var reminders: ReminderService
    @EnvironmentObject var store: CheckInStore
    @EnvironmentObject var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var exportURL: URL?
    @State private var exportError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("账号与同步") {
                    NavigationLink { AccountScreen() } label: {
                        Label(account.session == nil ? "开启云备份" : "账号与同步", systemImage: "person.crop.circle")
                    }
                    Text(account.status).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("每日提醒", isOn: Binding(get: { reminders.enabled }, set: { value in
                        Task { await reminders.apply(enabled: value, time: reminders.time) }
                    }))
                    DatePicker("提醒时间", selection: Binding(get: { reminders.time }, set: { value in
                        if reminders.enabled { Task { await reminders.apply(enabled: true, time: value) } }
                        else { reminders.time = value }
                    }), displayedComponents: .hourAndMinute)
                } footer: {
                    Text("每天在这个时间提醒你打开日历。即使当天已经记录，也会收到提醒。")
                }.disabled(reminders.busy)
                Section("数据与隐私") {
                    Text("游客记录仅保存在本机；主动登录并确认导入后，可同步到配置的云服务。系统设备备份可能包含本地记录。删除 App 不等于注销云端账号。")
                        .font(.subheadline)
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("分享记录备份", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("准备导出 JSON 备份") { export() }
                    }
                    Text("这是一款生活记录工具，噗噗颜色与表情是装饰，不代表健康诊断。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("打开系统通知设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("噗噗搭子 · 0.2.0 开发版").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("提醒与设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await reminders.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reminders.refresh() } } }
            .alert("提醒提示", isPresented: Binding(get: { reminders.message != nil }, set: { if !$0 { reminders.message = nil } })) {
                Button("知道了", role: .cancel) { reminders.message = nil }
            } message: { Text(reminders.message ?? "") }
            .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("知道了", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
        }
    }
    private func export() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("噗噗记录-备份.json")
            if !store.writable {
                try Data(contentsOf: store.repository.url).write(to: url, options: .atomic)
            } else {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(store.book).write(to: url, options: .atomic)
            }
            exportURL = url
        } catch { exportError = error.localizedDescription }
    }
}
