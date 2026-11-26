import UIKit

final class DownloadJob {
    let id = UUID().uuidString
    let track: Track
    let provider: String
    let quality: String
    var status = "Queued"
    var progress: Double = 0
    var done = false
    var detail = ""
    var filePath = ""
    var needsVerification = false
    init(track: Track, provider: String, quality: String) {
        self.track = track
        self.provider = provider
        self.quality = quality
    }
}

final class DownloadManager {
    static let shared = DownloadManager()
    static let changed = Notification.Name("LiteDownloadsChanged")
    private(set) var jobs: [DownloadJob] = []
    private var running = false
    private var timer: Timer?

    func enqueue(_ track: Track, provider: String, quality: String) {
        jobs.append(DownloadJob(track: track, provider: provider, quality: quality))
        notify()
        pump()
    }

    func cancel(_ job: DownloadJob) {
        if job.done { jobs.removeAll { $0 === job }; notify(); return }
        Lite.shared.call("cancelDownload", ["item_id": job.id])
        job.status = "Cancelled"
        job.done = true
        notify()
    }

    func retry(_ job: DownloadJob) {
        guard job.done else { return }
        job.done = false
        job.needsVerification = false
        job.status = "Queued"
        job.progress = 0
        job.detail = ""
        notify()
        pump()
    }

    func verifyAndRetry(_ job: DownloadJob) {
        job.status = "Waiting for verification in browser…"
        notify()
        Verification.shared.verify(job.provider) { ok in
            if ok { self.retry(job) } else {
                job.status = "Failed: verification was not completed"
                self.notify()
            }
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.done }
        notify()
    }

    private func pump() {
        guard !running, let job = jobs.first(where: { !$0.done && $0.status == "Queued" }) else { return }
        running = true
        job.status = "Downloading"
        startPolling()
        notify()
        let request = jsonString(job.track.downloadRequest(provider: job.provider, quality: job.quality,
                                                           itemId: job.id, outputDir: Lite.shared.music.path))
        Lite.shared.call("downloadByStrategy", request) { value, error in
            let result = jsonMap(value)
            NSLog("MornyeLite download [%@] %@ -> %@", job.provider, job.track.title,
                  error.map { "\($0)" } ?? jsonString(result))
            var verify = false
            if job.status != "Cancelled" {
                let message = result.str("error").isEmpty ? result.str("message") : result.str("error")
                if let error = error {
                    job.status = "Failed: \(error.localizedDescription)"
                } else if result["success"] as? Bool != true, Self.needsVerification(result.str("error_type") + " " + message) {
                    job.needsVerification = true
                    verify = true
                } else if result["success"] as? Bool == true,
                          !result.str("decryption_key").isEmpty || result["decryption"] != nil {
                    job.status = "Failed: track needs decryption, which requires FFmpeg (not included in Lite)"
                } else if result["success"] as? Bool == true {
                    let reported = result.str("file_path")
                    if let path = Self.placeInLibrary(reported) {
                        job.filePath = path
                        job.status = result["already_exists"] as? Bool == true ? "Done · already in library" : "Done"
                        job.progress = 1
                        job.detail = Self.describe(result, path)
                    } else {
                        job.status = "Failed: extension said done but no file was saved"
                        job.detail = reported.isEmpty ? "No file path returned" : "Missing: \(reported)"
                    }
                } else {
                    job.status = "Failed: \(message.isEmpty ? "unknown error" : message)"
                    if !result.str("error_type").isEmpty { job.detail = "Error type: \(result.str("error_type"))" }
                }
            }
            job.done = true
            Lite.shared.call("clearItemProgress", ["item_id": job.id])
            self.running = false
            self.notify()
            if !job.filePath.isEmpty { LibraryStore.shared.scan {} }
            if verify { self.verifyAndRetry(job) }
            if !self.jobs.contains(where: { !$0.done }) { self.stopPolling() }
            self.pump()
        }
    }

    static func needsVerification(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["verify_required", "verification_required", "verification required", "needsverification",
                "needs verification", "session is not authenticated", "signed session expired"].contains { t.contains($0) }
    }

    /// Returns the file's final path inside Documents/Music, moving it there if the extension saved it elsewhere.
    static func placeInLibrary(_ reported: String) -> String? {
        guard !reported.isEmpty else { return nil }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: reported.hasPrefix("file://") ? (URL(string: reported)?.path ?? reported) : reported)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let music = Lite.shared.music.standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(music + "/") { return url.path }
        let target = Lite.shared.music.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        do { try fm.moveItem(at: url, to: target) } catch {
            guard (try? fm.copyItem(at: url, to: target)) != nil else { return url.path }
        }
        return target.path
    }

    static func describe(_ result: [String: Any], _ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var parts: [String] = []
        let codec = [result.str("audio_codec"), result.str("actual_container")].filter { !$0.isEmpty }.joined(separator: "/")
        if !codec.isEmpty { parts.append(codec.uppercased()) }
        let bits = result.str("actual_bit_depth"), rate = result.str("actual_sample_rate")
        if !bits.isEmpty && bits != "0" { parts.append("\(bits)-bit") }
        if !rate.isEmpty && rate != "0" { parts.append(Double(rate).map { $0 >= 1000 ? "\($0 / 1000) kHz" : "\(rate) Hz" } ?? rate) }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
            parts.append(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))
        }
        if !LibraryStore.audioExtensions.contains(url.pathExtension.lowercased()) {
            parts.append(".\(url.pathExtension) can't play on iOS 12")
        }
        parts.append(url.lastPathComponent)
        return parts.joined(separator: " · ")
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        Lite.shared.call("getAllDownloadProgress") { value, _ in
            let map = jsonMap(value)
            var items = map["items"] as? [String: Any] ?? map
            for entry in jsonList(value) { items[entry.str("item_id")] = entry }
            for job in self.jobs where !job.done {
                guard let entry = items[job.id] as? [String: Any] else { continue }
                if let p = entry["progress"] as? NSNumber {
                    job.progress = p.doubleValue > 1 ? p.doubleValue / 100 : p.doubleValue
                } else {
                    let total = Double(entry.int("bytes_total"))
                    if total > 0 { job.progress = Double(entry.int("bytes_received")) / total }
                }
            }
            self.notify()
        }
    }

    private func notify() { NotificationCenter.default.post(name: DownloadManager.changed, object: nil) }
}

final class DownloadsViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clear))
        tableView.estimatedRowHeight = 72
        tableView.rowHeight = UITableView.automaticDimension
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData), name: DownloadManager.changed, object: nil)
    }

    @objc private func clear() { DownloadManager.shared.clearFinished() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { DownloadManager.shared.jobs.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "d") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "d")
        let job = DownloadManager.shared.jobs[indexPath.row]
        let name = Lite.shared.extensions.first { $0.str("id") == job.provider }?.extName ?? job.provider
        cell.textLabel?.text = "\(job.track.title) – \(job.track.artist)"
        let percent = job.done ? "" : " \(Int(job.progress * 100))%"
        var lines = ["\(name) · \(job.quality) · \(job.status)\(percent)"]
        if !job.detail.isEmpty { lines.append(job.detail) }
        cell.detailTextLabel?.text = lines.joined(separator: "\n")
        cell.detailTextLabel?.textColor = job.status.hasPrefix("Failed") ? .red : .gray
        cell.detailTextLabel?.numberOfLines = 0
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let job = DownloadManager.shared.jobs[indexPath.row]
        let sheet = UIAlertController(title: job.track.title, message: [job.status, job.detail].filter { !$0.isEmpty }.joined(separator: "\n"),
                                      preferredStyle: .actionSheet)
        if job.done && job.status.hasPrefix("Failed") {
            if job.needsVerification {
                sheet.addAction(UIAlertAction(title: "Verify and retry", style: .default) { _ in DownloadManager.shared.verifyAndRetry(job) })
            }
            sheet.addAction(UIAlertAction(title: "Retry", style: .default) { _ in DownloadManager.shared.retry(job) })
        }
        sheet.addAction(UIAlertAction(title: job.done ? "Remove" : "Cancel download", style: .destructive) { _ in
            DownloadManager.shared.cancel(job)
        })
        sheet.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(sheet, from: tableView.cellForRow(at: indexPath))
    }

    override func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        DownloadManager.shared.jobs[indexPath.row].done ? "Remove" : "Cancel"
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        DownloadManager.shared.cancel(DownloadManager.shared.jobs[indexPath.row])
    }
}
