import UIKit

final class DownloadJob {
    let id = UUID().uuidString
    let track: Track
    let provider: String
    let quality: String
    var status = "Queued"
    var progress: Double = 0
    var done = false
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
            if job.status != "Cancelled" {
                if let error = error {
                    job.status = "Failed: \(error.localizedDescription)"
                } else if result["success"] as? Bool == true,
                          !result.str("decryption_key").isEmpty || result["decryption"] != nil {
                    job.status = "Failed: track needs decryption, which requires FFmpeg (not included in Lite)"
                } else if result["success"] as? Bool == true {
                    job.status = "Done"
                    job.progress = 1
                } else {
                    let message = result.str("error").isEmpty ? result.str("message") : result.str("error")
                    job.status = "Failed: \(message.isEmpty ? "unknown error" : message)"
                }
            }
            job.done = true
            Lite.shared.call("clearItemProgress", ["item_id": job.id])
            self.running = false
            self.notify()
            if result["success"] as? Bool == true { LibraryStore.shared.scan {} }
            if !self.jobs.contains(where: { !$0.done }) { self.stopPolling() }
            self.pump()
        }
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
        tableView.rowHeight = 56
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData), name: DownloadManager.changed, object: nil)
    }

    @objc private func clear() { DownloadManager.shared.clearFinished() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { DownloadManager.shared.jobs.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "d") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "d")
        let job = DownloadManager.shared.jobs[indexPath.row]
        cell.textLabel?.text = "\(job.track.title) – \(job.track.artist)"
        let percent = job.done ? "" : " \(Int(job.progress * 100))%"
        cell.detailTextLabel?.text = "\(job.provider) · \(job.status)\(percent)"
        cell.detailTextLabel?.textColor = job.status.hasPrefix("Failed") ? .red : .gray
        cell.detailTextLabel?.numberOfLines = 2
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        DownloadManager.shared.jobs[indexPath.row].done ? "Remove" : "Cancel"
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        DownloadManager.shared.cancel(DownloadManager.shared.jobs[indexPath.row])
    }
}
