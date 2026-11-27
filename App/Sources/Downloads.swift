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
    private let cancelLock = NSLock()
    private var cancelRequested = false
    /// Thread-safe cancel flag for background conversions.
    var isCancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelRequested }
        set { cancelLock.lock(); cancelRequested = newValue; cancelLock.unlock() }
    }
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
        job.isCancelled = true
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

    /// Removes jobs from the list (cancelling active ones), optionally deleting their saved songs.
    func remove(_ list: [DownloadJob], deleteFiles: Bool) {
        var deleted = false
        for job in list {
            if !job.done {
                Lite.shared.call("cancelDownload", ["item_id": job.id])
                job.status = "Cancelled"
                job.isCancelled = true
                job.done = true
            } else if deleteFiles, !job.filePath.isEmpty, !job.status.hasPrefix("Failed"),
                      FileManager.default.fileExists(atPath: job.filePath) {
                try? FileManager.default.removeItem(atPath: job.filePath)
                deleted = true
            }
        }
        jobs.removeAll { job in list.contains { $0 === job } && !job.status.hasPrefix("Converting") }
        notify()
        if deleted { LibraryStore.shared.scan {} }
    }

    /// Tags to write into the saved file, preferring what the download returned over the search result.
    static func tags(_ track: Track, _ result: [String: Any]) -> [String: String] {
        func pick(_ key: String, _ fallback: String) -> String {
            let value = result.str(key)
            return value.isEmpty || value == "0" ? fallback : value
        }
        var tags = ["title": pick("title", track.title), "artist": pick("artist", track.artist),
                    "album": pick("album", track.album), "album_artist": pick("album_artist", track.raw.str("album_artist")),
                    "date": pick("release_date", track.raw.str("release_date")), "isrc": pick("isrc", track.raw.str("isrc")),
                    "cover_url": pick("cover_url", track.coverURL)]
        if tags["album_artist"]?.isEmpty != false { tags["album_artist"] = track.primaryArtist }
        for key in ["track_number", "disc_number"] {
            let n = result.int(key) > 0 ? result.int(key) : track.raw.int(key)
            if n > 0 { tags[key] = String(n) }
        }
        return tags.filter { !$0.value.isEmpty }
    }

    func clearFinished() {
        jobs.removeAll { $0.done && !$0.status.hasPrefix("Converting") }
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
            NSLog("MornyeLite download [%@] %@ -> success=%@ type=%@ path=%@ error=%@", job.provider, job.track.title,
                  "\(result["success"] ?? "nil")", result.str("error_type"), result.str("file_path"),
                  error?.localizedDescription ?? result.str("error"))
            var verify = false
            if job.status != "Cancelled" {
                let message = result.str("error").isEmpty ? result.str("message") : result.str("error")
                if let error = error {
                    job.status = "Failed: \(error.localizedDescription)"
                } else if result["success"] as? Bool != true, Self.needsVerification(result.str("error_type") + " " + message) {
                    job.needsVerification = true
                    verify = true
                } else if result["success"] as? Bool == true, MovDecrypt.needsDecryption(result) {
                    let encrypted = result.str("file_path")
                    if let info = MovDecrypt.descriptor(result), !encrypted.isEmpty {
                        job.status = "Converting: decrypting…"
                        DispatchQueue.global(qos: .userInitiated).async {
                            let path = MovDecrypt.run(input: encrypted, key: info.key, inputFormat: info.inputFormat,
                                                      outputExtension: info.outputExtension,
                                                      cancelled: { job.isCancelled })
                            DispatchQueue.main.async {
                                if let path = path {
                                    var decrypted = result
                                    decrypted["file_path"] = path
                                    self.finish(job, decrypted)
                                } else {
                                    try? FileManager.default.removeItem(atPath: encrypted)
                                    if job.status != "Cancelled" { job.status = "Failed: could not decrypt the track" }
                                }
                                self.notify()
                            }
                        }
                    } else {
                        job.status = "Failed: unsupported decryption method"
                        if !encrypted.isEmpty { try? FileManager.default.removeItem(atPath: encrypted) }
                    }
                } else if result["success"] as? Bool == true {
                    self.finish(job, result)
                } else {
                    job.status = "Failed: \(message.isEmpty ? "unknown error" : message)"
                    if !result.str("error_type").isEmpty { job.detail = "Error type: \(result.str("error_type"))" }
                }
            }
            job.done = true
            Lite.shared.call("clearItemProgress", ["item_id": job.id])
            self.running = false
            self.notify()
            if verify { self.verifyAndRetry(job) }
            if !self.jobs.contains(where: { !$0.done }) { self.stopPolling() }
            self.pump()
        }
    }

    private func finish(_ job: DownloadJob, _ result: [String: Any]) {
        let reported = result.str("file_path")
        if let path = Self.placeInLibrary(reported) {
            let finished = result["already_exists"] as? Bool == true ? "Done · already in library" : "Done"
            let opus = OpusRemux.extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
            job.filePath = path
            job.status = opus ? "Converting to AAC…" : finished
            job.progress = 1
            job.detail = Self.describe(result, path)
            LibraryStore.shared.importDownload(path, tags: result["already_exists"] as? Bool == true ? [:] : Self.tags(job.track, result)) { saved in
                if let saved = saved {
                    job.filePath = saved
                    job.status = finished
                    job.detail = Self.describe(result, saved) + (opus ? " · converted from Opus" : "")
                } else {
                    job.status = "Failed: could not convert Opus to AAC"
                }
                self.notify()
            }
        } else {
            job.status = "Failed: extension said done but no file was saved"
            job.detail = reported.isEmpty ? "No file path returned" : "Missing: \(reported)"
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
        if !OpusRemux.extensions.contains(url.pathExtension.lowercased()), !LibraryStore.audioExtensions.contains(url.pathExtension.lowercased()) {
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
    private let jobs = { DownloadManager.shared.jobs }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        tableView.rowHeight = 88
        tableView.separatorStyle = .none
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.register(DownloadCell.self, forCellReuseIdentifier: "d")
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: DownloadManager.changed, object: nil)
        updateButtons()
        changed()
    }

    @objc private func changed() {
        tableView.backgroundView = jobs().isEmpty ? Theme.emptyLabel("No downloads yet.\nFind songs in Search and tap one to download it.") : nil
        if tableView.isEditing && tableView.numberOfRows(inSection: 0) == jobs().count {
            for cell in tableView.visibleCells {
                if let path = tableView.indexPath(for: cell), let cell = cell as? DownloadCell { cell.show(jobs()[path.row]) }
            }
        } else {
            tableView.reloadData()
        }
        updateButtons()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        updateButtons()
    }

    private var selectedJobs: [DownloadJob] {
        (tableView.indexPathsForSelectedRows ?? []).map { $0.row }.filter { jobs().indices.contains($0) }.map { jobs()[$0] }
    }

    private func updateButtons() {
        if isEditing {
            let all = !jobs().isEmpty && selectedJobs.count == jobs().count
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: all ? "Deselect All" : "Select All", style: .plain,
                                                               target: self, action: #selector(toggleSelectAll))
            let delete = UIBarButtonItem(title: selectedJobs.isEmpty ? "Delete" : "Delete (\(selectedJobs.count))", style: .plain,
                                         target: self, action: #selector(deleteSelected))
            delete.tintColor = Theme.red
            delete.isEnabled = !selectedJobs.isEmpty
            navigationItem.rightBarButtonItems = [editButtonItem, delete]
        } else {
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItems = [editButtonItem]
            editButtonItem.isEnabled = !jobs().isEmpty
        }
    }

    @objc private func toggleSelectAll() {
        let all = selectedJobs.count == jobs().count
        for row in jobs().indices {
            let path = IndexPath(row: row, section: 0)
            if all { tableView.deselectRow(at: path, animated: false) } else { tableView.selectRow(at: path, animated: false, scrollPosition: .none) }
        }
        updateButtons()
    }

    @objc private func deleteSelected() {
        let list = selectedJobs
        guard !list.isEmpty else { return }
        let saved = list.filter { $0.done && !$0.filePath.isEmpty && !$0.status.hasPrefix("Failed") }.count
        let sheet = UIAlertController(title: "Remove \(list.count) download\(list.count == 1 ? "" : "s")?", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Remove from list", style: .default) { _ in self.remove(list, files: false) })
        if saved > 0 {
            sheet.addAction(UIAlertAction(title: "Remove and delete \(songCount(saved))", style: .destructive) { _ in self.remove(list, files: true) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last
        present(sheet, animated: true)
    }

    private func remove(_ list: [DownloadJob], files: Bool) {
        DownloadManager.shared.remove(list, deleteFiles: files)
        setEditing(false, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { jobs().count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "d", for: indexPath) as! DownloadCell
        cell.show(jobs()[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) { updateButtons() }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing { return updateButtons() }
        tableView.deselectRow(at: indexPath, animated: true)
        let job = jobs()[indexPath.row]
        let sheet = UIAlertController(title: job.track.title, message: [job.status, job.detail].filter { !$0.isEmpty }.joined(separator: "\n"),
                                      preferredStyle: .actionSheet)
        if job.done && job.status.hasPrefix("Failed") {
            if job.needsVerification {
                sheet.addAction(UIAlertAction(title: "Verify and retry", style: .default) { _ in DownloadManager.shared.verifyAndRetry(job) })
            }
            sheet.addAction(UIAlertAction(title: "Retry", style: .default) { _ in DownloadManager.shared.retry(job) })
        }
        if let item = LibraryStore.shared.items.first(where: { $0.path == job.filePath }) {
            sheet.addAction(UIAlertAction(title: "Play", style: .default) { _ in Player.shared.play([item], at: 0) })
        }
        sheet.addAction(UIAlertAction(title: job.done ? "Remove from list" : "Cancel download", style: .destructive) { _ in
            DownloadManager.shared.cancel(job)
        })
        sheet.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(sheet, from: tableView.cellForRow(at: indexPath))
    }

    override func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        jobs()[indexPath.row].done ? "Remove" : "Cancel"
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        DownloadManager.shared.cancel(jobs()[indexPath.row])
    }
}

private final class DownloadCell: UITableViewCell {
    private let art = UIImageView()
    private let title = Theme.label(15, .semibold)
    private let status = Theme.label(13, .medium)
    private let detail = Theme.label(11, .regular, Theme.subtext)
    private let bar = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        Theme.style(self)
        art.clipsToBounds = true
        art.layer.cornerRadius = 3
        art.backgroundColor = Theme.elevated
        detail.numberOfLines = 2
        [art, title, status, detail, bar].forEach { contentView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ job: DownloadJob) {
        let name = Lite.shared.extensions.first { $0.str("id") == job.provider }?.extName ?? job.provider
        title.text = "\(job.track.title) · \(job.track.artist)"
        let failed = job.status.hasPrefix("Failed") || job.status == "Cancelled"
        let finished = job.done && !failed && !job.status.hasPrefix("Converting")
        status.text = "\(name) · \(job.quality) · \(job.status)" + (job.done ? "" : " \(Int(job.progress * 100))%")
        status.textColor = failed ? Theme.red : finished ? Theme.green : Theme.text
        detail.text = job.detail
        bar.isHidden = job.done
        bar.progress = Float(job.progress)
        Art.set(art, path: nil, url: job.track.coverURL, size: 56)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        art.frame = CGRect(x: 16, y: 14, width: 56, height: 56)
        let x = art.frame.maxX + 12
        title.frame = CGRect(x: x, y: 10, width: w - x - 12, height: 20)
        status.frame = CGRect(x: x, y: 31, width: w - x - 12, height: 18)
        detail.frame = CGRect(x: x, y: 49, width: w - x - 12, height: 28)
        bar.frame = CGRect(x: x, y: 80, width: w - x - 16, height: 2)
    }
}
