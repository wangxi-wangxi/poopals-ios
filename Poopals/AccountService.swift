import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

struct CloudSession: Codable {
    let user_id: String
    let token: String
    let expires_at: Double
    let provider: String
}
struct LoginChallenge: Codable { let id: String; let nonce: String }
struct ProviderConfig: Codable { let apple: Bool; let wechat: Bool }
struct LoginBody: Encodable {
    let challenge_id: String
    let code: String
    let identity_token: String?
    let state: String?
}
struct AccountDetails: Decodable { let user_id: String; let providers: [String] }
struct EmptyBody: Encodable {}
enum CloudError: LocalizedError {
    case message(String)
    case conflict
    var errorDescription: String? {
        switch self { case .message(let value): return value; case .conflict: return "云端有新的版本，请选择要保留的记录。" }
    }
}

// Credentials never enter UserDefaults, exported backups or repository files.
private enum SessionKeychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Poopals.CloudSession", kSecAttrAccount as String: "current"]
    static func read() -> CloudSession? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(CloudSession.self, from: data)
    }
    static func save(_ session: CloudSession) throws {
        let data = try JSONEncoder().encode(session)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CloudError.message("无法安全保存登录凭证") }
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CloudError.message("无法安全保存登录凭证") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

@MainActor
final class AccountService: ObservableObject {
    @Published private(set) var session: CloudSession? = SessionKeychain.read()
    @Published var config: ProviderConfig?
    @Published var challenge: LoginChallenge?
    @Published var busy = false
    @Published var message: String?
    @Published var conflict: CloudSnapshot?
    @Published var guestImport: [CheckIn] = []
    @Published var importTarget: CloudSnapshot?
    @Published var providers: [String] = []
    @Published var status = "仅保存在本机"
    private var generation = UUID()
    private var bootstrapped = false
    var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PoopalsAPIURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    var ready: Bool { baseURL != nil }
    var nonceHash: String? { challenge.map { SHA256.hash(data: Data($0.nonce.utf8)).map { String(format: "%02x", $0) }.joined() } }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> T {
        guard let baseURL else { throw CloudError.message("云服务尚未接通，本机记录仍可正常使用。") }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method; req.timeoutInterval = 20; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let session else { throw CloudError.message("请先登录") }
            req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("网络响应异常") }
        if http.statusCode == 409 { throw CloudError.conflict }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw CloudError.message(detail ?? "服务暂不可用（\(http.statusCode)）")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func prepareLogin() async {
        guard ready else { return }
        do {
            config = try await request("v1/config", authenticated: false)
            challenge = try await request("v1/auth/challenge", method: "POST", authenticated: false)
        } catch { message = error.localizedDescription }
    }
    func bootstrap(store: CheckInStore) async {
        guard !bootstrapped else { return }; bootstrapped = true
        if let session {
            do { try store.activate(userID: session.user_id) }
            catch { message = error.localizedDescription; return }
            status = "已登录 · 等待同步"
            await sync(store: store)
            if let details: AccountDetails = try? await request("v1/account") { providers = details.providers }
        }
    }
    func appleResult(_ result: Result<ASAuthorization, Error>, store: CheckInStore, linking: Bool = false) async {
        guard !busy else { return }
        guard let challenge else { message = "请刷新登录方式后重试"; return }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                  let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else { throw CloudError.message("Apple 未返回完整凭证") }
            let body = LoginBody(challenge_id: challenge.id, code: code, identity_token: token, state: nil)
            if linking { await linkProvider("apple", body: body) }
            else { await login(provider: "apple", body: body, store: store) }
        } catch {
            if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
            await prepareLogin()
        }
    }
    func linkProvider(_ provider: String, body: LoginBody) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let _: [String: Bool] = try await request("v1/account/link/\(provider)", method: "POST", body: JSONEncoder().encode(body))
            let details: AccountDetails = try await request("v1/account")
            providers = details.providers; message = "登录方式已绑定到当前账号"
        } catch { message = error.localizedDescription }
        challenge = nil
    }
    func login(provider: String, body: LoginBody, store: CheckInStore) async {
        busy = true; defer { busy = false }
        do {
            let previousGuest = store.ownerID == nil ? store.book.records : []
            let result: CloudSession = try await request("v1/auth/login/\(provider)", method: "POST", body: JSONEncoder().encode(body), authenticated: false)
            // Activate the account-specific cache before exposing the session.
            let previousSession = session
            try SessionKeychain.save(result)
            do { try store.activate(userID: result.user_id) }
            catch {
                if let previousSession { try? SessionKeychain.save(previousSession) }
                else { SessionKeychain.clear() }
                throw error
            }
            session = result; generation = UUID(); providers = [provider]
            if let details: AccountDetails = try? await request("v1/account") { providers = details.providers }
            status = "已登录 · 等待同步"
            guestImport = previousGuest
            let remote: CloudSnapshot = try await request("v1/checkins")
            if store.book.pendingChanges == true {
                guestImport = []
                // An existing account cache is never discarded during reauthentication.
                conflict = remote
            } else if !previousGuest.isEmpty {
                guestImport = previousGuest; importTarget = remote
                status = "请选择是否导入本机记录"
            } else {
                try store.acceptCloud(remote); status = "已同步"
            }
        } catch { message = error.localizedDescription }
        challenge = nil
    }
    func offerGuestImport(store: CheckInStore) async {
        guard !busy, session != nil, store.book.pendingChanges != true else {
            message = "请先同步当前账号的修改，再导入游客记录"; return
        }
        do { guestImport = try store.guestRecords(); await sync(store: store) }
        catch { message = error.localizedDescription }
    }
    func finishImport(store: CheckInStore, preferGuest: Bool?, importing: Bool) async {
        guard let remote = importTarget else { return }
        do {
            if importing {
                let merged = RecordMerge.importGuest(guestImport, into: remote.records, preferGuest: preferGuest ?? false)
                try store.acceptCloud(CloudSnapshot(revision: remote.revision, records: merged), dirty: true)
            } else { try store.acceptCloud(remote) }
            guestImport = []; importTarget = nil
            await sync(store: store)
        } catch { message = error.localizedDescription }
    }
    func sync(store: CheckInStore) async {
        guard session != nil, !busy, importTarget == nil, conflict == nil, store.writable else { return }
        busy = true; defer { busy = false }
        let operation = generation
        do {
            if !guestImport.isEmpty {
                importTarget = try await request("v1/checkins")
                status = "请选择是否导入本机记录"
                return
            }
            if store.book.pendingChanges == true {
                guard let revision = store.book.cloudRevision else {
                    conflict = try await request("v1/checkins"); return
                }
                let sent = store.book.records
                let remote: CloudSnapshot = try await request("v1/checkins", method: "PUT", body: JSONEncoder().encode(CloudSnapshot(revision: revision, records: sent)))
                guard operation == generation else { return }
                if sent == store.book.records { try store.acceptCloud(remote) }
                else { try store.updateRevision(remote.revision) }
            } else {
                let before = store.book.records
                let remote: CloudSnapshot = try await request("v1/checkins")
                guard operation == generation else { return }
                // User can record while the request is in flight. Never overwrite new local input.
                if before == store.book.records && store.book.pendingChanges != true { try store.acceptCloud(remote) }
                else { conflict = remote }
            }
            status = store.book.pendingChanges == true ? "本机已保存 · 还有记录待同步" : "已同步"
        } catch CloudError.conflict {
            do { conflict = try await request("v1/checkins") }
            catch { message = error.localizedDescription }
            status = "同步冲突 · 本机记录已保留"
        } catch { status = "本机已保存 · 同步未完成"; message = error.localizedDescription }
    }
    func resolve(store: CheckInStore, useCloud: Bool) async {
        guard let remote = conflict else { return }
        do {
            // Keep a local recovery copy before the explicit whole-snapshot choice.
            try store.backupBeforeMerge()
            if useCloud { try store.acceptCloud(remote) }
            else { try store.updateRevision(remote.revision) }
            conflict = nil
            await sync(store: store)
        } catch { message = error.localizedDescription }
    }
    func logout(store: CheckInStore, delete: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let _: [String: Bool] = try await request(delete ? "v1/account" : "v1/auth/logout", method: delete ? "DELETE" : "POST")
            try store.leaveAccount(delete: delete)
            generation = UUID(); session = nil; SessionKeychain.clear()
            conflict = nil; importTarget = nil; guestImport = []; providers = []; status = "仅保存在本机"
        } catch { message = error.localizedDescription }
    }
}
