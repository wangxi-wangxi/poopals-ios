import Foundation
import UIKit
#if canImport(WechatOpenSDK)
import WechatOpenSDK
#endif

// The official SDK must be added by the signed build configuration. This adapter
// is deliberately unavailable until SDK, AppID and Universal Link all exist.
@MainActor
final class WeChatLogin: NSObject {
    static let shared = WeChatLogin()
    private var completion: ((Result<(String, String), Error>) -> Void)?
    private var expectedState: String?
    private var timeoutTask: Task<Void, Never>?
    var available: Bool {
        #if canImport(WechatOpenSDK)
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "WeChatAppID") as? String, appID.hasPrefix("wx"),
              let link = Bundle.main.object(forInfoDictionaryKey: "WeChatUniversalLink") as? String, link.hasPrefix("https://") else { return false }
        return WXApi.registerApp(appID, universalLink: link) && WXApi.isWXAppInstalled()
        #else
        return false
        #endif
    }
    func login(state: String, completion: @escaping (Result<(String, String), Error>) -> Void) {
        guard available else { completion(.failure(CloudError.message("微信登录暂不可用"))); return }
        self.completion = completion; expectedState = state
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.finish(.failure(CloudError.message("微信授权已超时，请重试")))
        }
        #if canImport(WechatOpenSDK)
        let req = SendAuthReq(); req.scope = "snsapi_userinfo"; req.state = state
        WXApi.send(req) { [weak self] sent in
            Task { @MainActor in if !sent { self?.finish(.failure(CloudError.message("无法打开微信"))) } }
        }
        #endif
    }
    func handle(_ url: URL) {
        #if canImport(WechatOpenSDK)
        WXApi.handleOpen(url, delegate: self)
        #endif
    }
    func handle(_ activity: NSUserActivity) {
        #if canImport(WechatOpenSDK)
        WXApi.handleOpenUniversalLink(activity, delegate: self)
        #endif
    }
    private func finish(_ result: Result<(String, String), Error>) {
        timeoutTask?.cancel(); let callback = completion; completion = nil; expectedState = nil; callback?(result)
    }
}
#if canImport(WechatOpenSDK)
extension WeChatLogin: WXApiDelegate {
    nonisolated func onResp(_ resp: BaseResp) {
        guard let response = resp as? SendAuthResp else { return }
        let code = response.code; let state = response.state; let error = response.errCode
        Task { @MainActor in
            guard error == 0, let code, let state, state == self.expectedState else {
                self.finish(.failure(CloudError.message("微信授权未完成，请重试"))); return
            }
            self.finish(.success((code, state)))
        }
    }
}
#endif
