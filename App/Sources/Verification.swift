import AuthenticationServices
import UIKit

/// Runs an extension's signed-session / OAuth challenge and returns to the app via mornye://.
final class Verification {
    static let shared = Verification()
    private var session: ASWebAuthenticationSession?
    private var waiting: [String: [(Bool) -> Void]] = [:]

    func verify(_ extensionId: String, done: @escaping (Bool) -> Void) {
        if waiting[extensionId] != nil { waiting[extensionId]?.append(done); return }
        waiting[extensionId] = [done]
        Lite.shared.call("getExtensionPendingAuth", ["extension_id": extensionId]) { value, _ in
            guard let url = URL(string: jsonMap(value).str("auth_url").trimmingCharacters(in: .whitespaces)),
                  url.scheme != nil else { return self.finish(extensionId, false) }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "mornye") { callback, _ in
                guard let callback = callback else { return self.finish(extensionId, false) }
                self.handle(callback) { ok in self.finish(extensionId, ok) }
            }
            self.session = session
            if !session.start() { self.finish(extensionId, false) }
        }
    }

    /// Completes mornye://callback?code=&state= or mornye://session-grant?grant=&state=.
    @discardableResult
    func handle(_ url: URL, done: ((Bool) -> Void)? = nil) -> Bool {
        guard url.scheme?.lowercased() == "mornye",
              let host = url.host?.lowercased(), host == "callback" || host == "session-grant" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let grant = host == "session-grant"
        let code = grant ? value("grant") : value("code")
        let state = value("state")
        Lite.shared.queue.async {
            var ok = false
            if !code.isEmpty && !state.isEmpty {
                ok = (try? Lite.shared.backend.completeAuthCallback(state: state, code: code, sessionGrant: grant) { _ in }) != nil
            }
            DispatchQueue.main.async { done?(ok) }
        }
        return true
    }

    private func finish(_ extensionId: String, _ ok: Bool) {
        DispatchQueue.main.async {
            self.session = nil
            let callbacks = self.waiting.removeValue(forKey: extensionId) ?? []
            callbacks.forEach { $0(ok) }
        }
    }
}
