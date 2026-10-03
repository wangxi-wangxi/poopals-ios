import SwiftUI
import AuthenticationServices

struct AccountScreen: View {
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var store: CheckInStore
    @State private var consent = false
    @State private var deleting = false
    @State private var signingOut = false
    var body: some View {
        Form {
            if account.session == nil {
                Section {
                    HStack { Spacer(); Image("AccountSticker").resizable().scaledToFit().frame(width: 140, height: 120); Spacer() }
                    Text("让日历跟着你").font(.title2.bold())
                    Text("先记录，随时再登录。开启云备份后，可以在新设备找回日历。")
                    Text("游客记录不会自动上传。登录后由你决定是否导入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                loginSection
            } else {
                Section("我的账号") {
                    Label("已登录", systemImage: "person.crop.circle.badge.checkmark")
                    Text("账号 · \(account.session!.user_id.prefix(8))").font(.caption).foregroundStyle(.secondary)
                    Text(account.status)
                    Text(store.book.pendingChanges == true ? "本机有待同步的更改" : "记录已保存在当前设备")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("立即同步") { Task { await account.sync(store: store) } }
                }
                if let target = account.importTarget {
                    Section("导入本机记录") {
                        Text("本机 \(account.guestImport.count) 条 · 云端 \(target.records.count) 条")
                        Text("同一天有 \(RecordMerge.conflicts(account.guestImport, target.records)) 条不同记录。请选择重复日期保留哪一份；其他日期都会保留。")
                            .font(.subheadline)
                        Button("合并，重复日期保留本机") { Task { await account.finishImport(store: store, preferGuest: true, importing: true) } }
                        Button("合并，重复日期保留云端") { Task { await account.finishImport(store: store, preferGuest: false, importing: true) } }
                        Button("暂不导入，只使用云端") { Task { await account.finishImport(store: store, preferGuest: nil, importing: false) } }
                    }
                }
                if let remote = account.conflict {
                    Section("选择同步版本") {
                        Text("本机 \(store.book.records.count) 条 · 云端 \(remote.records.count) 条")
                        Text("另一台设备修改了记录。以下选择会替换整份日历，包括删除的日期。选择前会保留本机恢复副本。")
                            .font(.caption)
                        Button("保留本机版本并上传") { Task { await account.resolve(store: store, useCloud: false) } }
                        Button("使用云端版本") { Task { await account.resolve(store: store, useCloud: true) } }
                    }
                }
                Section("登录渠道") {
                    Label(account.session?.provider == "apple" ? "Apple · 已连接" : "微信 · 已连接", systemImage: "checkmark.seal")
                    Text("其他登录方式将逐步开放。不同账号的记录不会自动合并。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("重新验证身份") { loginSection }
                }
                Section("账号管理") {
                    Button("退出登录") { signingOut = true }
                    Button("注销账号", role: .destructive) { deleting = true }
                    Text("退出后回到游客日历；账号缓存不会显示给游客。注销会删除云端记录和当前账号缓存，无法恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("两个人一起记录") {
                Text("先把自己的日历记录好，再邀请一位搭子。")
                Text("双人邀请、共同日历和好友通知正在设计阶段，当前构建尚未开放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(account.busy)
        .overlay { if account.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .navigationTitle("账号与同步").navigationBarTitleDisplayMode(.inline)
        .task { await account.prepareLogin() }
        .alert("账号提示", isPresented: Binding(get: { account.message != nil }, set: { if !$0 { account.message = nil } })) {
            Button("知道了", role: .cancel) { account.message = nil }
        } message: { Text(account.message ?? "") }
        .confirmationDialog("退出当前账号？", isPresented: $signingOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await account.logout(store: store) } }
        } message: { Text(store.book.pendingChanges == true ? "有记录尚未同步。退出后保留账号缓存，再次登录才能访问。" : "云端记录保留，回到本机游客日历。") }
        .confirmationDialog("永久注销并删除云端记录？", isPresented: $deleting, titleVisibility: .visible) {
            Button("永久删除账号", role: .destructive) { Task { await account.logout(store: store, delete: true) } }
        } message: { Text("操作不可恢复。请先导出需要保留的数据。若登录超过十分钟，请先重新验证身份。") }
    }
    @ViewBuilder private var loginSection: some View {
        Section("登录即注册") {
            if !account.ready {
                Label("云服务尚未接通", systemImage: "icloud.slash")
                Text("当前可继续使用本机打卡。云备份开放后即可登录同步。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("同意将导入的记录保存到云端", isOn: $consent)
                if account.config?.apple == true {
                    SignInWithAppleButton(.continue) { request in
                        request.nonce = account.nonceHash
                    } onCompletion: { result in
                        Task { await account.appleResult(result, store: store) }
                    }
                    .signInWithAppleButtonStyle(.black).frame(height: 48)
                    .disabled(!consent || account.challenge == nil)
                }
                if account.config?.wechat == true && WeChatLogin.shared.available {
                    Button("通过微信继续") {
                        guard let challenge = account.challenge else { return }
                        WeChatLogin.shared.login(state: challenge.nonce) { result in
                            Task { @MainActor in
                                switch result {
                                case .success(let value):
                                    await account.login(provider: "wechat", body: LoginBody(challenge_id: challenge.id, code: value.0, identity_token: nil, state: value.1), store: store)
                                case .failure(let error): account.message = error.localizedDescription
                                }
                            }
                        }
                    }.disabled(!consent || account.challenge == nil)
                }
                Button("刷新登录方式") { Task { await account.prepareLogin() } }
                Text("微信登录即将开放，当前可使用已开放的登录方式。")
                    .font(.caption).foregroundStyle(.secondary)
                if account.config?.apple == false { Text("Apple 登录暂不可用").font(.caption) }
            }
        }
    }
}
