import SwiftUI

@main
struct PoopalsApp: App {
    @StateObject private var store = CheckInStore()
    @StateObject private var account = AccountService()
    @StateObject private var reminders = ReminderService()
    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(reminders)
                .environmentObject(account)
                .task { await account.bootstrap(store: store) }
                .onOpenURL { WeChatLogin.shared.handle($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { WeChatLogin.shared.handle($0) }
                .preferredColorScheme(.light)
                .alert("记录提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                    Button("知道了", role: .cancel) { store.errorMessage = nil }
                } message: { Text(store.errorMessage ?? "") }
        }
    }
}
