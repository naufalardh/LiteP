import Foundation
import Security

/// App-level facade over the Mornye Rust backend.
final class Lite {
    static let shared = Lite()
    static let extensionsChanged = Notification.Name("LiteExtensionsChanged")
    static let libraryChanged = Notification.Name("LiteLibraryChanged")

    let backend = RustCoreBackend.shared
    let queue = DispatchQueue(label: "mornye.backend", qos: .userInitiated, attributes: .concurrent)
    let support: URL
    let music: URL
    let cache: URL
    private(set) var extensions: [[String: Any]] = []
    private(set) var startError: String?

    private init() {
        let fm = FileManager.default
        support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        music = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music", isDirectory: true)
        cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for dir in [extensionsDir, dataDir, music, repoCache] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var extensionsDir: URL { support.appendingPathComponent("extensions", isDirectory: true) }
    var dataDir: URL { support.appendingPathComponent("extension_data", isDirectory: true) }
    var repoCache: URL { cache.appendingPathComponent("repo", isDirectory: true) }

    var repoURLs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "repoURLs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "repoURLs") }
    }

    var downloadExtensions: [[String: Any]] {
        extensions.filter { ($0["enabled"] as? Bool ?? false) && ($0["has_download_provider"] as? Bool ?? false) }
    }

    var searchExtensions: [[String: Any]] {
        extensions.filter { ($0["enabled"] as? Bool ?? false) && ($0["search_behavior"] != nil || ($0["has_metadata_provider"] as? Bool ?? false)) }
    }

    func invoke(_ method: String, _ args: Any? = nil) throws -> Any? {
        try backend.invokeApplication(method: method, arguments: args)
    }

    func call(_ method: String, _ args: Any? = nil, done: ((Any?, Error?) -> Void)? = nil) {
        queue.async {
            do {
                let value = try self.invoke(method, args)
                DispatchQueue.main.async { done?(value, nil) }
            } catch {
                DispatchQueue.main.async { done?(nil, error) }
            }
        }
    }

    func start(done: @escaping () -> Void) {
        queue.async {
            do {
                try self.invoke("initExtensionSystem", [
                    "extensions_dir": self.extensionsDir.path,
                    "data_dir": self.dataDir.path,
                    "master_key": self.masterKey(),
                    "lyrics_providers_json": "[]",
                    "lyrics_options_json": "{}",
                    "allowed_directories": [self.music.path],
                ])
                try self.invoke("setDownloadDirectory", ["path": self.music.path])
                try self.invoke("initExtensionRepo", ["cache_dir": self.repoCache.path])
                try self.invoke("setRepoRegistryUrls", ["registry_urls": self.repoURLs])
                _ = try? self.invoke("loadExtensionsFromDir", ["dir_path": self.extensionsDir.path])
                try self.reloadExtensionsSync()
            } catch {
                self.startError = error.localizedDescription
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    func reloadExtensionsSync() throws {
        let list = jsonList(try invoke("getInstalledExtensions"))
        DispatchQueue.main.async {
            self.extensions = list
            NotificationCenter.default.post(name: Lite.extensionsChanged, object: nil)
        }
    }

    func reloadExtensions() {
        queue.async { try? self.reloadExtensionsSync() }
    }

    private func masterKey() -> String {
        let account = "mornye-lite-master-key"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecValueData as String: Data(key.utf8)]
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}

func jsonValue(_ value: Any?) -> Any? {
    if let text = value as? String, let data = text.data(using: .utf8) {
        return try? JSONSerialization.jsonObject(with: data)
    }
    return value
}

func jsonMap(_ value: Any?) -> [String: Any] {
    jsonValue(value) as? [String: Any] ?? [:]
}

func jsonList(_ value: Any?) -> [[String: Any]] {
    let parsed = jsonValue(value)
    if let list = parsed as? [[String: Any]] { return list }
    if let map = parsed as? [String: Any] {
        for key in ["tracks", "results", "items", "data", "extensions"] {
            if let list = map[key] as? [[String: Any]] { return list }
        }
    }
    return []
}

func jsonString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return ""
    }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? Int(str(key)) ?? 0 }
    var extName: String {
        let display = str("display_name")
        return display.isEmpty ? str("name") : display
    }
}
