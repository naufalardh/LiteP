import AudioToolbox
import UIKit

struct LibraryItem: Codable {
    let path: String
    var title: String
    var artist: String
    var album: String
    var coverPath: String?
    var modified: Double
    var url: URL { URL(fileURLWithPath: path) }
}

final class LibraryStore {
    static let shared = LibraryStore()
    static let audioExtensions: Set<String> = ["flac", "m4a", "mp3", "aac", "alac", "wav", "aiff", "aif", "caf", "mp4"]
    private(set) var items: [LibraryItem] = []
    private var indexFile: URL { Lite.shared.support.appendingPathComponent("library.json") }
    private var coverDir: URL { Lite.shared.cache.appendingPathComponent("covers", isDirectory: true) }

    private init() {
        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = saved
        }
    }

    /// Rescans Documents/Music, reading tags only for new or modified files.
    func scan(done: @escaping () -> Void) {
        Lite.shared.queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: self.coverDir, withIntermediateDirectories: true)
            let known = Dictionary(self.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var result: [LibraryItem] = []
            let root = Lite.shared.music
            let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            while var url = files?.nextObject() as? URL {
                if OpusRemux.extensions.contains(url.pathExtension.lowercased()) {
                    guard let converted = self.convertOpus(url) else { continue }
                    url = converted
                }
                guard LibraryStore.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let modified = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()).timeIntervalSince1970
                if let old = known[url.path], old.modified == modified,
                   old.coverPath.map({ fm.fileExists(atPath: $0) }) ?? true {
                    result.append(old)
                    continue
                }
                autoreleasepool { result.append(self.read(url, modified: modified)) }
            }
            result.sort { ($0.artist.lowercased(), $0.album.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased(), $1.title.lowercased()) }
            if let data = try? JSONEncoder().encode(result) { try? data.write(to: self.indexFile, options: .atomic) }
            DispatchQueue.main.async {
                self.items = result
                NotificationCenter.default.post(name: Lite.libraryChanged, object: nil)
                done()
            }
        }
    }

    /// Converts an .opus download to .caf (iOS 12 cannot play Ogg), keeping its tags and cover.
    private func convertOpus(_ url: URL) -> URL? {
        let fm = FileManager.default
        let target = url.deletingPathExtension().appendingPathExtension("caf")
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: url); return target }
        let meta = jsonMap(try? Lite.shared.backend.readFileMetadata(path: url.path, hint: url.lastPathComponent))
        var tags: [String: String] = [:]
        for (key, names) in [(kAFInfoDictionary_Title, ["title", "track_name"]), (kAFInfoDictionary_Artist, ["artist", "artist_name"]),
                             (kAFInfoDictionary_Album, ["album", "album_name"])] {
            if let value = names.map({ meta.str($0) }).first(where: { !$0.isEmpty }) { tags[key] = value }
        }
        let cover = coverDir.appendingPathComponent(sha256Hex(target.path) + ".jpg")
        _ = try? Lite.shared.backend.extractCoverToFile(audioPath: url.path, outputPath: cover.path)
        let art = url.deletingPathExtension().appendingPathExtension("jpg")
        if fm.fileExists(atPath: cover.path), !fm.fileExists(atPath: art.path) { try? fm.copyItem(at: cover, to: art) }
        guard let converted = OpusRemux.toCAF(url, tags: tags) else {
            NSLog("MornyeLite: could not convert %@", url.lastPathComponent)
            return nil
        }
        try? fm.removeItem(at: url)
        return converted
    }

    private func read(_ url: URL, modified: Double) -> LibraryItem {
        let name = url.deletingPathExtension().lastPathComponent
        var item = LibraryItem(path: url.path, title: name, artist: "", album: "", coverPath: nil, modified: modified)
        let meta = jsonMap(try? Lite.shared.backend.readFileMetadata(path: url.path, hint: url.lastPathComponent))
        for key in ["title", "track_name", "name"] where !meta.str(key).isEmpty { item.title = meta.str(key); break }
        for key in ["artist", "artist_name", "artists"] where !meta.str(key).isEmpty { item.artist = meta.str(key); break }
        for key in ["album", "album_name"] where !meta.str(key).isEmpty { item.album = meta.str(key); break }
        if url.pathExtension.lowercased() == "caf" {
            let tags = OpusRemux.tags(url)
            if let v = tags[kAFInfoDictionary_Title], item.title == name { item.title = v }
            if let v = tags[kAFInfoDictionary_Artist], item.artist.isEmpty { item.artist = v }
            if let v = tags[kAFInfoDictionary_Album], item.album.isEmpty { item.album = v }
        }
        let art = url.deletingPathExtension().appendingPathExtension("jpg")
        let cover = coverDir.appendingPathComponent(sha256Hex(url.path) + ".jpg")
        if FileManager.default.fileExists(atPath: cover.path) {
            item.coverPath = cover.path
        } else if (try? Lite.shared.backend.extractCoverToFile(audioPath: url.path, outputPath: cover.path)) != nil,
                  FileManager.default.fileExists(atPath: cover.path) {
            item.coverPath = cover.path
        } else if FileManager.default.fileExists(atPath: art.path) {
            item.coverPath = art.path
        }
        return item
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(atPath: item.path)
        items.removeAll { $0.path == item.path }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexFile, options: .atomic) }
    }
}

final class LibraryViewController: UITableViewController, UISearchResultsUpdating {
    private var shown: [LibraryItem] = []
    private let search = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Playing", style: .plain, target: self, action: #selector(openPlayer))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Rescan", style: .plain, target: self, action: #selector(rescan))
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.rowHeight = 56
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(rescan), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Lite.libraryChanged, object: nil)
        reload()
        rescan()
    }

    @objc private func rescan() {
        LibraryStore.shared.scan { [weak self] in self?.refreshControl?.endRefreshing() }
    }

    @objc private func reload() {
        let q = (search.searchBar.text ?? "").lowercased()
        let all = LibraryStore.shared.items
        shown = q.isEmpty ? all : all.filter { "\($0.title) \($0.artist) \($0.album)".lowercased().contains(q) }
        tableView.reloadData()
    }

    func updateSearchResults(for searchController: UISearchController) { reload() }

    @objc private func openPlayer() { navigationController?.pushViewController(PlayerViewController(), animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "t") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "t")
        let item = shown[indexPath.row]
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " · ")
        cell.detailTextLabel?.textColor = .gray
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        Player.shared.play(shown, at: indexPath.row)
        openPlayer()
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        LibraryStore.shared.delete(shown[indexPath.row])
        reload()
    }
}
